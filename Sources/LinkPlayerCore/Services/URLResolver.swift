import Foundation
#if canImport(FoundationNetworking)
// Linux (CI/sandbox) keeps URLSession & friends in FoundationNetworking.
import FoundationNetworking
#endif

/// Result of resolving a user-supplied URL over the network:
/// final URL after redirects, HTTP status and reported content type.
public struct ResolvedResource: Equatable, Sendable {
    public let finalURL: URL
    public let statusCode: Int
    public let contentType: String?
    public let expectedContentLength: Int64   // -1 when unknown

    public init(finalURL: URL, statusCode: Int, contentType: String?, expectedContentLength: Int64 = -1) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentType = contentType
        self.expectedContentLength = expectedContentLength
    }
}

/// Abstraction over the network so tests can inject mocks (DI for testability).
public protocol URLResolving: Sendable {
    func resolve(_ url: URL) async throws -> ResolvedResource
}

enum ResolutionErrorKind {
    case notHTTP
    case http(status: Int)
    case transport(String)
    case cancelled
    case timedOut
}

/// Shared classification of `URLError` / HTTP responses into `PlaybackError`.
/// Used by both the resolver and the tests.
public func classifyTransportError(_ error: Error) -> PlaybackError {
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default: return .networkFailure(urlError.localizedDescription)
        }
    }
    return .networkFailure(String(describing: error))
}

/// Production resolver. Issues a lightweight HEAD request first (no body
/// download); falls back to a bounded GET when the server answers 405/501 or
/// omits Content-Type. Redirects are followed automatically; the *final* URL
/// is what callers classify — we never assume the original link was media.
public struct HTTPURLResolver: URLResolving {

    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func resolve(_ url: URL) async throws -> ResolvedResource {
        guard url.scheme == "https" || url.scheme == "http" else {
            throw PlaybackError.unsupportedScheme(url.scheme ?? "")
        }

        let session = Self.makeSession(timeout: timeout)
        do {
            // 1. Cheap HEAD probe.
            if let head = try? await probe(session: session, url: url, method: "HEAD"),
               Self.isUsable(head) {
                return try map(head, url: url)
            }
            // 2. Some servers reject HEAD or hide Content-Type there → small GET.
            let get = try await probe(session: session, url: url, method: "GET")
            return try map(get, url: url)
        } catch let playbackError as PlaybackError {
            throw playbackError
        } catch {
            throw classifyTransportError(error)
        }
    }

    private struct ProbeResult {
        let response: HTTPURLResponse
        let data: Data
    }

    private func probe(session: URLSession, url: URL, method: String) async throws -> ProbeResult {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("LinkPlayer/1.0", forHTTPHeaderField: "User-Agent")
        if method == "GET" {
            // We only need headers; ask for a tiny range to avoid downloading
            // whole files while still getting real Content-Type values.
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.networkFailure("Unexpected response type")
        }
        return ProbeResult(response: http, data: data)
    }

    /// HEAD results worth trusting: success with a content type, or any
    /// definitive HTTP status other than 405/501 (method not supported).
    private static func isUsable(_ probe: ProbeResult) -> Bool {
        let code = probe.response.statusCode
        if code == 405 || code == 501 { return false }
        if (200...299).contains(code) {
            return true
        }
        // Definitive client/server errors should surface immediately.
        return (400...599).contains(code)
    }

    private func map(_ probe: ProbeResult, url: URL) throws -> ResolvedResource {
        let code = probe.response.statusCode
        switch code {
        case 401, 403: throw PlaybackError.unauthorized(statusCode: code)
        case 404: throw PlaybackError.notFound(statusCode: code)
        case 500...599: throw PlaybackError.serverError(statusCode: code)
        default: break
        }
        let contentType = probe.response.value(forHTTPHeaderField: "Content-Type")
        let length = Int64(probe.response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        let finalURL = probe.response.url ?? url
        return ResolvedResource(finalURL: finalURL,
                                statusCode: code,
                                contentType: contentType,
                                expectedContentLength: length)
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpAdditionalHeaders = ["Accept": "*/*"]
        return URLSession(configuration: config)
    }
}

#if canImport(FoundationNetworking)
// Linux Foundation needs the async data(for:) shim (used only in CI builds).
extension URLSession {
    fileprivate func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
#endif
