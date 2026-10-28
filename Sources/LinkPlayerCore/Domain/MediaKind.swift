import Foundation

/// Classifies what a remote resource actually is, based on the final URL
/// (after redirects) and the HTTP `Content-Type` header.
///
/// We never pretend an HTML page is a media stream: website pages are
/// reported as `.webPage`, which the UI turns into a clear error message.
public enum MediaKind: Equatable, Sendable {
    case progressiveVideo      // .mp4 / .m4v / .mov, video/mp4 …
    case hlsStream             // .m3u8, application/vnd.apple.mpegurl …
    case audio                 // .mp3 / .m4a / .aac / .wav / .flac …
    case webPage               // text/html — not directly playable
    case unknown               // could not be determined

    /// True when AVFoundation can plausibly play this resource directly.
    public var isDirectlyPlayable: Bool {
        switch self {
        case .progressiveVideo, .hlsStream, .audio: return true
        case .webPage, .unknown: return false
        }
    }
}

public struct MediaKindDetector: Sendable {

    public init() {}

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "alac", "aiff"]
    private static let hlsExtensions: Set<String> = ["m3u8"]

    private static let videoContentTypes: Set<String> = [
        "video/mp4", "video/quicktime", "video/x-m4v", "video/mov"
    ]
    private static let audioContentTypes: Set<String> = [
        "audio/mpeg", "audio/mp4", "audio/aac", "audio/wav", "audio/x-wav",
        "audio/flac", "audio/x-flac", "audio/basic", "audio/mp3"
    ]
    private static let hlsContentTypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl"
    ]
    private static let htmlContentTypes: Set<String> = [
        "text/html", "application/xhtml+xml"
    ]

    /// Combines header information with path-extension heuristics.
    /// The Content-Type header wins when present; extensions are fallback.
    public func detect(finalURL: URL, contentTypeHeader: String?) -> MediaKind {
        let mime = Self.normalizeMIME(contentTypeHeader)

        if let mime {
            if Self.hlsContentTypes.contains(mime) { return .hlsStream }
            if Self.videoContentTypes.contains(mime) { return .progressiveVideo }
            if Self.audioContentTypes.contains(mime) { return .audio }
            if Self.htmlContentTypes.contains(mime) { return .webPage }
            // Explicit generic-binary/octet-stream tells us nothing useful —
            // fall through to extension heuristic below.
            if mime != "application/octet-stream" && mime.hasPrefix("video/") {
                return .progressiveVideo
            }
            if mime != "application/octet-stream" && mime.hasPrefix("audio/") {
                return .audio
            }
        }

        return detectFromPath(finalURL)
    }

    /// Extension-only classification (used for optimistic checks and tests).
    public func detectFromPath(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if Self.hlsExtensions.contains(ext) { return .hlsStream }
        if Self.videoExtensions.contains(ext) { return .progressiveVideo }
        if Self.audioExtensions.contains(ext) { return .audio }
        if ext == "html" || ext == "htm" { return .webPage }
        return .unknown
    }

    private static func normalizeMIME(_ header: String?) -> String? {
        guard let header else { return nil }
        let base = header.split(separator: ";", maxSplits: 1).first ?? ""
        let value = base.trimmingCharacters(in: .whitespaces).lowercased()
        return value.isEmpty ? nil : value
    }
}
