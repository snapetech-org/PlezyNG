package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestBrowserOriginPolicy(t *testing.T) {
	t.Setenv(browserOriginsEnv, "https://pleazyng.app,https://www.pleazyng.app,http://localhost:3000")
	tests := []struct {
		name    string
		origins []string
		want    bool
	}{
		{name: "native client", want: true},
		{name: "configured app", origins: []string{"https://pleazyng.app"}, want: true},
		{name: "configured www app", origins: []string{"https://www.pleazyng.app"}, want: true},
		{name: "configured local development", origins: []string{"http://localhost:3000"}, want: true},
		{name: "unlisted website", origins: []string{"https://attacker.example"}},
		{name: "null origin", origins: []string{"null"}},
		{name: "origin with path", origins: []string{"https://pleazyng.app/"}},
		{name: "duplicate origins", origins: []string{"https://pleazyng.app", "https://attacker.example"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "https://pleazyng-api.snape.tech/logs", nil)
			for _, origin := range tt.origins {
				r.Header.Add("Origin", origin)
			}
			if got := browserOriginAllowed(r); got != tt.want {
				t.Fatalf("browserOriginAllowed() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestAnonymousRelayRejectsUntrustedBrowserOrigin(t *testing.T) {
	h := newRelayHarnessNoTrust(t)
	headers := http.Header{"Origin": {"https://attacker.example"}}
	conn, response, err := websocket.DefaultDialer.Dial(h.wsURL, headers)
	if conn != nil {
		_ = conn.Close()
		t.Fatal("relay accepted an untrusted browser origin")
	}
	if err == nil || response == nil || response.StatusCode != http.StatusForbidden {
		t.Fatalf("relay response = %#v, error = %v; want 403", response, err)
	}
}

func TestAnonymousUploadsRejectUntrustedBrowserOriginBeforeStorage(t *testing.T) {
	t.Setenv(browserOriginsEnv, defaultBrowserOrigins)
	logs := newLogStore(t.TempDir())
	posters := newPosterStore(t.TempDir(), maxPosterStoreSize, posterMaxAge)
	h := newStorageHarness(t, logs, posters)
	for _, tt := range []struct {
		path string
		body []byte
	}{
		{path: "/logs", body: []byte("diagnostic content")},
		{path: "/posters", body: bytes.Clone(minimalPNG)},
	} {
		t.Run(strings.TrimPrefix(tt.path, "/"), func(t *testing.T) {
			req, err := http.NewRequest(http.MethodPost, h.baseURL+tt.path, bytes.NewReader(tt.body))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Origin", "https://attacker.example")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusForbidden {
				t.Fatalf("status = %d, want 403", resp.StatusCode)
			}
		})
	}
	if len(logs.entries) != 0 || len(posters.entries) != 0 {
		t.Fatalf("rejected uploads changed storage: logs=%d posters=%d", len(logs.entries), len(posters.entries))
	}
}
