// Package infra provides device-only local persistence: atomic JSON store,
// sanitized history and user settings. Nothing here talks to a server.
package infra

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// ErrDecodingFailed mirrors JSONFileStore.StoreError.decodingFailed.
var ErrDecodingFailed = errors.New("decoding failed")

// JSONStore is an atomic JSON file persistence rooted at a directory.
type JSONStore struct {
	Dir string
}

// NewJSONStore builds a store rooted at dir (created lazily on write).
func NewJSONStore(dir string) *JSONStore { return &JSONStore{Dir: dir} }

func (s *JSONStore) fileURL(name string) string {
	return filepath.Join(s.Dir, name+".json")
}

// Write marshals value and atomically replaces the target file
// (temp + rename → no torn files on crash).
func (s *JSONStore) Write(key string, value any) error {
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return err
	}
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); err != nil {
		return err
	}
	target := s.fileURL(key)
	tmp := target + ".tmp"
	if err := os.WriteFile(tmp, []byte(buf.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, target)
}

// Read unmarshals key into value; returns (false, nil) when the file is absent
// and (false, ErrDecodingFailed) for corrupt content (callers fall back to defaults).
func (s *JSONStore) Read(key string, value any) (bool, error) {
	data, err := os.ReadFile(s.fileURL(key))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(data, value); err != nil {
		return false, ErrDecodingFailed
	}
	return true, nil
}

// Remove deletes the stored key if present (best effort).
func (s *JSONStore) Remove(key string) error {
	err := os.Remove(s.fileURL(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// DefaultDataDir resolves LinkPlayer's per-user data directory:
// $XDG_DATA_HOME/linkplayer or ~/.local/share/linkplayer.
func DefaultDataDir() string {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "linkplayer")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "linkplayer")
	}
	return filepath.Join(home, ".local", "share", "linkplayer")
}
