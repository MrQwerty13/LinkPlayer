package domain

import (
	"net/url"
	"strings"
	"unicode"
)

// ValidationPolicy mirrors MediaURLValidator.Policy from the Swift core.
type ValidationPolicy struct {
	AllowedSchemes     map[string]bool
	AllowsInsecureHTTP bool
}

// StandardPolicy accepts https and http.
func StandardPolicy() ValidationPolicy {
	return ValidationPolicy{
		AllowedSchemes:     map[string]bool{"https": true, "http": true},
		AllowsInsecureHTTP: true,
	}
}

// HTTPSPolicyOnly rejects plain http.
func HTTPSPolicyOnly() ValidationPolicy {
	return ValidationPolicy{
		AllowedSchemes:     map[string]bool{"https": true, "http": true},
		AllowsInsecureHTTP: false,
	}
}

// URLValidator performs pure, synchronous validation of untrusted user input.
type URLValidator struct {
	Policy ValidationPolicy
}

// NewURLValidator builds a validator with the given policy.
func NewURLValidator(policy ValidationPolicy) *URLValidator {
	return &URLValidator{Policy: policy}
}

// Validate normalizes raw text and returns a parsed URL or a *PlaybackError.
func (v *URLValidator) Validate(raw string) (*url.URL, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, New(KindEmptyInput, "")
	}
	// Reject whitespace inside the link early — almost always a paste mistake.
	for _, r := range trimmed {
		if unicode.IsSpace(r) {
			return nil, New(KindNotAURL, trimmed)
		}
	}

	// Parse the scheme manually ("scheme:") so behaviour never depends on how
	// a particular parser tokenizes exotic inputs like `data:` or `file:`.
	colon := strings.Index(trimmed, ":")
	if colon < 0 {
		return nil, New(KindNotAURL, trimmed)
	}
	scheme := strings.ToLower(trimmed[:colon])
	if !isSchemeLike(scheme) {
		return nil, New(KindNotAURL, trimmed)
	}
	// file:, javascript:, data:, itms-apps: and any arbitrary custom scheme are
	// rejected: LinkPlayer plays network media only.
	if !v.Policy.AllowedSchemes[scheme] {
		return nil, New(KindUnsupportedScheme, scheme)
	}
	if scheme == "http" && !v.Policy.AllowsInsecureHTTP {
		return nil, New(KindHTTPNotAllowed, "")
	}

	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.Host == "" {
		if err != nil {
			return nil, New(KindNotAURL, trimmed)
		}
		return nil, New(KindMissingHost, trimmed)
	}
	// Guard against "https:/weird" style one-slash inputs.
	if parsed.Scheme != scheme {
		return nil, New(KindNotAURL, trimmed)
	}
	return parsed, nil
}

func isSchemeLike(s string) bool {
	if s == "" || !isASCIIAlpha(s[0]) {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
			c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'
		if !ok {
			return false
		}
	}
	return true
}

func isASCIIAlpha(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}
