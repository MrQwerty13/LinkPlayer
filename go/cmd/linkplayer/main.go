// LinkPlayer — Linux edition.
//
// Modes:
//
//	linkplayer                     interactive TUI (default; works in a terminal)
//	linkplayer <url>               open URL immediately, then interactive TUI
//	linkplayer --play <url>        headless/CLI: validate → resolve → ffplay window
//	linkplayer --check <url>       validate & classify only (no playback)
//	linkplayer --history           list history
//	linkplayer --clear-history     wipe history
//
// Flags:
//	--no-window   play audio-only (-nodisp), useful over SSH / without X
//	--volume N    initial volume 0..100 (persisted to settings)
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"linkplayer.local/go/internal/domain"
	"linkplayer.local/go/internal/infra"
	"linkplayer.local/go/internal/player"
	"linkplayer.local/go/internal/services"
)

// app is the composition root: every dependency is wired here once and
// injected into the coordinator (no global mutable state).
type app struct {
	store     *infra.JSONStore
	history   *infra.HistoryManager
	settings  *infra.SettingsManager
	resolver  services.Resolver
	engine    *player.FFplayEngine
	coord     *services.Coordinator
	validator *domain.URLValidator
}

func newApp() *app {
	dataDir := infra.DefaultDataDir()
	if override := os.Getenv("LINKPLAYER_DATA_DIR"); override != "" {
		dataDir = override
	}
	store := infra.NewJSONStore(dataDir)
	settings := infra.NewSettingsManager(store)
	history := infra.NewHistoryManager(store, infra.DefaultHistoryLimit)
	engine := player.NewFFplayEngine()
	engine.SetVolume(settings.Snapshot().Volume)

	validator := domain.NewURLValidator(policyFrom(settings))
	resolver := services.NewHTTPResolver(10 * time.Second)

	a := &app{
		store: store, history: history, settings: settings,
		resolver: resolver, engine: engine, validator: validator,
	}
	a.coord = services.NewCoordinator(validator, resolver, engine, history, func() services.SettingsView {
		s := settings.Snapshot()
		return services.SettingsView{
			HistoryEnabled:     s.HistoryEnabled,
			AllowsInsecureHTTP: s.AllowsInsecureHTTP,
			AutoPlayOnOpen:     s.AutoPlayOnOpen,
			Volume:             s.Volume,
		}
	})
	return a
}

// policyFrom rebuilds the validation policy from live settings so toggling
// HTTP support takes effect without restarting the app.
func policyFrom(sm *infra.SettingsManager) *domain.URLValidator {
	return domain.NewURLValidator(domain.ValidationPolicy{
		AllowedSchemes:     map[string]bool{"https": true, "http": true},
		AllowsInsecureHTTP: sm.Snapshot().AllowsInsecureHTTP,
	})
}

func main() {
	args := os.Args[1:]
	a := newApp()

	flags := map[string]bool{}
	var positional []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--no-window":
			flags["no-window"] = true
		case "--play", "--check", "--history", "--clear-history", "--help", "-h":
			flags[args[i]] = true
		case "--volume":
			if i+1 < len(args) {
				if v, err := strconv.Atoi(args[i+1]); err == nil {
					a.settings.Update(func(s *infra.Settings) { s.Volume = v })
					a.engine.SetVolume(v)
				}
				i++
			}
		default:
			positional = append(positional, args[i])
		}
	}

	if flags["--help"] || flags["-h"] {
		usage()
		return
	}
	if flags["--history"] {
		printHistory(a.history)
		return
	}
	if flags["--clear-history"] {
		a.history.Clear()
		fmt.Println("History cleared.")
		return
	}

	if len(positional) == 0 && !flags["--play"] && !flags["--check"] {
		runTUI(a)
		return
	}

	target := firstTarget(flags, positional)
	if target == "" {
		fmt.Fprintln(os.Stderr, "No URL given. Try: linkplayer https://example.com/video.mp4")
		os.Exit(2)
	}

	if flags["--check"] {
		runCheck(a, target)
		return
	}
	runHeadless(a, target, flags["no-window"])
}

func firstTarget(flags map[string]bool, positional []string) string {
	if len(positional) > 0 {
		return positional[0]
	}
	if flags["--play"] || flags["--check"] {
		return ""
	}
	return ""
}

// runCheck validates + resolves + classifies without playing anything.
func runCheck(a *app, raw string) {
	u, err := a.validator.Validate(raw)
	if err != nil {
		fmt.Printf("✗ %s\n", friendly(err))
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	resolved, err := a.resolver.Resolve(ctx, u.String())
	if err != nil {
		fmt.Printf("✗ %s\n", friendly(asPlaybackErr(err)))
		os.Exit(1)
	}
	kind := domain.KindDetector{}.Detect(mustParse(resolved.FinalURL), resolved.ContentType)
	status := "not directly playable"
	if kind.IsDirectlyPlayable() {
		status = "playable (" + kind.String() + ")"
	}
	fmt.Printf("✓ %s → %s [%s]\n", resolved.FinalURL, status, orNone(resolved.ContentType))
}

// runHeadless opens a real playback session through ffplay.
func runHeadless(a *app, raw string, noWindow bool) {
	if !player.Available() {
		fmt.Fprintln(os.Stderr, "ffplay was not found in PATH. Install FFmpeg (package `ffmpeg`) and retry.")
		os.Exit(3)
	}
	if noWindow {
		// Audio-only mode handled via env consumed by engine args builder.
		os.Setenv("LINKPLAYER_NODISP", "1")
	}
	done := make(chan services.Phase, 8)
	unsub := a.coord.Subscribe(func(p services.Phase) { done <- p })
	defer unsub()

	a.coord.Open(raw)

	last := services.Phase{}
	select {
	case last = <-done:
	case <-time.After(60 * time.Second):
		fmt.Fprintln(os.Stderr, "Timed out waiting for playback to start.")
		a.coord.Stop()
		os.Exit(4)
	}
	if last.Kind == services.PhaseFailed {
		fmt.Printf("✗ %s\n", friendly(last.Error))
		os.Exit(1)
	}
	if last.Kind != services.PhasePlaying {
		fmt.Printf("Unexpected state: %s\n", last.Kind)
		os.Exit(1)
	}
	fmt.Printf("▶ Playing %s\n", shortTitle(last.URL))
	fmt.Println("Ctrl+C to stop.")

	// Wait until natural end, another phase change (engine failure) or SIGINT.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.TERM)
	for {
		select {
		case p := <-done:
			switch p.Kind {
			case services.PhaseFailed:
				fmt.Printf("\n✗ %s\n", friendly(p.Error))
				os.Exit(1)
			case services.PhaseStopped:
				fmt.Println("\n■ Stopped.")
				return
			}
		case <-sig:
			fmt.Println("\nStopping…")
			a.coord.Stop()
			return
		}
	}
}

func printHistory(h *infra.HistoryManager) {
	entries := h.All()
	if len(entries) == 0 {
		fmt.Println("History is empty.")
		return
	}
	for i, e := range entries {
		u := mustParse(e.URL)
		fmt.Printf("%2d. %-28s %s  (%s)\n", i+1,
			truncateRunes(domain.DisplayTitle(u), 28),
			e.URL,
			e.OpenedAt.Local().Format("2006-01-02 15:04"))
	}
}

func friendly(err *domain.PlaybackError) string {
	if err == nil {
		return "Unknown error."
	}
	return err.UserMessage()
}

func asPlaybackErr(err error) *domain.PlaybackError {
	if pe, ok := err.(*domain.PlaybackError); ok {
		return pe
	}
	return services.ClassifyTransportError(err)
}

func orNone(s string) string {
	if s == "" {
		return "no content type"
	}
	return s
}

func shortTitle(raw string) string {
	u := mustParse(raw)
	t := domain.DisplayTitle(u)
	if r := []rune(t); len(r) > 50 {
		return string(r[:50]) + "…"
	}
	return t
}

func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s + strings.Repeat(" ", max(0, n-len(r)))
	}
	return string(r[:n-1]) + "…"
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func usage() {
	fmt.Print(`LinkPlayer — minimal media link player (Linux edition)

Usage:
  linkplayer                          interactive terminal UI
  linkplayer <url>                    open URL in the terminal UI
  linkplayer --play <url>             CLI: validate → probe → play via ffplay
  linkplayer --check <url>            validate & classify only (no playback)
  linkplayer --history                show recently opened links
  linkplayer --clear-history          delete all history
Options:
  --no-window                         audio-only playback (no video window)
  --volume N                          set volume 0..100 (persisted)

Supported: direct media files (.mp4/.m4v/.mov/.m4a…) and HLS streams (.m3u8)
that FFmpeg can decode and that do not require authorization or DRM.
`)
}
