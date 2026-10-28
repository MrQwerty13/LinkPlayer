package domain

import (
	"net/url"
	"strings"
)

// MediaKind classifies what a remote resource actually is, based on the final
// URL (after redirects) and the HTTP Content-Type header. We never pretend an
// HTML page is a media stream: website pages are reported as WebPage.
type MediaKind int

const (
	MediaUnknown MediaKind = iota
	ProgressiveVideo       // .mp4 / .m4v / .mov, video/mp4 …
	HLSStream              // .m3u8, application/vnd.apple.mpegurl …
	Audio                  // .mp3 / .m4a / .aac / .wav / .flac …
	WebPage                // text/html — not directly playable
)

func (k MediaKind) IsDirectlyPlayable() bool {
	return k == ProgressiveVideo || k == HLSStream || k == Audio
}

func (k MediaKind) String() string {
	switch k {
	case ProgressiveVideo:
		return "video"
	case HLSStream:
		return "hls"
	case Audio:
		return "audio"
	case WebPage:
		return "webpage"
	}
	return "unknown"
}

var (
	videoExtensions   = map[string]bool{"mp4": true, "m4v": true, "mov": true}
	audioExtensions   = map[string]bool{"mp3": true, "m4a": true, "aac": true, "wav": true, "flac": true, "alac": true, "aiff": true}
	hlsExtensions     = map[string]bool{"m3u8": true}
	videoContentTypes = map[string]bool{"video/mp4": true, "video/quicktime": true, "video/x-m4v": true, "video/mov": true}
	audioContentTypes = map[string]bool{
		"audio/mpeg": true, "audio/mp4": true, "audio/aac": true, "audio/wav": true,
		"audio/x-wav": true, "audio/flac": true, "audio/x-flac": true, "audio/basic": true, "audio/mp3": true,
	}
	hlsContentTypes = map[string]bool{
		"application/vnd.apple.mpegurl": true, "application/x-mpegurl": true,
		"audio/mpegurl": true, "audio/x-mpegurl": true,
	}
	htmlContentTypes = map[string]bool{"text/html": true, "application/xhtml+xml": true}
)

// KindDetector combines header information with path-extension heuristics.
// The Content-Type header wins when present; extensions are fallback.
type KindDetector struct{}

// Detect classifies a resolved resource.
func (KindDetector) Detect(finalURL *url.URL, contentTypeHeader string) MediaKind {
	if mime, ok := normalizeMIME(contentTypeHeader); ok {
		switch {
		case hlsContentTypes[mime]:
			return HLSStream
		case videoContentTypes[mime]:
			return ProgressiveVideo
		case audioContentTypes[mime]:
			return Audio
		case htmlContentTypes[mime]:
			return WebPage
		}
		// Explicit generic-binary/octet-stream tells us nothing useful —
		// fall through to the extension heuristic below.
		if mime != "application/octet-stream" && strings.HasPrefix(mime, "video/") {
			return ProgressiveVideo
		}
		if mime != "application/octet-stream" && strings.HasPrefix(mime, "audio/") {
			return Audio
		}
	}
	return KindDetector{}.DetectFromPath(finalURL)
}

// DetectFromPath is extension-only classification (optimistic checks, tests).
func (KindDetector) DetectFromPath(u *url.URL) MediaKind {
	ext := strings.ToLower(pathExtension(u))
	switch {
	case hlsExtensions[ext]:
		return HLSStream
	case videoExtensions[ext]:
		return ProgressiveVideo
	case audioExtensions[ext]:
		return Audio
	case ext == "html" || ext == "htm":
		return WebPage
	}
	return MediaUnknown
}

func pathExtension(u *url.URL) string {
	p := u.Path
	if i := strings.LastIndex(p, "."); i >= 0 {
		return p[i+1:]
	}
	return ""
}

func normalizeMIME(header string) (string, bool) {
	base := strings.SplitN(header, ";", 2)[0]
	value := strings.ToLower(strings.TrimSpace(base))
	return value, value != ""
}
