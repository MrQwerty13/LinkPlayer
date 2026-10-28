import Foundation

/// Pure, synchronous validation of user-entered link text.
/// Treats the input as untrusted: normalizes, then enforces scheme policy.
public struct MediaURLValidator: Sendable {

    public struct Policy: Sendable, Equatable {
        /// Schemes AVFoundation can stream directly over the network.
        public var allowedSchemes: Set<String>
        /// When false, plain `http:` links are rejected (HTTPS-only mode).
        public var allowsInsecureHTTP: Bool

        public init(allowedSchemes: Set<String> = ["https", "http"],
                    allowsInsecureHTTP: Bool = true) {
            self.allowedSchemes = allowedSchemes
            self.allowsInsecureHTTP = allowsInsecureHTTP
        }

        public static let standard = Policy()
        public static let httpsOnly = Policy(allowsInsecureHTTP: false)
    }

    public var policy: Policy

    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Validates raw user text and returns a normalized URL or a precise error.
    public func validate(_ rawText: String) -> Result<URL, PlaybackError> {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyInput) }
        // Reject whitespace inside the link early — almost always a paste mistake.
        guard !trimmed.contains(where: { $0.isWhitespace }) else {
            return .failure(.notAURL(trimmed))
        }

        guard let url = URL(string: trimmed), url.scheme != nil else {
            return .failure(.notAURL(trimmed))
        }
        guard let scheme = url.scheme?.lowercased() else {
            return .failure(.notAURL(trimmed))
        }
        // file:, javascript:, data:, itms-apps: and any arbitrary custom scheme
        // are rejected: LinkPlayer plays network media only.
        guard policy.allowedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme(scheme))
        }
        if scheme == "http" && !policy.allowsInsecureHTTP {
            return .failure(.httpNotAllowed)
        }
        guard let host = url.host, !host.isEmpty else {
            return .failure(.missingHost)
        }
        return .success(url)
    }

    /// Convenience throwing variant used by async code paths.
    public func validatedURL(for rawText: String) throws -> URL {
        switch validate(rawText) {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }
}
