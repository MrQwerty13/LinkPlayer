import Foundation

/// User-facing failure taxonomy for opening and playing a media link.
/// Every case maps to a short human sentence shown in the UI.
public enum PlaybackError: Error, Equatable, LocalizedError {
    case emptyInput
    case notAURL(String)
    case unsupportedScheme(String)
    case missingHost
    case httpNotAllowed
    case networkFailure(String)
    case timedOut
    case cancelled
    case notAMediaResource(finalURL: String, contentType: String?)
    case unauthorized(statusCode: Int)
    case notFound(statusCode: Int)
    case serverError(statusCode: Int)
    case decodingFailed(String)
    case drmProtected

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter a link to a video."
        case .notAURL(let raw):
            return "“\(Self.truncate(raw))” is not a valid URL."
        case .unsupportedScheme(let scheme):
            return "The “\(scheme):” links are not supported. Use an http(s) link to a media file or stream."
        case .missingHost:
            return "The URL has no host. Check the link and try again."
        case .httpNotAllowed:
            return "Plain HTTP links are disabled. Enable them in Settings if you trust the source."
        case .networkFailure(let detail):
            return "Network error: \(detail). Check your connection and try again."
        case .timedOut:
            return "The server took too long to respond."
        case .cancelled:
            return "Operation was cancelled."
        case .notAMediaResource(_, let contentType):
            if let contentType {
                return "This resource is not directly playable (received “\(contentType)”). LinkPlayer plays direct media files such as .mp4 and HLS streams (.m3u8), not website pages."
            }
            return "This resource is not directly playable. LinkPlayer plays direct media files such as .mp4 and HLS streams (.m3u8), not website pages."
        case .unauthorized:
            return "Access denied by the server (login or token required). LinkPlayer does not bypass authorization or DRM."
        case .notFound:
            return "The resource was not found (404). The link may be outdated."
        case .serverError(let code):
            return "The server returned an error (\(code))."
        case .decodingFailed(let detail):
            return "Playback failed: \(detail)"
        case .drmProtected:
            return "This content is DRM-protected and cannot be played."
        }
    }

    private static func truncate(_ s: String) -> String {
        s.count <= 60 ? s : String(s.prefix(57)) + "…"
    }
}
