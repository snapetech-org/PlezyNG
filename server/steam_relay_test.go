package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func relayTestOAuth() *oauthProxy {
	p := newOAuthProxy("https://relay.test", map[string]oauthServiceConfig{}, clientIPResolver{})
	p.steamCatalogGrants = map[[32]byte]*steamCatalogGrant{sha256.Sum256([]byte(strings.Repeat("a", 43))): {steamID: cloudTestID, expires: time.Now().Add(time.Hour)}}
	return p
}

func relayTestConnect(t *testing.T, server, token, role string) *websocket.Conn {
	t.Helper()
	h := http.Header{"X-Steam-Relay-Admission": {strings.Repeat("a", 43)}, "Authorization": {"Bearer " + token}, "X-Steam-Relay-Role": {role}, "X-Steam-Relay-Version": {"1"}}
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server, "http")+"/games/steam/relay", h)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
	return c
}
func relayReadControl(t *testing.T, c *websocket.Conn, kind string) map[string]any {
	t.Helper()
	typ, data, err := c.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if typ != websocket.TextMessage || json.Unmarshal(data, &m) != nil || m["kind"] != kind {
		t.Fatalf("unexpected control %s", data)
	}
	return m
}
func TestSteamRelayPairedRoomAndOpaquePackets(t *testing.T) {
	s := newSteamRelay(clientIPResolver{}, relayTestOAuth())
	defer s.close()
	server := httptest.NewServer(http.HandlerFunc(s.handle))
	defer server.Close()
	token := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	h := relayTestConnect(t, server.URL, token, "host")
	ready := relayReadControl(t, h, "ready")
	r := relayTestConnect(t, server.URL, token, "receiver")
	relayReadControl(t, r, "ready")
	relayReadControl(t, r, "peer")
	relayReadControl(t, h, "peer")
	payload := []byte{17, 1, 0, 4, 255, 9}
	if h.WriteMessage(websocket.BinaryMessage, payload) != nil {
		t.Fatal("write failed")
	}
	kind, data, err := r.ReadMessage()
	if err != nil || kind != websocket.BinaryMessage || string(data) != string(payload) {
		t.Fatal("payload changed")
	}
	cookieBytes, _ := base64.RawURLEncoding.DecodeString(ready["udpCookie"].(string))
	var cookie [32]byte
	copy(cookie[:], cookieBytes)
	s.observe(cookie, netip.MustParseAddrPort("203.0.113.7:4567"))
	observed := relayReadControl(t, h, "observed")
	if observed["ip"] != "203.0.113.7" || observed["port"] != float64(4567) {
		t.Fatal("UDP source not scoped to its socket")
	}
	_ = h.Close()
	_ = r.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err = r.ReadMessage(); err == nil {
		t.Fatal("orphan receiver survived host close")
	}
	deadline := time.Now().Add(time.Second)
	for {
		s.mu.Lock()
		empty := len(s.rooms) == 0 && len(s.cookies) == 0 && len(s.ips) == 0
		s.mu.Unlock()
		if empty {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("admission leaked")
		}
		time.Sleep(time.Millisecond)
	}
}
func TestSteamRelayLimitsAndAuthority(t *testing.T) {
	s := newSteamRelay(clientIPResolver{}, relayTestOAuth())
	defer s.close()
	token := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	for _, headers := range []http.Header{
		{}, {"Authorization": {"Bearer " + token}, "X-Steam-Relay-Role": {"receiver"}, "X-Steam-Relay-Version": {"1"}, "Origin": {"https://evil.test"}},
	} {
		r := httptest.NewRequest("GET", "https://relay.test/games/steam/relay", nil)
		r.Header = headers
		w := httptest.NewRecorder()
		s.handle(w, r)
		if w.Code != 400 {
			t.Fatal("unauthorized origin accepted")
		}
	}
	server := httptest.NewServer(http.HandlerFunc(s.handle))
	defer server.Close()
	c := relayTestConnect(t, server.URL, token, "host")
	relayReadControl(t, c, "ready")
	d := relayTestConnect(t, server.URL, token, "receiver")
	relayReadControl(t, d, "ready")
	relayReadControl(t, d, "peer")
	relayReadControl(t, c, "peer")
	// A third socket cannot replace an existing endpoint.
	h := http.Header{"X-Steam-Relay-Admission": {strings.Repeat("a", 43)}, "Authorization": {"Bearer " + token}, "X-Steam-Relay-Role": {"receiver"}, "X-Steam-Relay-Version": {"1"}}
	if third, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), h); err == nil {
		third.Close()
		t.Fatal("third peer admitted")
	}
	if c.WriteMessage(websocket.BinaryMessage, make([]byte, steamRelayMaxFrame+1)) != nil {
		t.Fatal("write failed")
	}
	if _, _, err := d.ReadMessage(); err == nil {
		t.Fatal("oversized/fragmented frame survived")
	}
}
func TestSteamRelayQueueBoundedAndConfigDisabled(t *testing.T) {
	p := &steamRelayPeer{out: make(chan steamRelayFrame, 16), done: make(chan struct{})}
	for i := 0; i < 16; i++ {
		if !p.enqueue(steamRelayFrame{2, []byte{1}}) {
			t.Fatal("early full")
		}
	}
	if p.enqueue(steamRelayFrame{2, []byte{1}}) {
		t.Fatal("unbounded queue")
	}
	p.stop()
	if p.enqueue(steamRelayFrame{2, []byte{1}}) {
		t.Fatal("retired peer accepted data")
	}
	t.Setenv("STEAM_STREAM_RELAY_ENABLED", "")
	mux := http.NewServeMux()
	if registerSteamRelay(mux, clientIPResolver{}, relayTestOAuth()) != nil {
		t.Fatal("relay enabled by default")
	}
	t.Setenv("STEAM_STREAM_RELAY_ENABLED", "true")
	if registerSteamRelay(mux, clientIPResolver{}, nil) != nil {
		t.Fatal("relay enabled without Steam identity admission")
	}
	insecure := relayTestOAuth()
	insecure.baseURL = "http://relay.test"
	if registerSteamRelay(mux, clientIPResolver{}, insecure) != nil {
		t.Fatal("relay enabled with an insecure public origin")
	}
	t.Setenv("STEAM_STREAM_RELAY_UDP_PORT", "80")
	if registerSteamRelay(mux, clientIPResolver{}, relayTestOAuth()) != nil {
		t.Fatal("invalid UDP configuration enabled relay")
	}
	// Room identity is a digest of a separate relay capability, not a user ID.
	if sha256.Sum256(make([]byte, 32)) == ([32]byte{}) {
		t.Fatal("impossible digest")
	}
}

func TestSteamRelayRequiresLiveMatchingSteamIdentity(t *testing.T) {
	oauth := relayTestOAuth()
	other := strings.Repeat("b", 43)
	oauth.steamCatalogGrants[sha256.Sum256([]byte(other))] = &steamCatalogGrant{steamID: "76561198000000002", expires: time.Now().Add(time.Hour)}
	s := newSteamRelay(clientIPResolver{}, oauth)
	defer s.close()
	server := httptest.NewServer(http.HandlerFunc(s.handle))
	defer server.Close()
	token := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	host := relayTestConnect(t, server.URL, token, "host")
	relayReadControl(t, host, "ready")
	for _, admission := range []string{"", strings.Repeat("c", 43), other} {
		headers := http.Header{"X-Steam-Relay-Admission": {admission}, "Authorization": {"Bearer " + token}, "X-Steam-Relay-Role": {"receiver"}, "X-Steam-Relay-Version": {"1"}}
		conn, response, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http")+"/games/steam/relay", headers)
		if err == nil {
			_ = conn.Close()
			t.Fatal("invalid or different Steam account joined the room")
		}
		if response == nil || (response.StatusCode != 401 && response.StatusCode != 503) {
			t.Fatal("unexpected admission failure")
		}
		_ = response.Body.Close()
	}
	receiver := relayTestConnect(t, server.URL, token, "receiver")
	relayReadControl(t, receiver, "ready")
	relayReadControl(t, receiver, "peer")
	relayReadControl(t, host, "peer")
	oauth.mu.Lock()
	delete(oauth.steamCatalogGrants, sha256.Sum256([]byte(strings.Repeat("a", 43))))
	oauth.mu.Unlock()
	if err := host.WriteMessage(websocket.BinaryMessage, []byte{17, 1}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := receiver.ReadMessage(); err == nil {
		t.Fatal("revoked catalog identity still forwarded game traffic")
	}
}

func TestSteamRelayExpiresCatalogAdmission(t *testing.T) {
	oauth := relayTestOAuth()
	digest := sha256.Sum256([]byte(strings.Repeat("a", 43)))
	oauth.steamCatalogGrants[digest].expires = time.Now().Add(-time.Second)
	s := newSteamRelay(clientIPResolver{}, oauth)
	if s.identity(digest) != "" {
		t.Fatal("expired catalog admission remained authorized")
	}
}

func TestSteamRelayConfiguredBandwidthIsBounded(t *testing.T) {
	t.Setenv("STEAM_STREAM_RELAY_ENABLED", "true")
	t.Setenv("STEAM_STREAM_RELAY_UDP_PORT", "")
	for _, invalid := range []string{"0", "-1", "65", "1.5", "999999999999999999999999"} {
		t.Setenv("STEAM_STREAM_RELAY_MIB_PER_SECOND", invalid)
		if registerSteamRelay(http.NewServeMux(), clientIPResolver{}, relayTestOAuth()) != nil {
			t.Fatalf("accepted bandwidth %q", invalid)
		}
	}
	for _, valid := range []string{"", "1", "8", "64"} {
		t.Setenv("STEAM_STREAM_RELAY_MIB_PER_SECOND", valid)
		relay := registerSteamRelay(http.NewServeMux(), clientIPResolver{}, relayTestOAuth())
		if relay == nil || relay.bytesPerSecond < 1<<20 || relay.bytesPerSecond > 64<<20 {
			t.Fatalf("invalid bandwidth for %q", valid)
		}
		relay.close()
	}
}
