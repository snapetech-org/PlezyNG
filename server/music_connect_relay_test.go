package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func musicRelayTestHeaders(role, secret, control string) http.Header {
	digest := sha256.Sum256([]byte(secret))
	h := http.Header{
		"Authorization":         {"Bearer " + secret},
		"X-Pleazyng-Music-Role": {role},
		"X-Pleazyng-Music-Room": {hex.EncodeToString(digest[:])},
	}
	if role == "host" {
		h.Set("X-Pleazyng-Music-Control", control)
	}
	if role == "controller" {
		h.Set("Authorization", "Bearer "+control)
	}
	return h
}

func musicRelayTestServer(t *testing.T) (*musicConnectRelay, string) {
	t.Helper()
	service := newMusicConnectRelay(newClientIPResolver(nil))
	server := httptest.NewServer(http.HandlerFunc(service.handle))
	t.Cleanup(func() { service.close(); server.Close() })
	return service, "ws" + strings.TrimPrefix(server.URL, "http") + "/music/connect/relay"
}

func musicRelayDial(t *testing.T, url string, headers http.Header) *websocket.Conn {
	t.Helper()
	conn, response, err := websocket.DefaultDialer.Dial(url, headers)
	if err != nil {
		t.Fatalf("dial failed with status %v: %v", response, err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func musicRelayRead(t *testing.T, conn *websocket.Conn) musicRelayMessage {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	var value musicRelayMessage
	if err := conn.ReadJSON(&value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestMusicRelayForwardsToTheAuthenticatedControllerOnly(t *testing.T) {
	_, url := musicRelayTestServer(t)
	secret, control := strings.Repeat("1", 64), strings.Repeat("2", 64)
	host := musicRelayDial(t, url, musicRelayTestHeaders("host", secret, control))
	first := musicRelayDial(t, url, musicRelayTestHeaders("controller", secret, control))
	joined := musicRelayRead(t, host)
	if joined.Event != "joined" || len(joined.Peer) != 32 {
		t.Fatal("invalid controller identity")
	}
	if musicRelayRead(t, first).Peer != joined.Peer {
		t.Fatal("identity changed")
	}
	second := musicRelayDial(t, url, musicRelayTestHeaders("controller", secret, control))
	other := musicRelayRead(t, host)
	_ = musicRelayRead(t, second)
	if other.Peer == joined.Peer {
		t.Fatal("duplicate controller")
	}
	if err := first.WriteJSON(musicRelayMessage{Peer: other.Peer, Data: json.RawMessage(`{"cipher":"first"}`)}); err != nil {
		t.Fatal(err)
	}
	message := musicRelayRead(t, host)
	if message.Peer != joined.Peer {
		t.Fatal("controller spoofed another peer")
	}
	if err := host.WriteJSON(musicRelayMessage{Peer: joined.Peer, Data: message.Data}); err != nil {
		t.Fatal(err)
	}
	if string(musicRelayRead(t, first).Data) != string(message.Data) {
		t.Fatal("ciphertext changed")
	}
	if err := host.WriteJSON(musicRelayMessage{Event: "close", Peer: other.Peer}); err != nil {
		t.Fatal(err)
	}
	_ = second.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := second.ReadMessage(); err == nil {
		t.Fatal("rejected peer stayed connected")
	}
}

func TestMusicRelayRejectsWrongCapabilitiesAndBrowserOrigins(t *testing.T) {
	_, url := musicRelayTestServer(t)
	secret, control := strings.Repeat("a", 64), strings.Repeat("b", 64)
	_ = musicRelayDial(t, url, musicRelayTestHeaders("host", secret, control))
	cases := []struct {
		name    string
		headers http.Header
		status  int
	}{
		{"wrong controller", musicRelayTestHeaders("controller", secret, strings.Repeat("c", 64)), http.StatusUnauthorized},
		{"duplicate host", musicRelayTestHeaders("host", secret, control), http.StatusConflict},
		{"missing host", musicRelayTestHeaders("controller", strings.Repeat("d", 64), control), http.StatusServiceUnavailable},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			conn, response, err := websocket.DefaultDialer.Dial(url, test.headers)
			if conn != nil {
				_ = conn.Close()
			}
			if err == nil || response == nil || response.StatusCode != test.status {
				t.Fatalf("wanted %d, got %v %v", test.status, response, err)
			}
		})
	}
	headers := musicRelayTestHeaders("controller", secret, control)
	headers.Set("Origin", "https://evil.example")
	conn, response, err := websocket.DefaultDialer.Dial(url, headers)
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusBadRequest {
		t.Fatal("browser accepted")
	}
	duplicateOrigin := musicRelayTestHeaders("controller", secret, control)
	duplicateOrigin.Add("Origin", "")
	duplicateOrigin.Add("Origin", "https://evil.example")
	conn, response, err = websocket.DefaultDialer.Dial(url, duplicateOrigin)
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusBadRequest {
		t.Fatal("duplicate browser origin accepted")
	}
}

func TestMusicRelayHostDisconnectRetiresItsControllers(t *testing.T) {
	service, url := musicRelayTestServer(t)
	secret, control := strings.Repeat("3", 64), strings.Repeat("4", 64)
	host := musicRelayDial(t, url, musicRelayTestHeaders("host", secret, control))
	controller := musicRelayDial(t, url, musicRelayTestHeaders("controller", secret, control))
	_ = musicRelayRead(t, host)
	_ = musicRelayRead(t, controller)
	_ = host.Close()
	_ = controller.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := controller.ReadMessage(); err == nil {
		t.Fatal("controller survived host")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		service.mu.Lock()
		count, rooms := service.total, len(service.rooms)
		service.mu.Unlock()
		if count == 0 && rooms == 0 && service.queued.Load() == 0 {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("relay retained an admission or queued payload")
}

func TestMusicRelayQueueBudgetIsBoundedAndDrained(t *testing.T) {
	service := newMusicConnectRelay(newClientIPResolver(nil))
	peer := &musicRelayPeer{out: make(chan []byte, 2), done: make(chan struct{})}
	if !service.enqueue(peer, make([]byte, 1024)) || !service.enqueue(peer, make([]byte, 1024)) {
		t.Fatal("valid queue rejected")
	}
	if service.enqueue(peer, make([]byte, 1024)) {
		t.Fatal("unlimited queue")
	}
	service.drain(peer)
	if service.queued.Load() != 0 {
		t.Fatal("queue budget leaked")
	}
	if service.enqueue(peer, []byte("late")) {
		t.Fatal("retired peer accepted data")
	}
}
