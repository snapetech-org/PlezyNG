package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAbuseGuardEscalatesAndPersistsHashedBans(t *testing.T) {
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	statePath := filepath.Join(t.TempDir(), "abuse.json")
	guard, err := newAbuseGuard(statePath, now)
	if err != nil {
		t.Fatalf("newAbuseGuard: %v", err)
	}
	ip := "198.51.100.22"
	for i := 0; i < abuseStrikeThreshold-1; i++ {
		if until := guard.recordViolation(ip, now); !until.IsZero() {
			t.Fatalf("strike %d unexpectedly banned until %v", i+1, until)
		}
	}
	firstBan := guard.recordViolation(ip, now)
	if want := now.Add(15 * time.Minute); !firstBan.Equal(want) {
		t.Fatalf("first ban until=%v, want %v", firstBan, want)
	}
	contents, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read persisted state: %v", err)
	}
	if strings.Contains(string(contents), ip) {
		t.Fatal("persisted abuse state contains a raw client address")
	}
	info, err := os.Stat(statePath)
	if err != nil {
		t.Fatalf("stat persisted state: %v", err)
	}
	if info.Mode().Perm()&0077 != 0 {
		t.Fatalf("persisted state permissions=%#o, want owner-only", info.Mode().Perm())
	}

	restarted, err := newAbuseGuard(statePath, now.Add(16*time.Minute))
	if err != nil {
		t.Fatalf("reload abuse guard: %v", err)
	}
	if until := restarted.bannedUntil(ip, now.Add(16*time.Minute)); !until.IsZero() {
		t.Fatalf("expired ban remains active until %v", until)
	}
	secondBanTime := now.Add(16 * time.Minute)
	for i := 0; i < abuseStrikeThreshold-1; i++ {
		restarted.recordViolation(ip, secondBanTime)
	}
	secondBan := restarted.recordViolation(ip, secondBanTime)
	if want := secondBanTime.Add(time.Hour); !secondBan.Equal(want) {
		t.Fatalf("second ban until=%v, want %v", secondBan, want)
	}
}

func TestAbuseGuardRejectsMissingHashKeyForExistingState(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "abuse.json")
	if err := os.WriteFile(statePath, []byte(`{"version":1,"bans":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := newAbuseGuard(statePath, time.Now()); err == nil {
		t.Fatal("newAbuseGuard succeeded without the hash key for existing state")
	}
}

func TestAbuseGuardSharesRelayMessageBudgetAcrossConnections(t *testing.T) {
	now := time.Now()
	guard, err := newAbuseGuard(filepath.Join(t.TempDir(), "abuse.json"), now)
	if err != nil {
		t.Fatal(err)
	}
	ip := "203.0.113.40"
	for i := 0; i < abuseRelayMessageBurst; i++ {
		if !guard.allowRelayMessage(ip, now) {
			t.Fatalf("shared message %d denied inside burst", i+1)
		}
	}
	if guard.allowRelayMessage(ip, now) {
		t.Fatal("shared per-IP relay bucket allowed traffic beyond its burst")
	}
	if !guard.allowRelayMessage("203.0.113.41", now) {
		t.Fatal("one source exhausted another source's bucket")
	}
	refilled := now.Add(time.Second)
	for i := 0; i < abuseRelayMessageRate; i++ {
		if !guard.allowRelayMessage(ip, refilled) {
			t.Fatalf("message %d denied after one second of refill", i+1)
		}
	}
	if guard.allowRelayMessage(ip, refilled) {
		t.Fatal("shared per-IP relay bucket exceeded its sustained rate")
	}
}

func TestAbuseGuardMiddlewareAppliesTimedBanAndKeepsHealthReachable(t *testing.T) {
	guard, err := newAbuseGuard(filepath.Join(t.TempDir(), "abuse.json"), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	resolver := newClientIPResolver(nil)
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	handler := guard.middleware(next, resolver)
	request := func(path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, "http://relay.example"+path, nil)
		r.RemoteAddr = "203.0.113.50:45678"
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	for i := 0; i < abuseHTTPBurst; i++ {
		if got := request("/api").Code; got != http.StatusNoContent {
			t.Fatalf("request %d status=%d, want 204", i+1, got)
		}
	}
	for i := 0; i < abuseStrikeThreshold; i++ {
		if got := request("/api").Code; got != http.StatusTooManyRequests {
			t.Fatalf("excess request %d status=%d, want 429", i+1, got)
		}
	}
	banned := request("/api")
	if banned.Code != http.StatusTooManyRequests || banned.Header().Get("Retry-After") == "" {
		t.Fatalf("active ban response status=%d Retry-After=%q", banned.Code, banned.Header().Get("Retry-After"))
	}
	if got := request("/health").Code; got != http.StatusNoContent {
		t.Fatalf("health status=%d while source is banned, want 204", got)
	}
}

func TestAbuseGuardCountsMarkedEndpointRateLimits(t *testing.T) {
	guard, err := newAbuseGuard(filepath.Join(t.TempDir(), "abuse.json"), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		markRateLimit(w, "Rate limited", time.Second)
	})
	handler := guard.middleware(next, newClientIPResolver(nil))
	for i := 0; i < abuseStrikeThreshold; i++ {
		r := httptest.NewRequest(http.MethodGet, "http://relay.example/resource", nil)
		r.RemoteAddr = "203.0.113.60:45678"
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != http.StatusTooManyRequests {
			t.Fatalf("marked rate response %d status=%d, want 429", i+1, w.Code)
		}
		if w.Header().Get(abuseRateLimitSignal) != "" {
			t.Fatal("internal abuse marker leaked to the client")
		}
	}
	r := httptest.NewRequest(http.MethodGet, "http://relay.example/resource", nil)
	r.RemoteAddr = "203.0.113.60:45678"
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != http.StatusTooManyRequests || !strings.Contains(w.Body.String(), "Temporarily blocked") {
		t.Fatalf("marked source limits did not activate ban: status=%d body=%q", w.Code, w.Body.String())
	}
}
