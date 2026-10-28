import Foundation

/// Small pure helper used by the UI to render friendly titles for history rows.
public enum LinkPresentation {

    /// "Big Buck Bunny (blazesub…)" style title from a URL.
    public static func displayTitle(for url: URL) -> String {
        let host = url.host ?? ""
        var base = url.lastPathComponent
        if !base.isEmpty {
            // drop known media extensions for readability
            let ext = base.split(separator: ".").last.map(String.init) ?? ""
            if ["mp4","m4v","mov","mp3","m4a","aac","wav","flac","m3u8"].contains(ext.lowercased()) {
                base = String(base.dropLast(ext.count + 1))
            }
            base = base.replacingOccurrences(of: "-", with: " ")
                       .replacingOccurrences(of: "_", with: " ")
            if base.count > 40 { base = String(base.prefix(40)) + "…" }
            if !base.isEmpty { return base }
        }
        return trimmingWWW(host).isEmpty ? url.absoluteString : trimmingWWW(host)
    }

    private static func trimmingWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Compact relative date for history rows ("5 min ago" style is handled by
    /// SwiftUI's `.relative` formatter in the app; this returns ISO fallback).
    public static func subtitle(for entry: HistoryEntry) -> String {
        entry.parsedURL.map { trimmingWWW($0.host ?? "") } ?? ""
    }
}
