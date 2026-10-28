package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"linkplayer.local/go/internal/domain"
	"linkplayer.local/go/internal/infra"
	"linkplayer.local/go/internal/services"
)

// runTUI is the interactive terminal front-end. It contains no business
// logic: every action is a thin dispatch into the coordinator/managers, so
// the same flows are covered by unit tests of those components.
func runTUI(a *app) {
	fmt.Println("LinkPlayer — type a media URL and press Enter.")
	fmt.Println("Commands: <url> open | play/pause | stop | vol N | history | clear-history | http on|off | q quit")
	fmt.Println(strings.Repeat("─", 64))

	phaseCh := make(chan services.Phase, 16)
	unsub := a.coord.Subscribe(func(p services.Phase) {
		select {
		case phaseCh <- p:
		default:
		}
	})
	defer unsub()

	// Launch behavior from Settings (real effect, not decorative).
	switch a.settings.Snapshot().LaunchBehavior {
	case infra.LaunchHistory:
		printHistory(a.history)
	case infra.LaunchReopen:
		if entries := a.history.All(); len(entries) > 0 {
			fmt.Printf("(launch) reopening last item…\n")
			a.coord.Open(entries[0].URL)
		}
	}

	reader := bufio.NewReader(os.Stdin)
	drainPhases(phaseCh)

	for {
		prompt()
		line, err := reader.ReadString('\n')
		if err != nil { // EOF → graceful exit
			fmt.Println()
			return
		}
		cmd := strings.TrimSpace(line)
		drainPhases(phaseCh)
		if cmd == "" {
			continue
		}

		switch {
		case cmd == "q" || cmd == "quit" || cmd == "exit":
			a.coord.Stop()
			fmt.Println("Bye.")
			return

		case cmd == "play" || cmd == "pause" || cmd == "resume":
			a.coord.TogglePlayPause()

		case cmd == "stop":
			a.coord.Stop()

		case cmd == "history":
			printHistory(a.history)

		case cmd == "clear-history":
			a.history.Clear()
			fmt.Println("History cleared.")

		case strings.HasPrefix(cmd, "vol "):
			if v, e := strconv.Atoi(strings.TrimSpace(cmd[4:])); e == nil {
				a.settings.Update(func(s *infra.Settings) { s.Volume = v })
				a.engine.SetVolume(v)
				fmt.Printf("Volume: %d\n", a.engine.Volume())
			} else {
				fmt.Println("Usage: vol 0..100")
			}

		case strings.HasPrefix(cmd, "http "):
			on := strings.TrimSpace(cmd[5:]) == "on"
			a.settings.Update(func(s *infra.Settings) { s.AllowsInsecureHTTP = on })
			a.validator.Policy.AllowsInsecureHTTP = on
			if on {
				fmt.Println("Plain HTTP links enabled (only trust sources you know).")
			} else {
				fmt.Println("Plain HTTP links disabled (HTTPS only).")
			}

		case strings.HasPrefix(cmd, "seek "):
			if secs, e := strconv.ParseFloat(strings.TrimSpace(cmd[5:]), 64); e == nil {
				a.coord.Seek(secs)
				fmt.Println("Seek requested (ffplay backend has no IPC seek; use arrow keys in its window: ←/→ 10s, ↑/↓ 1min).")
			}

		default:
			// Treat anything else as a link to open.
			a.coord.Open(cmd)
			waitForSettle(phaseCh, 3*time.Second)
		}
		drainPhases(phaseCh)
	}
}

func prompt() {
	fmt.Print("\nlinkplayer> ")
}

// drainPhases renders every state transition that arrived since last check.
func drainPhases(ch chan services.Phase) {
	for {
		select {
		case p := <-ch:
			renderPhase(p)
		default:
			return
		}
	}
}

// waitForSettle consumes phases until a terminal one or timeout.
func waitForSettle(ch chan services.Phase, d time.Duration) {
	deadline := time.After(d)
	for {
		select {
		case p := <-ch:
			renderPhase(p)
			switch p.Kind {
			case services.PhasePlaying, services.PhaseFailed, services.PhaseStopped:
				return
			}
		case <-deadline:
			return
		}
	}
}

func renderPhase(p services.Phase) {
	switch p.Kind {
	case services.PhaseValidating:
		fmt.Print("… validating link ")
	case services.PhaseLoading:
		fmt.Printf("\r… probing %s\n", truncate(p.URL, 70))
	case services.PhasePlaying:
		fmt.Printf("▶ playing: %s\n", domain.DisplayTitle(mustParse(p.URL)))
	case services.PhasePaused:
		fmt.Println("⏸ paused")
	case services.PhaseStopped:
		fmt.Println("■ stopped")
	case services.PhaseFailed:
		fmt.Printf("✗ %s\n", friendly(p.Error))
	}
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
