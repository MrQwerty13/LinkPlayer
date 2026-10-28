package infra

import (
	"sync"
)

// LaunchBehavior controls what the GUI shows at startup. Every value has a
// real effect on app behavior — no decorative switches.
type LaunchBehavior string

const (
	LaunchEmpty    LaunchBehavior = "showEmptyPlayer" // URL field focused (default)
	LaunchReopen   LaunchBehavior = "reopenLastItem"  // replay last history entry
	LaunchHistory  LaunchBehavior = "showHistory"     // open with history panel
)

// DisplayName renders the human label for menus.
func (b LaunchBehavior) DisplayName() string {
	switch b {
	case LaunchReopen:
		return "Reopen the last video"
	case LaunchHistory:
		return "Show history"
	}
	return "Start with an empty player"
}

// Settings is the persisted user-preferences model (mirrors AppSettings).
type Settings struct {
	HistoryEnabled     bool         `json:"historyEnabled"`
	AllowsInsecureHTTP bool         `json:"allowsInsecureHTTP"`
	AutoPlayOnOpen     bool         `json:"autoPlayOnOpen"`
	LaunchBehavior     LaunchBehavior `json:"launchBehavior"`
	Volume             int          `json:"volume"` // 0…100 system-style volume
}

// DefaultSettings matches the Swift core defaults.
func DefaultSettings() Settings {
	return Settings{
		HistoryEnabled:     true,
		AllowsInsecureHTTP: false,
		AutoPlayOnOpen:     true,
		LaunchBehavior:     LaunchEmpty,
		Volume:             80,
	}
}

// SettingsManager owns settings state + persistence; safe for concurrent use.
type SettingsManager struct {
	mu       sync.Mutex
	store    *JSONStore
	settings Settings
}

// NewSettingsManager loads persisted settings or falls back to defaults
// (corrupt files are tolerated, matching SettingsManagerTests behaviour).
func NewSettingsManager(store *JSONStore) *SettingsManager {
	sm := &SettingsManager{store: store, settings: DefaultSettings()}
	var loaded Settings
	if ok, err := store.Read("settings", &loaded); ok && err == nil {
		sm.settings = loaded
		sm.clamp()
	}
	return sm
}

// Snapshot returns a copy of current settings.
func (m *SettingsManager) Snapshot() Settings {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.settings
	return s
}

// Update applies transform, clamps values and persists atomically.
func (m *SettingsManager) Update(transform func(*Settings)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	transform(&m.settings)
	m.clamp()
	_ = m.store.Write("settings", m.settings)
}

// ResetToDefaults restores and persists the default model.
func (m *SettingsManager) ResetToDefaults() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.settings = DefaultSettings()
	_ = m.store.Write("settings", m.settings)
}

func (m *SettingsManager) clamp() {
	if m.settings.Volume < 0 {
		m.settings.Volume = 0
	}
	if m.settings.Volume > 100 {
		m.settings.Volume = 100
	}
	switch m.settings.LaunchBehavior {
	case LaunchEmpty, LaunchReopen, LaunchHistory:
	default:
		m.settings.LaunchBehavior = LaunchEmpty
	}
}
