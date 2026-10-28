// Package domain contains pure business logic shared by the CLI and GUI:
// URL validation, media classification, error taxonomy and presentation.
package domain

import (
	"fmt"
	"strconv"
)

// ErrorKind categorises user-facing failures.
type ErrorKind int

const (
	KindEmptyInput ErrorKind = iota
	KindNotAURL
	KindUnsupportedScheme
	KindMissingHost
	KindHTTPNotAllowed
	KindNetworkFailure
	KindTimedOut
	KindCancelled
	KindNotAMediaResource
	KindUnauthorized
	KindNotFound
	KindServerError
	KindDecodingFailed
	KindDRMProtected
)

// PlaybackError is a failure with a short human sentence attached,
// mirroring the Swift core's PlaybackError taxonomy 1:1.
type PlaybackError struct {
	Kind   ErrorKind
	Detail string // raw input / scheme / status code / network detail
	Extra  string // secondary info (e.g. content type)
}

func (e *PlaybackError) Error() string { return e.UserMessage() }

// New creates a PlaybackError of the given kind.
func New(kind ErrorKind, detail string) *PlaybackError {
	return &PlaybackError{Kind: kind, Detail: detail}
}

// NewWithExtra creates a PlaybackError carrying secondary info.
func NewWithExtra(kind ErrorKind, detail, extra string) *PlaybackError {
	return &PlaybackError{Kind: kind, Detail: detail, Extra: extra}
}

// UserMessage returns the explanation shown in UI/terminal.
func (e *PlaybackError) UserMessage() string {
	switch e.Kind {
	case KindEmptyInput:
		return "Please enter a link to a video."
	case KindNotAURL:
		return fmt.Sprintf("%q is not a valid URL.", truncate(e.Detail, 60))
	case KindUnsupportedScheme:
		return fmt.Sprintf("The %q links are not supported. Use an http(s) link to a media file or stream.", e.Detail+":")
	case KindMissingHost:
		return "The URL has no host. Check the link and try again."
	case KindHTTPNotAllowed:
		return "Plain HTTP links are disabled. Enable them in Settings if you trust the source."
	case KindNetworkFailure:
		return fmt.Sprintf("Network error: %s. Check your connection and try again.", e.Detail)
	case KindTimedOut:
		return "The server took too long to respond."
	case KindCancelled:
		return "Operation was cancelled."
	case KindNotAMediaResource:
		if e.Extra != "" {
			return fmt.Sprintf("This resource is not directly playable (received %q). LinkPlayer plays direct media files such as .mp4 and HLS streams (.m3u8), not website pages.", e.Extra)
		}
		return "This resource is not directly playable. LinkPlayer plays direct media files such as .mp4 and HLS streams (.m3u8), not website pages."
	case KindUnauthorized:
		return "Access denied by the server (login or token required). LinkPlayer does not bypass authorization or DRM."
	case KindNotFound:
		return "The resource was not found (404). The link may be outdated."
	case KindServerError:
		code, _ := strconv.Atoi(e.Detail)
		return fmt.Sprintf("The server returned an error (%d).", code)
	case KindDecodingFailed:
		return fmt.Sprintf("Playback failed: %s", e.Detail)
	case KindDRMProtected:
		return "This content is DRM-protected and cannot be played."
	}
	return "Unknown error."
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
