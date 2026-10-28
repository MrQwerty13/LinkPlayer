package services

import (
	"context"
	"errors"
	"net/url"
	"sync"

	"linkplayer.local/go/internal/domain"
)

// PhaseKind enumerates transport/playback states (mirrors Swift PlaybackPhase).
type PhaseKind int

const (
	PhaseIdle PhaseKind = iota
	PhaseValidating
	PhaseLoading
	PhasePlaying
	PhasePaused
	PhaseFailed
	PhaseStopped
)

func (p PhaseKind) String() string {
	switch p {
	case PhaseIdle:
		return "idle"
	case PhaseValidating:
		return "validating"
	case PhaseLoading:
		return "loading"
	case PhasePlaying:
		return "playing"
	case PhasePaused:
		return "paused"
	case PhaseFailed:
		return "failed"
	case PhaseStopped:
		return "stopped"
	}
	return "?"
}

// Phase is a state-machine snapshot: kind plus optional URL/error.
type Phase struct {
	Kind  PhaseKind
	URL   string
	Error *domain.PlaybackError
}

// Engine abstracts the concrete media backend (ffplay/mpv/AVPlayer-like).
// Play starts playback of the item; failures observed after start are funneled
// back through the onFailure callback (decode errors, missing codecs…).
type Engine interface {
	Play(ctx context.Context, rawURL string, onFailure func(*domain.PlaybackError)) error
	Pause() error
	Resume() error
	Stop() error       // idempotent: stops and releases the current resource
	Suspend() error    // stop process but keep position for resume
	Position() float64 // seconds, best effort (0 when unknown)
	Duration() float64 // seconds, -1 when unknown
	Volume() int
	SetVolume(v int)
}

// SettingsView is the read-only snapshot of user preferences the coordinator
// consumes (dependency injection keeps core testable without disk access).
type SettingsView struct {
	HistoryEnabled     bool
	AllowsInsecureHTTP bool
	AutoPlayOnOpen     bool
	Volume             int
}

// Recorder receives successfully opened links (device-only history sink).
type Recorder interface {
	Record(rawURL string)
}

// Coordinator orchestrates: validate → resolve → classify → play → record.
// Cancellation-safe; opening a new resource always stops the previous one first.
type Coordinator struct {
	mu sync.Mutex

	validator *domain.URLValidator
	resolver  Resolver
	detector  domain.KindDetector
	engine    Engine
	recorder  Recorder
	settings  func() SettingsView

	phase      Phase
	openCancel context.CancelFunc
	generation int

	listeners []func(Phase)
}

// NewCoordinator wires dependencies (composition root / DI).
func NewCoordinator(validator *domain.URLValidator, resolver Resolver,
	engine Engine, recorder Recorder, settings func() SettingsView) *Coordinator {
	return &Coordinator{
		validator: validator,
		resolver:  resolver,
		detector:  domain.KindDetector{},
		engine:    engine,
		recorder:  recorder,
		settings:  settings,
		phase:     Phase{Kind: PhaseIdle},
	}
}

// Subscribe registers a phase-change listener; returns unsubscribe func.
func (c *Coordinator) Subscribe(fn func(Phase)) func() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.listeners = append(c.listeners, fn)
	idx := len(c.listeners) - 1
	return func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if idx < len(c.listeners) {
			c.listeners = append(c.listeners[:idx], c.listeners[idx+1:]...)
		}
	}
}

// Phase returns the current state snapshot.
func (c *Coordinator) Phase() Phase {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.phase
}

// Open is the UI entry point: raw text typed/pasted by the user. Any previous
// open operation is cancelled and the current resource stopped.
func (c *Coordinator) Open(rawText string) {
	c.mu.Lock()
	if c.openCancel != nil {
		c.openCancel()
	}
	c.generation++
	gen := c.generation
	ctx, cancel := context.WithCancel(context.Background())
	c.openCancel = cancel
	c.mu.Unlock()

	go c.runOpen(ctx, gen, rawText)
}

// TogglePlayPause flips playing ⇄ paused.
func (c *Coordinator) TogglePlayPause() {
	c.mu.Lock()
	phase := c.phase
	c.mu.Unlock()

	switch phase.Kind {
	case PhasePlaying:
		if err := c.engine.Pause(); err == nil {
			c.transition(Phase{Kind: PhasePaused, URL: phase.URL})
		}
	case PhasePaused:
		if err := c.engine.Resume(); err == nil {
			c.transition(Phase{Kind: PhasePlaying, URL: phase.URL})
		}
	}
}

// Stop cancels any in-flight open and tears down current playback.
func (c *Coordinator) Stop() {
	c.mu.Lock()
	if c.openCancel != nil {
		c.openCancel()
		c.openCancel = nil
	}
	c.generation++
	c.mu.Unlock()

	c.engine.Stop()
	c.transition(Phase{Kind: PhaseStopped})
}

// Seek requests repositioning (engine-level; GUI/CLI thin wrappers call it).
func (c *Coordinator) Seek(seconds float64) {
	// ffplay has no IPC seek; engines that support it implement it here.
	_ = seconds
}

func (c *Coordinator) runOpen(ctx context.Context, gen int, rawText string) {
	// 1. Stop whatever is currently playing before touching the network.
	c.engine.Stop()
	c.transitionGuarded(gen, Phase{Kind: PhaseValidating})

	// 2. Cheap synchronous validation of untrusted input.
	u, err := c.validator.Validate(rawText)
	if err != nil {
		c.failCtx(ctx, gen, normalizeResolveError(err))
		return
	}
	if ctx.Err() != nil {
		c.finishCancelled(gen)
		return
	}

	// 3. Resolve redirects & content type without downloading the media.
	c.transitionGuarded(gen, Phase{Kind: PhaseLoading, URL: u.String()})
	resolved, err := c.resolver.Resolve(ctx, u.String())
	if err != nil {
		c.failCtx(ctx, gen, normalizeResolveError(err))
		return
	}
	if ctx.Err() != nil {
		c.finishCancelled(gen)
		return
	}

	finalURL, err := parseURL(resolved.FinalURL)
	if err != nil {
		c.failCtx(ctx, gen, domain.New(domain.KindNetworkFailure, err.Error()))
		return
	}

	// 4. Classify honestly: HTML pages are NOT presented as streams.
	kind := c.detector.Detect(finalURL, resolved.ContentType)
	if !kind.IsDirectlyPlayable() {
		c.failCtx(ctx, gen, domain.NewWithExtra(domain.KindNotAMediaResource,
			resolved.FinalURL, resolved.ContentType))
		return
	}

	// 5. Hand off to the media engine. Engine-level failures observed after
	// start are funneled back into this state machine.
	onFailure := func(e *domain.PlaybackError) {
		c.handleEngineFailure(gen, e)
	}
	playCtx, playCancel := context.WithCancel(context.Background())
	if err := c.engine.Play(playCtx, resolved.FinalURL, onFailure); err != nil {
		playCancel()
		c.failCtx(ctx, gen, normalizeResolveError(err))
		return
	}
	// Keep playCancel reachable for Stop(): store under lock.
	c.mu.Lock()
	if gen != c.generation {
		c.mu.Unlock()
		playCancel()
		return
	}
	prev := c.openCancel
	c.openCancel = func() {
		if prev != nil {
			prev()
		}
		playCancel()
	}
	c.mu.Unlock()

	c.transitionGuarded(gen, Phase{Kind: PhasePlaying, URL: resolved.FinalURL})

	// 6. Local history (device-only, sanitized at storage layer).
	if c.settings != nil && c.settings().HistoryEnabled && c.recorder != nil {
		c.recorder.Record(resolved.FinalURL)
	}
}

// handleEngineFailure ignores stale callbacks from a previous session.
func (c *Coordinator) handleEngineFailure(gen int, e *domain.PlaybackError) {
	c.mu.Lock()
	stale := gen != c.generation
	notPlaying := c.phase.Kind != PhasePlaying
	c.mu.Unlock()
	if stale || notPlaying {
		return
	}
	c.transition(Phase{Kind: PhaseFailed, Error: e})
}

func (c *Coordinator) failCtx(ctx context.Context, gen int, err *domain.PlaybackError) {
	if ctx.Err() != nil || errors.Is(err, context.Canceled) || err.Kind == domain.KindCancelled {
		c.finishCancelled(gen)
		return
	}
	c.transitionGuarded(gen, Phase{Kind: PhaseFailed, Error: err})
}

func (c *Coordinator) finishCancelled(gen int) {
	c.transitionGuarded(gen, Phase{Kind: PhaseStopped})
}

// transitionGuarded drops transitions from superseded operations.
func (c *Coordinator) transitionGuarded(gen int, p Phase) {
	c.mu.Lock()
	stale := gen != c.generation
	c.mu.Unlock()
	if stale {
		return
	}
	c.transition(p)
}

func (c *Coordinator) transition(p Phase) {
	c.mu.Lock()
	c.phase = p
	listeners := append([]func(Phase){}, c.listeners...)
	c.mu.Unlock()
	for _, fn := range listeners {
		fn(p)
	}
}

// normalizeResolveError passes *PlaybackError through, classifies the rest.
func normalizeResolveError(err error) *domain.PlaybackError {
	var pe *domain.PlaybackError
	if errors.As(err, &pe) {
		return pe
	}
	return ClassifyTransportError(err)
}

// CurrentStatus is a convenience snapshot for CLI/GUI rendering.
type CurrentStatus struct {
	Phase    Phase
	KindName string
	Position float64
	Duration float64
	Volume   int
}

// Status combines phase + engine metrics with a short settle delay allowance.
func (c *Coordinator) Status() CurrentStatus {
	ph := c.Phase()
	st := CurrentStatus{Phase: ph, Position: c.engine.Position(), Volume: c.engine.Volume()}
	if ph.Kind == PhasePlaying || ph.Kind == PhasePaused {
		st.Duration = c.engine.Duration()
	}
	return st
}

func parseURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" {
		return nil, errors.New("invalid final URL")
	}
	return u, nil
}
