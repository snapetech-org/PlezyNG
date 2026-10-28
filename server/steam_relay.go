package main

// A bounded, optional two-party byte relay. It never sees Steam credentials or
// plaintext game packets: paired apps authenticate and encrypt end to end.
import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const steamRelayMaxFrame = 65536
const steamRelayMaxRooms = 8

type steamRelayFrame struct {
	kind int
	data []byte
}
type steamRelayPeer struct {
	admission  [32]byte
	steamID    string
	conn       *websocket.Conn
	room       [32]byte
	cookie     [32]byte
	host       bool
	ip         string
	out        chan steamRelayFrame
	done       chan struct{}
	stopOnce   sync.Once
	observed   netip.AddrPort
	observedAt time.Time
}

func (p *steamRelayPeer) stop() {
	p.stopOnce.Do(func() {
		close(p.done)
		if p.conn != nil {
			_ = p.conn.Close()
		}
	})
}
func (p *steamRelayPeer) enqueue(f steamRelayFrame) bool {
	select {
	case <-p.done:
		return false
	default:
	}
	select {
	case p.out <- f:
		return true
	default:
		return false
	}
}
func relayControl(kind string, fields map[string]any) steamRelayFrame {
	if fields == nil {
		fields = map[string]any{}
	}
	fields["kind"] = kind
	data, _ := json.Marshal(fields)
	return steamRelayFrame{websocket.TextMessage, data}
}

type steamRelayRoom struct{ host, receiver *steamRelayPeer }
type steamRelay struct {
	oauth     *oauthProxy
	mu        sync.Mutex
	rooms     map[[32]byte]*steamRelayRoom
	cookies   map[[32]byte]*steamRelayPeer
	ips       map[string]int
	clientIPs clientIPResolver
	udp       *net.UDPConn
	udpPort   int
	closed    bool
}

func newSteamRelay(resolver clientIPResolver, oauth *oauthProxy) *steamRelay {
	return &steamRelay{oauth: oauth, rooms: map[[32]byte]*steamRelayRoom{}, cookies: map[[32]byte]*steamRelayPeer{}, ips: map[string]int{}, clientIPs: resolver}
}
func registerSteamRelay(mux *http.ServeMux, resolver clientIPResolver, oauth *oauthProxy) *steamRelay {
	if os.Getenv("STEAM_STREAM_RELAY_ENABLED") != "true" || oauth == nil {
		return nil
	}
	base, err := url.Parse(oauth.baseURL)
	if err != nil || base.Scheme != "https" || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" {
		return nil
	}
	s := newSteamRelay(resolver, oauth)
	if raw := os.Getenv("STEAM_STREAM_RELAY_UDP_PORT"); raw != "" {
		port, err := strconv.Atoi(raw)
		if err != nil || port < 1024 || port > 65535 {
			return nil
		}
		s.udp, err = net.ListenUDP("udp4", &net.UDPAddr{Port: port})
		if err != nil {
			return nil
		}
		s.udpPort = port
		go s.observeUDP()
	}
	mux.HandleFunc("/games/steam/relay", s.handle)
	return s
}
func (s *steamRelay) close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.udp != nil {
		_ = s.udp.Close()
	}
	for _, r := range s.rooms {
		r.host.stop()
		if r.receiver != nil {
			r.receiver.stop()
		}
	}
}
func (s *steamRelay) remove(p *steamRelayPeer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	room := s.rooms[p.room]
	if room == nil || (room.host != p && room.receiver != p) {
		p.stop()
		return
	}
	// A fresh receiver always requires a new pair of random handshake nonces.
	delete(s.rooms, p.room)
	for _, peer := range []*steamRelayPeer{room.host, room.receiver} {
		if peer == nil {
			continue
		}
		delete(s.cookies, peer.cookie)
		s.ips[peer.ip]--
		if s.ips[peer.ip] == 0 {
			delete(s.ips, peer.ip)
		}
		peer.stop()
	}
}
func (s *steamRelay) identity(digest [32]byte) string {
	if s.oauth == nil {
		return ""
	}
	s.oauth.mu.Lock()
	defer s.oauth.mu.Unlock()
	grant := s.oauth.steamCatalogGrants[digest]
	if grant == nil || !time.Now().Before(grant.expires) {
		return ""
	}
	return grant.steamID
}
func (s *steamRelay) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	// Browser origins and URL credentials are deliberately unsupported. Only
	// native paired clients use this capability in an Authorization header.
	raw := r.Header.Get("Authorization")
	secret, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(raw, "Bearer "))
	role := r.Header.Get("X-Steam-Relay-Role")
	if r.Method != "GET" || r.URL.RawQuery != "" || r.Header.Get("Origin") != "" || len(r.Header.Values("Authorization")) != 1 || !strings.HasPrefix(raw, "Bearer ") || err != nil || len(secret) != 32 || len(raw) != 50 || (role != "host" && role != "receiver") || r.Header.Get("X-Steam-Relay-Version") != "1" {
		http.Error(w, "Invalid relay request", 400)
		return
	}
	admission := r.Header.Get("X-Steam-Relay-Admission")
	if len(admission) != 43 || len(r.Header.Values("X-Steam-Relay-Admission")) != 1 {
		http.Error(w, "Link Steam", 401)
		return
	}
	digest := sha256.Sum256([]byte(admission))
	steamID := s.identity(digest)
	if steamID == "" {
		http.Error(w, "Link Steam", 401)
		return
	}
	ip, err := s.clientIPs.resolve(r)
	if err != nil {
		http.Error(w, "Invalid client", 400)
		return
	}
	p := &steamRelayPeer{admission: digest, steamID: steamID, room: sha256.Sum256(secret), host: role == "host", ip: ip, out: make(chan steamRelayFrame, 16), done: make(chan struct{})}
	if _, err = rand.Read(p.cookie[:]); err != nil {
		http.Error(w, "Unavailable", 503)
		return
	}
	s.mu.Lock()
	accountRooms := 0
	for _, room := range s.rooms {
		if room.host.steamID == steamID {
			accountRooms++
		}
	}
	room := s.rooms[p.room]
	if s.closed || s.ips[ip] >= 8 || (p.host && (room != nil || len(s.rooms) >= steamRelayMaxRooms || accountRooms >= 4)) || (!p.host && (room == nil || room.host.conn == nil || room.receiver != nil || room.host.steamID != steamID)) {
		s.mu.Unlock()
		http.Error(w, "Unavailable", 503)
		return
	}
	if p.host {
		room = &steamRelayRoom{host: p}
		s.rooms[p.room] = room
	} else {
		room.receiver = p
	}
	s.ips[ip]++
	s.mu.Unlock()
	defer s.remove(p)
	upgrader := websocket.Upgrader{HandshakeTimeout: 5 * time.Second, ReadBufferSize: 4096, WriteBufferSize: 4096, EnableCompression: false, CheckOrigin: func(*http.Request) bool { return true }}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	s.mu.Lock()
	if s.closed || s.rooms[p.room] != room {
		s.mu.Unlock()
		_ = conn.Close()
		return
	}
	p.conn = conn
	s.cookies[p.cookie] = p
	p.enqueue(relayControl("ready", map[string]any{"udpCookie": base64.RawURLEncoding.EncodeToString(p.cookie[:]), "udpPort": s.udpPort}))
	if room.host.conn != nil && room.receiver != nil && room.receiver.conn != nil {
		room.host.enqueue(relayControl("peer", nil))
		room.receiver.enqueue(relayControl("peer", nil))
	}
	s.mu.Unlock()
	conn.SetReadLimit(steamRelayMaxFrame)
	_ = conn.SetReadDeadline(time.Now().Add(45 * time.Second))
	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	go s.write(p)
	started, window := time.Now(), time.Now()
	var total, windowBytes int64
	for {
		kind, data, e := conn.ReadMessage()
		if e != nil {
			return
		}
		now := time.Now()
		if s.identity(p.admission) != p.steamID || kind != websocket.BinaryMessage || len(data) < 1 || now.Sub(started) > 2*time.Hour {
			return
		}
		if now.Sub(window) >= time.Second {
			window = now
			windowBytes = 0
		}
		total += int64(len(data))
		windowBytes += int64(len(data))
		if total > 32<<30 || windowBytes > 8<<20 {
			return
		}
		s.mu.Lock()
		current := s.rooms[p.room]
		var peer *steamRelayPeer
		if current == room {
			if p.host {
				peer = room.receiver
			} else {
				peer = room.host
			}
		}
		accepted := peer != nil && peer.conn != nil && peer.enqueue(steamRelayFrame{kind, data})
		s.mu.Unlock()
		if !accepted {
			return
		}
	}
}
func (s *steamRelay) write(p *steamRelayPeer) {
	defer s.remove(p)
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	lifetime := time.NewTimer(2 * time.Hour)
	defer lifetime.Stop()
	for {
		select {
		case <-p.done:
			return
		case <-lifetime.C:
			return
		case <-ticker.C:
			if s.identity(p.admission) != p.steamID {
				return
			}
			if p.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) != nil {
				return
			}
		case f := <-p.out:
			_ = p.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if p.conn.WriteMessage(f.kind, f.data) != nil {
				return
			}
		}
	}
}
func (s *steamRelay) observeUDP() {
	// No UDP response/amplification: report the observed source only over that
	// cookie's existing TLS channel. Cookies expire with their socket.
	buffer := make([]byte, 37)
	for {
		n, source, err := s.udp.ReadFromUDPAddrPort(buffer)
		if err != nil {
			return
		}
		if n != 36 || string(buffer[:4]) != "PSU1" || !source.Addr().Is4() || !steamCloudPublicIP(source.Addr()) {
			continue
		}
		var cookie [32]byte
		copy(cookie[:], buffer[4:36])
		s.observe(cookie, source)
	}
}
func (s *steamRelay) observe(cookie [32]byte, source netip.AddrPort) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.cookies[cookie]
	if p == nil || time.Since(p.observedAt) < 5*time.Second {
		return
	}
	p.observedAt = time.Now()
	if p.observed == source {
		return
	}
	p.observed = source
	p.enqueue(relayControl("observed", map[string]any{"ip": source.Addr().String(), "port": source.Port()}))
}
