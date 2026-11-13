package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	abuseHTTPBurst          = 120
	abuseHTTPSustained      = 30
	abuseHandshakeBurst     = 5
	abuseHandshakeSustained = 1
	abuseRelayMessageBurst  = maxConnsPerIP * rateBurst
	abuseRelayMessageRate   = maxConnsPerIP * rateSustained
	abuseSteamFrameBurst    = 2000
	abuseSteamFrameRate     = 1000
	abuseStrikeWindow       = 15 * time.Minute
	abuseStrikeThreshold    = 10
	abuseBanRetention       = 30 * 24 * time.Hour
	abusePersistMinInterval = time.Second
	abuseMaxSources         = 8192
	abuseMaxPersistedBans   = 4096
	abuseMaxStateBytes      = 1 << 20
	abuseKeyBytes           = 32
	abuseRateLimitSignal    = "X-Pleazyng-Abuse-Signal"
	abusePersistedStateVer  = 1
)

var abuseBanDurations = [...]time.Duration{15 * time.Minute, time.Hour, 24 * time.Hour}

type abuseSource struct {
	httpRate         *rateLimiter
	handshakeRate    *rateLimiter
	relayRate        *rateLimiter
	steamFrameRate   *rateLimiter
	strikeStart      time.Time
	strikes          int
	relayConnections int
	lastSeen         time.Time
}

type abuseBan struct {
	Level       int       `json:"level"`
	BannedUntil time.Time `json:"banned_until"`
	LastBanned  time.Time `json:"last_banned"`
}

type persistedAbuseBan struct {
	SourceHash  string    `json:"source_hash"`
	Level       int       `json:"level"`
	BannedUntil time.Time `json:"banned_until"`
	LastBanned  time.Time `json:"last_banned"`
}

type persistedAbuseState struct {
	Version int                 `json:"version"`
	Bans    []persistedAbuseBan `json:"bans"`
}

// abuseGuard keeps raw client addresses only in a bounded in-memory table.
// The durable state contains keyed HMACs, never the source addresses.
type abuseGuard struct {
	mu          sync.Mutex
	state       map[string]*abuseSource
	bans        map[string]abuseBan
	key         []byte
	statePath   string
	keyPath     string
	lastPersist time.Time
	dirty       bool
}

func optionalAbuseGuard(guards []*abuseGuard) *abuseGuard {
	if len(guards) == 0 {
		return nil
	}
	return guards[0]
}

func newAbuseGuard(statePath string, now time.Time) (*abuseGuard, error) {
	if strings.TrimSpace(statePath) == "" {
		return nil, errors.New("abuse state path is empty")
	}
	g := &abuseGuard{
		state:     make(map[string]*abuseSource),
		bans:      make(map[string]abuseBan),
		statePath: statePath,
		keyPath:   statePath + ".key",
	}
	if _, stateErr := os.Lstat(g.statePath); stateErr == nil {
		if _, keyErr := os.Lstat(g.keyPath); errors.Is(keyErr, os.ErrNotExist) {
			return nil, errors.New("abuse hash key is missing while abuse state exists")
		} else if keyErr != nil {
			return nil, fmt.Errorf("inspect abuse hash key: %w", keyErr)
		}
	} else if !errors.Is(stateErr, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect abuse state: %w", stateErr)
	}
	key, err := loadOrCreateAbuseKey(g.keyPath)
	if err != nil {
		return nil, fmt.Errorf("load abuse hash key: %w", err)
	}
	g.key = key
	if err := g.loadState(now); err != nil {
		return nil, fmt.Errorf("load abuse state: %w", err)
	}
	return g, nil
}

func loadOrCreateAbuseKey(path string) ([]byte, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	load := func() ([]byte, error) {
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() != abuseKeyBytes {
			return nil, errors.New("abuse key must be a private regular file containing 32 bytes")
		}
		key, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		if len(key) != abuseKeyBytes {
			return nil, errors.New("abuse key has an invalid length")
		}
		return key, nil
	}
	if key, err := load(); err == nil {
		return key, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key := make([]byte, abuseKeyBytes)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if errors.Is(err, os.ErrExist) {
		return load()
	}
	if err != nil {
		return nil, err
	}
	if _, err = file.Write(key); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		_ = os.Remove(path)
		return nil, err
	}
	if closeErr != nil {
		_ = os.Remove(path)
		return nil, closeErr
	}
	if err := syncDirectory(filepath.Dir(path)); err != nil {
		return nil, err
	}
	return key, nil
}

func (g *abuseGuard) sourceHash(ip string) string {
	mac := hmac.New(sha256.New, g.key)
	_, _ = mac.Write([]byte(ip))
	return hex.EncodeToString(mac.Sum(nil))
}

func (g *abuseGuard) loadState(now time.Time) error {
	info, err := os.Lstat(g.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > abuseMaxStateBytes {
		return errors.New("abuse state must be a private regular file smaller than 1 MiB")
	}
	f, err := os.Open(g.statePath)
	if err != nil {
		return err
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, abuseMaxStateBytes+1))
	dec.DisallowUnknownFields()
	var data persistedAbuseState
	if err := dec.Decode(&data); err != nil {
		return err
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("abuse state contains trailing JSON")
		}
		return err
	}
	if data.Version != abusePersistedStateVer || len(data.Bans) > abuseMaxPersistedBans {
		return errors.New("abuse state version or ban count is invalid")
	}
	for _, item := range data.Bans {
		if len(item.SourceHash) != sha256.Size*2 || item.Level < 1 || item.Level > len(abuseBanDurations) || item.BannedUntil.IsZero() || item.LastBanned.IsZero() {
			return errors.New("abuse state contains an invalid ban record")
		}
		if _, err := hex.DecodeString(item.SourceHash); err != nil || item.SourceHash != strings.ToLower(item.SourceHash) {
			return errors.New("abuse state contains an invalid source hash")
		}
		if now.Sub(item.LastBanned) >= abuseBanRetention {
			continue
		}
		g.bans[item.SourceHash] = abuseBan{Level: item.Level, BannedUntil: item.BannedUntil, LastBanned: item.LastBanned}
	}
	return nil
}

func (g *abuseGuard) persistLocked(now time.Time) error {
	items := make([]persistedAbuseBan, 0, len(g.bans))
	for hash, ban := range g.bans {
		items = append(items, persistedAbuseBan{SourceHash: hash, Level: ban.Level, BannedUntil: ban.BannedUntil, LastBanned: ban.LastBanned})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].SourceHash < items[j].SourceHash })
	if len(items) > abuseMaxPersistedBans {
		return errors.New("abuse ban table is full")
	}
	data, err := json.Marshal(persistedAbuseState{Version: abusePersistedStateVer, Bans: items})
	if err != nil {
		return err
	}
	if len(data) > abuseMaxStateBytes {
		return errors.New("abuse state exceeds 1 MiB")
	}
	dir := filepath.Dir(g.statePath)
	tmp, err := os.CreateTemp(dir, ".abuse-state-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, g.statePath); err != nil {
		return err
	}
	if err := syncDirectory(dir); err != nil {
		return err
	}
	g.lastPersist = now
	g.dirty = false
	return nil
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (g *abuseGuard) sourceLocked(ip string, now time.Time) *abuseSource {
	source := g.state[ip]
	if source != nil {
		source.lastSeen = now
		return source
	}
	if len(g.state) >= abuseMaxSources {
		g.cleanupLocked(now)
	}
	if len(g.state) >= abuseMaxSources {
		oldestIP := ""
		var oldest time.Time
		for candidateIP, candidate := range g.state {
			if candidate.relayConnections > 0 {
				continue
			}
			// Prefer entries with no pending strikes; an old, quiet source is
			// the least harmful state to evict when the bounded table is full.
			if oldestIP == "" || candidate.strikes == 0 && g.state[oldestIP].strikes != 0 ||
				(candidate.strikes == g.state[oldestIP].strikes && candidate.lastSeen.Before(oldest)) {
				oldestIP = candidateIP
				oldest = candidate.lastSeen
			}
		}
		if oldestIP == "" {
			return nil
		}
		delete(g.state, oldestIP)
	}
	source = &abuseSource{
		httpRate:       newRateLimiterAt(abuseHTTPBurst, abuseHTTPSustained, now),
		handshakeRate:  newRateLimiterAt(abuseHandshakeBurst, abuseHandshakeSustained, now),
		relayRate:      newRateLimiterAt(abuseRelayMessageBurst, abuseRelayMessageRate, now),
		steamFrameRate: newRateLimiterAt(abuseSteamFrameBurst, abuseSteamFrameRate, now),
		lastSeen:       now,
	}
	g.state[ip] = source
	return source
}

func (g *abuseGuard) allowHTTP(ip string, now time.Time) (bool, time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	source := g.sourceLocked(ip, now)
	if source == nil {
		return false, time.Minute
	}
	return source.httpRate.allowOrWaitAt(now)
}

func (g *abuseGuard) allowHandshake(ip string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	source := g.sourceLocked(ip, now)
	return source != nil && source.handshakeRate.allowAt(now)
}

func (g *abuseGuard) allowRelayMessage(ip string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	source := g.sourceLocked(ip, now)
	return source != nil && source.relayRate.allowAt(now)
}

func (g *abuseGuard) allowSteamFrame(ip string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	source := g.sourceLocked(ip, now)
	return source != nil && source.steamFrameRate.allowAt(now)
}

func (g *abuseGuard) addRelayConnection(ip string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	source := g.sourceLocked(ip, now)
	if source == nil {
		return false
	}
	source.relayConnections++
	return true
}

func (g *abuseGuard) removeRelayConnection(ip string, now time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if source := g.state[ip]; source != nil {
		if source.relayConnections > 0 {
			source.relayConnections--
		}
		source.lastSeen = now
	}
}

func (g *abuseGuard) bannedUntil(ip string, now time.Time) time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	ban, ok := g.bans[g.sourceHash(ip)]
	if !ok || !now.Before(ban.BannedUntil) {
		return time.Time{}
	}
	return ban.BannedUntil
}

// recordViolation applies a timed ban after repeated rate-limit or abuse
// signals. Repeat bans escalate to one hour and then one day; they never become
// permanent. The strike window is intentionally not persisted across restarts.
func (g *abuseGuard) recordViolation(ip string, now time.Time) time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	hash := g.sourceHash(ip)
	if ban, ok := g.bans[hash]; ok && now.Before(ban.BannedUntil) {
		return ban.BannedUntil
	}
	source := g.sourceLocked(ip, now)
	if source == nil {
		return time.Time{}
	}
	if source.strikeStart.IsZero() || now.Sub(source.strikeStart) >= abuseStrikeWindow || now.Before(source.strikeStart) {
		source.strikeStart = now
		source.strikes = 0
	}
	source.strikes++
	if source.strikes < abuseStrikeThreshold {
		return time.Time{}
	}
	previous, hadPrevious := g.bans[hash]
	level := 1
	if !previous.LastBanned.IsZero() && now.Sub(previous.LastBanned) < abuseBanRetention {
		level = previous.Level + 1
	}
	if level > len(abuseBanDurations) {
		level = len(abuseBanDurations)
	}
	ban := abuseBan{Level: level, BannedUntil: now.Add(abuseBanDurations[level-1]), LastBanned: now}
	if len(g.bans) < abuseMaxPersistedBans || hadPrevious {
		g.bans[hash] = ban
	} else {
		g.pruneBansLocked(now)
		if len(g.bans) < abuseMaxPersistedBans {
			g.bans[hash] = ban
		} else {
			return time.Time{}
		}
	}
	source.strikes = 0
	g.dirty = true
	if err := g.persistIfDueLocked(now); err != nil {
		// Keep the active in-memory ban in force and log the persistence failure.
		log.Printf("abuse guard: failed to persist repeat-abuse ban: %v", err)
	}
	return ban.BannedUntil
}

func (g *abuseGuard) pruneBansLocked(now time.Time) {
	for hash, ban := range g.bans {
		if now.Sub(ban.LastBanned) >= abuseBanRetention && !now.Before(ban.BannedUntil) {
			delete(g.bans, hash)
			g.dirty = true
		}
	}
}

func (g *abuseGuard) cleanup(now time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.cleanupLocked(now)
	g.pruneBansLocked(now)
	if err := g.persistIfDueLocked(now); err != nil {
		log.Printf("abuse guard: failed to persist cleanup: %v", err)
	}
}

func (g *abuseGuard) flush() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.dirty {
		return nil
	}
	return g.persistLocked(time.Now())
}

func (g *abuseGuard) persistIfDueLocked(now time.Time) error {
	if !g.dirty || !g.lastPersist.IsZero() && now.Sub(g.lastPersist) < abusePersistMinInterval {
		return nil
	}
	return g.persistLocked(now)
}

func (g *abuseGuard) cleanupLocked(now time.Time) {
	for ip, source := range g.state {
		if source.relayConnections == 0 && now.Sub(source.lastSeen) >= abuseStrikeWindow && (source.strikeStart.IsZero() || now.Sub(source.strikeStart) >= abuseStrikeWindow) {
			delete(g.state, ip)
		}
	}
}

func (g *abuseGuard) middleware(next http.Handler, resolver clientIPResolver) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health checks must remain available to the local supervisor while an
		// address is banned or the per-source table is under pressure.
		if r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}
		ip, err := resolver.resolve(r)
		if err != nil {
			http.Error(w, "Invalid client address", http.StatusBadRequest)
			return
		}
		now := time.Now()
		if until := g.bannedUntil(ip, now); !until.IsZero() {
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Retry-After", retryAfter(until.Sub(now)))
			http.Error(w, "Temporarily blocked after repeated rate-limit violations", http.StatusTooManyRequests)
			return
		}
		if allowed, wait := g.allowHTTP(ip, now); !allowed {
			until := g.recordViolation(ip, now)
			if !until.IsZero() {
				wait = until.Sub(now)
			}
			w.Header().Set("Retry-After", retryAfter(wait))
			http.Error(w, "Too many requests", http.StatusTooManyRequests)
			return
		}
		wrapped := &abuseResponseWriter{ResponseWriter: w, guard: g, ip: ip}
		next.ServeHTTP(wrapped, r)
	})
}

func retryAfter(delay time.Duration) string {
	seconds := int64(delay / time.Second)
	if delay%time.Second != 0 {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	return fmt.Sprint(seconds)
}

func markRateLimit(w http.ResponseWriter, message string, retry time.Duration) {
	w.Header().Set(abuseRateLimitSignal, "1")
	if retry > 0 {
		w.Header().Set("Retry-After", retryAfter(retry))
	}
	http.Error(w, message, http.StatusTooManyRequests)
}

func markAbuseStatus(w http.ResponseWriter, message string, status int) {
	w.Header().Set(abuseRateLimitSignal, "1")
	http.Error(w, message, status)
}

type abuseResponseWriter struct {
	http.ResponseWriter
	guard *abuseGuard
	ip    string
	wrote bool
}

func (w *abuseResponseWriter) WriteHeader(status int) {
	if w.wrote {
		return
	}
	w.wrote = true
	if w.Header().Get(abuseRateLimitSignal) == "1" {
		w.Header().Del(abuseRateLimitSignal)
		if until := w.guard.recordViolation(w.ip, time.Now()); !until.IsZero() {
			if status == http.StatusTooManyRequests {
				w.Header().Set("Retry-After", retryAfter(until.Sub(time.Now())))
			}
		}
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *abuseResponseWriter) Write(data []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

func (w *abuseResponseWriter) Flush() {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *abuseResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("underlying ResponseWriter does not support hijacking")
	}
	return h.Hijack()
}

func (w *abuseResponseWriter) Push(target string, opts *http.PushOptions) error {
	if p, ok := w.ResponseWriter.(http.Pusher); ok {
		return p.Push(target, opts)
	}
	return http.ErrNotSupported
}

func (w *abuseResponseWriter) ReadFrom(r io.Reader) (int64, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	if rf, ok := w.ResponseWriter.(io.ReaderFrom); ok {
		return rf.ReadFrom(r)
	}
	return io.Copy(struct{ io.Writer }{w.ResponseWriter}, r)
}

func (w *abuseResponseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
