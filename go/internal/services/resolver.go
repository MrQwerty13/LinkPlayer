// Package services implements the platform-independent application logic:
// network URL resolution and the playback state machine.
package services

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"linkplayer.local/go/internal/domain"
)

// ResolvedResource is the outcome of probing a user-supplied URL:
// final URL after redirects, HTTP status and reported content type.
type ResolvedResource struct {
	FinalURL              string
	StatusCode            int
	ContentType           string
	ExpectedContentLength int64 // -1 when unknown
}

// Resolver abstracts the network so tests can inject mocks (DI).
type Resolver interface {
	Resolve(ctx context.Context, rawURL string) (*ResolvedResource, error)
}

// ClassifyTransportError maps Go http/context errors to PlaybackError kinds,
// mirroring classifyTransportError(_:) from the Swift core.
func ClassifyTransportError(err error) *domain.PlaybackError {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.Canceled):
		return domain.New(domain.KindCancelled, "")
	case errors.Is(err, context.DeadlineExceeded):
		return domain.New(domain.KindTimedOut, "")
	}
	var hErr *httpError
	if errors.As(err, &hErr) {
		return hErr.playbackErr()
	}
	msg := err.Error()
	if strings.Contains(msg, "timeout awaiting response headers") ||
		strings.Contains(msg, "Client.Timeout exceeded") {
		return domain.New(domain.KindTimedOut, "")
	}
	return domain.New(domain.KindNetworkFailure, msg)
}

// httpError wraps low-level transport failures with a timeout hint.
type httpError struct {
	err      error
	timedOut bool
}

func (e *httpError) Error() string { return e.err.Error() }
func (e *httpError) Unwrap() error { return e.err }
func (e *httpError) playbackErr() *domain.PlaybackError {
	if e.timedOut {
		return domain.New(domain.KindTimedOut, "")
	}
	return domain.New(domain.KindNetworkFailure, e.err.Error())
}

// HTTPResolver is the production resolver. It issues a lightweight HEAD probe
// first (no body download); falls back to a bounded ranged GET when the server
// answers 405/501 or omits Content-Type. Redirects are followed automatically;
// the *final* URL is what callers classify — we never assume the original link
// was media.
type HTTPResolver struct {
	Client  *http.Client
	Timeout time.Duration
}

// NewHTTPResolver builds a resolver with sane defaults (10 s per request).
func NewHTTPResolver(timeout time.Duration) *HTTPResolver {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return &HTTPResolver{
		Client: &http.Client{
			Timeout: timeout * 3,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 5 {
					return errors.New("too many redirects")
				}
				return nil
			},
		},
		Timeout: timeout,
	}
}

type probeResult struct {
	resp *http.Response
}

// Resolve probes the URL and returns metadata (never downloads the full body).
func (r *HTTPResolver) Resolve(ctx context.Context, rawURL string) (*ResolvedResource, error) {
	head, headErr := r.probe(ctx, rawURL, http.MethodHead)
	if headErr == nil && isUsable(head.resp) {
		res, err := mapProbe(head.resp)
		if err != nil {
			return nil, err
		}
		return res, nil
	}
	// Some servers reject HEAD or hide Content-Type there → small ranged GET.
	get, getErr := r.probe(ctx, rawURL, http.MethodGet)
	if getErr != nil {
		// Prefer the more informative error.
		if headErr != nil {
			return nil, headErr
		}
		return nil, getErr
	}
	return mapProbe(get.resp)
}

func (r *HTTPResolver) probe(ctx context.Context, rawURL, method string) (*probeResult, error) {
	reqCtx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, method, rawURL, nil)
	if err != nil {
		return nil, &httpError{err: err}
	}
	req.Header.Set("User-Agent", "LinkPlayer/1.0")
	req.Header.Set("Accept", "*/*")
	if method == http.MethodGet {
		// We only need headers; ask for a tiny range to avoid downloading
		// whole files while still getting real Content-Type values.
		req.Header.Set("Range", "bytes=0-1023")
	}
	resp, err := r.Client.Do(req)
	if err != nil {
		herr := &httpError{err: err}
		if errors.Is(err, context.DeadlineExceeded) {
			herr.timedOut = true
		}
		if ce, ok := err.(interface{ Timeout() bool }); ok && ce.Timeout() {
			herr.timedOut = true
		}
		return nil, herr
	}
	return &probeResult{resp: resp}, nil
}

// isUsable reports whether a HEAD result can be trusted: success with any
// status other than 405/501 (method not supported), or definitive errors.
func isUsable(resp *http.Response) bool {
	code := resp.StatusCode
	if code == http.StatusMethodNotAllowed || code == http.StatusNotImplemented {
		return false
	}
	if code >= 200 && code < 300 {
		return true
	}
	return code >= 400 && code < 600
}

func mapProbe(resp *http.Response) (*ResolvedResource, error) {
	// Drain & close to enable connection reuse; body was never needed.
	io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	resp.Body.Close()

	code := resp.StatusCode
	switch {
	case code == http.StatusUnauthorized || code == http.StatusForbidden:
		return nil, domain.New(domain.KindUnauthorized, itoa(code))
	case code == http.StatusNotFound:
		return nil, domain.New(domain.KindNotFound, itoa(code))
	case code >= 500 && code <= 599:
		return nil, domain.New(domain.KindServerError, itoa(code))
	}
	length := int64(-1)
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		if n, err := parseInt(cl); err == nil {
			length = n
		}
	}
	final := resp.Request.URL.String()
	if resp.Request.URL != nil {
		final = resp.Request.URL.String()
	}
	return &ResolvedResource{
		FinalURL:              final,
		StatusCode:            code,
		ContentType:           resp.Header.Get("Content-Type"),
		ExpectedContentLength: length,
	}, nil
}

func itoa(n int) string { return strconv.Itoa(n) }

func parseInt(s string) (int64, error) { return strconv.ParseInt(s, 10, 64) }
