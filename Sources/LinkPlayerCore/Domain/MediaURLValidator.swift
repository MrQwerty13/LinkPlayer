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

        // Parse the scheme manually ("scheme:") so we never depend on how a
        // particular Foundation version tokenizes exotic inputs like `data:`.
        guard let colon = trimmed.firstIndex(of: ":") else {
            return .failure(.notAURL(trimmed))
        }
        let schemeCandidate = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        let isSchemeLike = !schemeCandidate.isEmpty
            && schemeCandidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
            && schemeCandidate.first.map { $0.isLetter } == true
        guard isSchemeLike else {
            return .failure(.notAURL(trimmed))
        }
        // file:, javascript:, data:, itms-apps: and any arbitrary custom scheme
        // are rejected: LinkPlayer plays network media only.
        guard policy.allowedSchemes.contains(schemeCandidate) else {
            return .failure(.unsupportedScheme(schemeCandidate))
        }
        // Only parse the URL once we know the scheme is one we support, so the
        // error for unsupported schemes stays precise across Foundation versions.
        guard let url = URL(string: trimmed) else {
            return .failure(.notAURL(trimmed))
        }
        let scheme = schemeCandidate
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
