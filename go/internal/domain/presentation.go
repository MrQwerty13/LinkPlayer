package domain

import (
	"net/url"
	"strings"
)

// LinkPresentation renders friendly titles for history rows and the UI.
var knownMediaExtensions = map[string]bool{
	"mp4": true, "m4v": true, "mov": true, "mp3": true, "m4a": true,
	"aac": true, "wav": true, "flac": true, "m3u8": true,
}

// DisplayTitle produces a readable title from a URL ("Big Buck Bunny"-style).
func DisplayTitle(u *url.URL) string {
	host := trimWWW(u.Hostname())
	base := u.Path
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	if base != "" {
		ext := ""
		dot := strings.LastIndex(base, ".")
		if dot >= 0 {
			ext = strings.ToLower(base[dot+1:])
		}
		if knownMediaExtensions[ext] && dot > 0 {
			base = base[:dot]
		}
		base = strings.ReplaceAll(base, "-", " ")
		base = strings.ReplaceAll(base, "_", " ")
		r := []rune(base)
		if len(r) > 40 {
			base = string(r[:40]) + "…"
		}
		if base != "" {
			return base
		}
	}
	if host == "" {
		return u.String()
	}
	return host
}

// Subtitle returns the trimmed host for secondary lines in history rows.
func Subtitle(u *url.URL) string {
	if u == nil {
		return ""
	}
	return trimWWW(u.Hostname())
}

func trimWWW(host string) string {
	return strings.TrimPrefix(host, "www.")
}
