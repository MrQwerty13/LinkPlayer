// Package player implements the Linux media backend used by LinkPlayer.
//
// Architecture decision (see docs/ADR.md ADR-010): playback is delegated to
// ffplay (FFmpeg, LGPL/GPL) as a separate process — the same pattern mpv/VLC
// use for external streams. The app itself never links FFmpeg; it only spawns
// the binary found in PATH. No DRM or authorization is ever bypassed.
package player

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"linkplayer.local/go/internal/domain"
)

// FFplayEngine drives an ffplay subprocess and tracks its lifecycle.
// ffplay has no IPC control channel, so pause/resume suspend the process at
// OS level (SIGSTOP/SIGCONT) — frame-accurate freeze without any decoder work
// inside our code. Position/duration are probed with ffprobe when available.
type FFplayEngine struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	volume   int
	stopped  chan struct{} // closed when the current process exits
	startAt  time.Time     // wall clock of session start (position estimate)
	duration float64       // probed duration in seconds (-1 unknown)
}

// NewFFplayEngine creates an engine with default volume.
func NewFFplayEngine() *FFplayEngine {
	return &FFplayEngine{volume: 80}
}

// Available reports whether ffplay exists in PATH.
func Available() bool {
	_, err := exec.LookPath("ffplay")
	return err == nil
}

// Play launches ffplay for the given URL. Returns as soon as the process has
// started successfully; runtime failures are reported through onFailure.
func (e *FFplayEngine) Play(ctx context.Context, rawURL string, onFailure func(*domain.PlaybackError)) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if err := e.stopLocked(); err != nil {
		return err
	}

	binary, err := exec.LookPath("ffplay")
	if err != nil {
		return domain.New(domain.KindDecodingFailed,
			"ffplay was not found in PATH. Install FFmpeg (e.g. your distribution's ffmpeg package).")
	}

	args := []string{
		"-loglevel", "error",
		"-volume", strconv.Itoa(e.volumeLinear()),
		rawURL,
	}
	cmd := exec.Command(binary, args...)
	cmd.Stdout = nil
	// Capture stderr tail for diagnostics without logging full URLs' secrets.
	errBuf := &limitedBuffer{max: 4096}
	cmd.Stderr = errBuf

	if err := cmd.Start(); err != nil {
		return domain.New(domain.KindNetworkFailure, err.Error())
	}

	e.cmd = cmd
	e.stopped = make(chan struct{})
	e.startAt = time.Now()
	e.duration = -1
	done := e.stopped
	pid := cmd.Process.Pid

	go func() {
		waitErr := cmd.Wait()
		close(done)
		// Determine whether this failure belongs to the still-current session.
		e.mu.Lock()
		current := e.cmd != nil && e.cmd.Process != nil && e.cmd.Process.Pid == pid
		if current {
			e.cmd = nil
		}
		e.mu.Unlock()

		if waitErr != nil && current && onFailure != nil {
			detail := strings.TrimSpace(errBuf.String())
			if detail == "" {
				detail = waitErr.Error()
			}
			onFailure(decodeFFplayFailure(detail, waitErr))
		}
	}()

	return nil
}

// Pause freezes playback by stopping the process at OS level (SIGSTOP).
func (e *FFplayEngine) Pause() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.cmd == nil || e.cmd.Process == nil {
		return fmt.Errorf("no active playback session")
	}
	return e.cmd.Process.Signal(sigStop())
}

// Resume unfreezes a paused process (SIGCONT).
func (e *FFplayEngine) Resume() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.cmd == nil || e.cmd.Process == nil {
		return fmt.Errorf("no active playback session")
	}
	return e.cmd.Process.Signal(sigCont())
}

// Stop terminates the current ffplay process and waits briefly for exit.
func (e *FFplayEngine) Stop() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stopLocked()
}

// Wait blocks until the current playback session ends (used by CLI mode).
func (e *FFplayEngine) Wait() {
	e.mu.Lock()
	ch := e.stopped
	e.mu.Unlock()
	if ch != nil {
		<-ch
	}
}

// HasSession reports whether a playback process is currently running.
func (e *FFplayEngine) HasSession() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.cmd != nil
}

// Position is best-effort: wall clock since session start, capped by probed
// duration when known. Live streams report 0 (indeterminate UI state).
func (e *FFplayEngine) Position() float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.cmd == nil || e.duration < 0 {
		return 0
	}
	pos := time.Since(e.startAt).Seconds()
	if pos > e.duration {
		return e.duration
	}
	return pos
}

// Duration returns the ffprobe-derived duration (-1 when unknown/live).
func (e *FFplayEngine) Duration() float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.duration
}

// SetProbedDuration stores an externally probed duration for display.
func (e *FFplayEngine) SetProbedDuration(seconds float64) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.duration = seconds
}

// Volume returns the logical 0…100 volume.
func (e *FFplayEngine) Volume() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.volume
}

// SetVolume stores volume; applied on next play (ffplay has no IPC volume).
func (e *FFplayEngine) SetVolume(v int) {
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.volume = v
	// If a session is live, restart is NOT forced — keep UX stable.
}

func (e *FFplayEngine) volumeLinear() int { return e.volume } // ffplay -volume: 0..~100 linear

func (e *FFplayEngine) stopLocked() error {
	if e.cmd == nil || e.cmd.Process == nil {
		return nil
	}
	p := e.cmd.Process
	_ = p.Kill()
	e.cmd = nil
	return nil
}

// decodeFFplayFailure maps common ffplay stderr signatures to PlaybackError.
func decodeFFplayFailure(detail string, waitErr error) *domain.PlaybackError {
	l := strings.ToLower(detail)
	switch {
	case strings.Contains(l, "403 forbidden"), strings.Contains(l, "401 unauthorized"):
		return domain.New(domain.KindUnauthorized, "")
	case strings.Contains(l, "404 not found"):
		return domain.New(domain.KindNotFound, "404")
	case strings.Contains(l, "drm"), strings.Contains(l, "decryption failed"):
		return domain.New(domain.KindDRMProtected, "")
	case strings.Contains(l, "timed out"), strings.Contains(l, "timeout"):
		return domain.New(domain.KindTimedOut, "")
	case strings.Contains(l, "invalid data found"), strings.Contains(l, "moov atom not found"):
		return domain.New(domain.KindDecodingFailed, firstLine(detail))
	}
	if waitErr != nil {
		return domain.New(domain.KindDecodingFailed, firstLine(detail))
	}
	return domain.New(domain.KindDecodingFailed, firstLine(detail))
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	if len(s) > 200 {
		return s[:200]
	}
	return s
}

// limitedBuffer captures the last bytes of output without unbounded growth.
type limitedBuffer struct {
	max int
	buf []byte
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	b.buf = append(b.buf, p...)
	if len(b.buf) > b.max {
		b.buf = b.buf[len(b.buf)-b.max:]
	}
	return len(p), nil
}

func (b *limitedBuffer) String() string { return string(b.buf) }

// ProbeDuration uses ffprobe (same FFmpeg install) to learn media duration
// for display purposes; purely informational, never required for playback.
func ProbeDuration(ctx context.Context, rawURL string) (time.Duration, error) {
	binary, err := exec.LookPath("ffprobe")
	if err != nil {
		return 0, fmt.Errorf("ffprobe not found")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary,
		"-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", rawURL)
	out, err := cmd.Output()
	if err != nil {
		return 0, err
	}
	secs, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil {
		return 0, err
	}
	return time.Duration(secs * float64(time.Second)), nil
}
