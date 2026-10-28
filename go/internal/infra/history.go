package infra

import (
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// Entry is one history record: a media link the user opened successfully.
type Entry struct {
	ID       string    `json:"id"`
	URL      string    `json:"url"` // sanitized absolute URL
	OpenedAt time.Time `json:"openedAt"`
}

// SensitiveParameterNames are query parameters whose values must never be
// persisted (tokens, signatures, passwords, session ids…).
var SensitiveParameterNames = map[string]bool{
	"token": true, "access_token": true, "accesstoken": true, "authtoken": true,
	"auth": true, "api_key": true, "apikey": true, "key": true, "secret": true,
	"password": true, "passwd": true, "pwd": true, "session": true,
	"sessionid": true, "sid": true, "sig": true, "signature": true,
	"expires": true, "x-amz-credential": true, "x-amz-security-token": true,
	"x-goog-signature": true, "shared": true, "usertoken": true, "bearer": true,
}

// HistoryManager keeps a device-only, most-recent-first, deduplicated,
// size-capped, sanitized list of recently opened links.
type HistoryManager struct {
	mu      sync.Mutex
	limit   int
	store   *JSONStore
	entries []Entry
	loaded  bool
}

// DefaultHistoryLimit mirrors HistoryManager.defaultLimit from the Swift core.
const DefaultHistoryLimit = 50

// NewHistoryManager builds a manager backed by store with a hard size cap.
func NewHistoryManager(store *JSONStore, limit int) *HistoryManager {
	if limit < 1 {
		limit = DefaultHistoryLimit
	}
	return &HistoryManager{limit: limit, store: store}
}

// All returns a copy of the current entries (most recent first).
func (h *HistoryManager) All() []Entry {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.ensureLoaded()
	out := make([]Entry, len(h.entries))
	copy(out, h.entries)
	return out
}

// Record implements services.Recorder — called after a successful open.
func (h *HistoryManager) Record(rawURL string) {
	h.Add(rawURL)
}

// Add inserts (or moves to top) a sanitized entry and persists.
func (h *HistoryManager) Add(rawURL string) Entry {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.ensureLoaded()

	sanitized := Sanitize(rawURL)
	// Deduplicate: move existing entry to the top instead of duplicating.
	filtered := h.entries[:0]
	for _, e := range h.entries {
		if e.URL != sanitized {
			filtered = append(filtered, e)
		}
	}
	h.entries = filtered

	entry := Entry{ID: newID(), URL: sanitized, OpenedAt: time.Now().UTC()}
	h.entries = append([]Entry{entry}, h.entries...)
	if len(h.entries) > h.limit {
		h.entries = h.entries[:h.limit]
	}
	h.persist()
	return entry
}

// Remove deletes a single record by id.
func (h *HistoryManager) Remove(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.ensureLoaded()
	filtered := h.entries[:0]
	for _, e := range h.entries {
		if e.ID != id {
			filtered = append(filtered, e)
		}
	}
	h.entries = filtered
	h.persist()
}

// Clear wipes the whole history (also used by Settings → “Clear History”).
func (h *HistoryManager) Clear() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.entries = nil
	h.loaded = true
	_ = h.store.Remove("history")
}

// Count reports current size (after lazy load).
func (h *HistoryManager) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.ensureLoaded()
	return len(h.entries)
}

// Sanitize strips credentials/tokens from query & fragment before storage.
func Sanitize(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return rawURL
	}
	q := u.Query()
	changed := false
	for name := range q {
		if SensitiveParameterNames[strings.ToLower(name)] {
			q.Del(name)
			changed = true
		}
	}
	if changed {
		u.RawQuery = q.Encode()
	} else {
		// Re-encode to normalize ordering/padding deterministically.
		u.RawQuery = q.Encode()
	}
	u.Fragment = "" // fragments often carry player tokens too
	return u.String()
}

func (h *HistoryManager) ensureLoaded() {
	if h.loaded {
		return
	}
	h.loaded = true
	var stored []Entry
	ok, err := h.store.Read("history", &stored)
	if ok && err == nil {
		h.entries = stored
		sortEntries(h.entries)
		if len(h.entries) > h.limit {
			h.entries = h.entries[:h.limit]
		}
	}
}

func sortEntries(entries []Entry) {
	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].OpenedAt.After(entries[j].OpenedAt)
	})
}

func (h *HistoryManager) persist() {
	_ = h.store.Write("history", h.entries)
}

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "fallback-id"
	}
	return hex.EncodeToString(b[:])
}
