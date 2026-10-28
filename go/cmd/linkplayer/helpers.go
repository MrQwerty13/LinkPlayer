package main

import "net/url"

// mustParse is used only on URLs that already passed validation/resolution.
func mustParse(raw string) *url.URL {
	u, err := url.Parse(raw)
	if err != nil {
		return &url.URL{Path: raw}
	}
	return u
}
