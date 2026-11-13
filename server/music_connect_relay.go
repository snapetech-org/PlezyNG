package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

const (
	musicRelayMaxMessage     = 64 << 10
	musicRelayQueueBudget    = 16 << 20
	musicRelayMaxPeers       = 256
	musicRelayMaxRooms       = 128
	musicRelayMaxPeersPerIP  = 16
	musicRelayMaxControllers = 8
)

type musicRelayMessage struct {
	Event string          `json:"event,omitempty"`
	Peer  string          `json:"peer,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
}

type musicRelayPeer struct {
	mu           sync.Mutex
	id, ip, room string
	host         bool
	conn         *websocket.Conn
	out          chan []byte
	done         chan struct{}
	once         sync.Once
	removed      bool
}

func (p *musicRelayPeer) stop() {
	p.once.Do(func() {
		p.mu.Lock()
		close(p.done)
		conn := p.conn
		p.mu.Unlock()
		if conn != nil {
			_ = conn.Close()
		}
	})
}

func (p *musicRelayPeer) attach(conn *websocket.Conn) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	select {
	case <-p.done:
		_ = conn.Close()
		return false
	default:
		p.conn = conn
		return true
	}
}

type musicRelayRoom struct {
	host    *musicRelayPeer
	control [32]byte
	peers   map[string]*musicRelayPeer
}

type musicConnectRelay struct {
	mu        sync.Mutex
	wg        sync.WaitGroup
	rooms     map[string]*musicRelayRoom
	ips       map[string]int
	total     int
	queued    atomic.Int64
	clientIPs clientIPResolver
	abuse     *abuseGuard
	closed    bool
}

func newMusicConnectRelay(resolver clientIPResolver, guards ...*abuseGuard) *musicConnectRelay {
	return &musicConnectRelay{rooms: map[string]*musicRelayRoom{}, ips: map[string]int{}, clientIPs: resolver, abuse: optionalAbuseGuard(guards)}
}

func registerMusicConnectRelay(mux *http.ServeMux, resolver clientIPResolver, guards ...*abuseGuard) *musicConnectRelay {
	if os.Getenv("MUSIC_CONNECT_RELAY_ENABLED") != "true" {
		return nil
	}
	service := newMusicConnectRelay(resolver, guards...)
	mux.HandleFunc("/music/connect/relay", service.handle)
	return service
}

func musicRelayToken(value string) bool {
	if len(value) != 64 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && value == strings.ToLower(value)
}

func (s *musicConnectRelay) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet || r.URL.RawQuery != "" || len(r.Header.Values("Origin")) != 0 {
		http.Error(w, "Unsupported music relay request", http.StatusBadRequest)
		return
	}
	auth := r.Header.Get("Authorization")
	if len(r.Header.Values("Authorization")) != 1 || !strings.HasPrefix(auth, "Bearer ") ||
		!musicRelayToken(strings.TrimPrefix(auth, "Bearer ")) {
		markAbuseStatus(w, "Music relay authentication required", http.StatusUnauthorized)
		return
	}
	token := strings.TrimPrefix(auth, "Bearer ")
	role := r.Header.Get("X-Pleazyng-Music-Role")
	roomID := r.Header.Get("X-Pleazyng-Music-Room")
	if len(r.Header.Values("X-Pleazyng-Music-Role")) != 1 ||
		len(r.Header.Values("X-Pleazyng-Music-Room")) != 1 ||
		!musicRelayToken(roomID) || (role != "host" && role != "controller") {
		http.Error(w, "Invalid music relay registration", http.StatusBadRequest)
		return
	}
	control := r.Header.Get("X-Pleazyng-Music-Control")
	if role == "host" {
		digest := sha256.Sum256([]byte(token))
		expected := hex.EncodeToString(digest[:])
		if len(r.Header.Values("X-Pleazyng-Music-Control")) != 1 ||
			!musicRelayToken(control) || subtle.ConstantTimeCompare([]byte(expected), []byte(roomID)) != 1 {
			markAbuseStatus(w, "Invalid music relay registration", http.StatusUnauthorized)
			return
		}
	}
	peerID := make([]byte, 16)
	if _, err := rand.Read(peerID); err != nil {
		http.Error(w, "Music relay unavailable", http.StatusServiceUnavailable)
		return
	}
	ip, err := s.clientIPs.resolve(r)
	if err != nil {
		http.Error(w, "Invalid client address", http.StatusBadRequest)
		return
	}
	if s.abuse != nil && !s.abuse.allowHandshake(ip, time.Now()) {
		markRateLimit(w, "Too many music relay connections", time.Second)
		return
	}
	p := &musicRelayPeer{
		id: hex.EncodeToString(peerID), ip: ip, room: roomID, host: role == "host",
		out: make(chan []byte, 32), done: make(chan struct{}),
	}
	s.mu.Lock()
	room := s.rooms[roomID]
	status := 0
	sourceRateLimited := false
	switch {
	case s.closed || s.total >= musicRelayMaxPeers:
		status = http.StatusTooManyRequests
	case s.ips[p.ip] >= musicRelayMaxPeersPerIP:
		status = http.StatusTooManyRequests
		sourceRateLimited = true
	case p.host && room != nil:
		status = http.StatusConflict
	case p.host && len(s.rooms) >= musicRelayMaxRooms:
		status = http.StatusTooManyRequests
	case !p.host && room == nil:
		status = http.StatusServiceUnavailable
	case !p.host && room != nil:
		given := sha256.Sum256([]byte(token))
		if subtle.ConstantTimeCompare(given[:], room.control[:]) != 1 {
			status = http.StatusUnauthorized
		} else if len(room.peers) >= musicRelayMaxControllers {
			status = http.StatusTooManyRequests
		}
	}
	if status != 0 {
		s.mu.Unlock()
		if sourceRateLimited {
			markRateLimit(w, "Music device unavailable", time.Second)
		} else {
			http.Error(w, "Music device unavailable", status)
		}
		return
	}
	if p.host {
		room = &musicRelayRoom{host: p, control: sha256.Sum256([]byte(control)), peers: map[string]*musicRelayPeer{}}
		s.rooms[roomID] = room
	} else {
		room.peers[p.id] = p
	}
	s.total++
	s.ips[p.ip]++
	s.wg.Add(1)
	s.mu.Unlock()
	defer s.wg.Done()

	upgrader := websocket.Upgrader{
		HandshakeTimeout: 5 * time.Second, ReadBufferSize: 4096, WriteBufferSize: 4096,
		CheckOrigin: func(r *http.Request) bool { return len(r.Header.Values("Origin")) == 0 },
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		s.remove(p)
		return
	}
	if !p.attach(conn) {
		s.remove(p)
		return
	}
	defer s.remove(p)
	conn.SetReadLimit(musicRelayMaxMessage)
	_ = conn.SetReadDeadline(time.Now().Add(75 * time.Second))
	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(75 * time.Second)) })
	go s.write(p)
	if !p.host {
		joined, _ := json.Marshal(musicRelayMessage{Event: "joined", Peer: p.id})
		if !s.enqueue(p, joined) || !s.enqueue(room.host, joined) {
			return
		}
	}
	remaining := int64(8 << 20)
	last := time.Now()
	for {
		kind, data, err := conn.ReadMessage()
		if err != nil || kind != websocket.TextMessage {
			return
		}
		now := time.Now()
		if s.abuse != nil {
			if until := s.abuse.bannedUntil(p.ip, now); !until.IsZero() {
				_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "temporarily blocked after repeated rate-limit violations"), time.Now().Add(5*time.Second))
				return
			}
			if !s.abuse.allowRelayMessage(p.ip, now) {
				s.abuse.recordViolation(p.ip, now)
				_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "relay message rate exceeded"), time.Now().Add(5*time.Second))
				return
			}
		}
		remaining += int64(now.Sub(last).Seconds() * float64(1<<20))
		if remaining > 8<<20 {
			remaining = 8 << 20
		}
		last = now
		remaining -= int64(len(data))
		if remaining < 0 {
			if s.abuse != nil {
				s.abuse.recordViolation(p.ip, now)
			}
			return
		}
		var message musicRelayMessage
		if json.Unmarshal(data, &message) != nil {
			return
		}
		if p.host && message.Event == "close" {
			s.mu.Lock()
			room := s.rooms[p.room]
			var controller *musicRelayPeer
			if room != nil && room.host == p {
				controller = room.peers[message.Peer]
			}
			s.mu.Unlock()
			if controller != nil {
				controller.stop()
			}
			continue
		}
		if message.Event != "" || len(message.Data) == 0 || string(message.Data) == "null" {
			return
		}
		s.mu.Lock()
		current := s.rooms[p.room]
		var target *musicRelayPeer
		if current != nil {
			if p.host && current.host == p {
				target = current.peers[message.Peer]
			} else if !p.host && current.peers[p.id] == p {
				target = current.host
				message.Peer = p.id
			}
		}
		s.mu.Unlock()
		if target == nil {
			continue
		}
		forward, err := json.Marshal(message)
		if err != nil || !s.enqueue(target, forward) {
			return
		}
	}
}

func (s *musicConnectRelay) enqueue(p *musicRelayPeer, message []byte) bool {
	p.mu.Lock()
	select {
	case <-p.done:
		p.mu.Unlock()
		return false
	default:
	}
	if s.queued.Add(int64(len(message))) > musicRelayQueueBudget {
		s.queued.Add(-int64(len(message)))
		p.mu.Unlock()
		return false
	}
	select {
	case p.out <- message:
		p.mu.Unlock()
		return true
	default:
		s.queued.Add(-int64(len(message)))
		p.mu.Unlock()
		p.stop()
		return false
	}
}

func (s *musicConnectRelay) drain(p *musicRelayPeer) {
	for {
		select {
		case message := <-p.out:
			s.queued.Add(-int64(len(message)))
		default:
			return
		}
	}
}

func (s *musicConnectRelay) write(p *musicRelayPeer) {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	defer func() { p.stop(); s.drain(p) }()
	for {
		select {
		case <-p.done:
			return
		case message := <-p.out:
			_ = p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			err := p.conn.WriteMessage(websocket.TextMessage, message)
			s.queued.Add(-int64(len(message)))
			if err != nil {
				return
			}
		case <-ticker.C:
			if err := p.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second)); err != nil {
				return
			}
		}
	}
}

func (s *musicConnectRelay) remove(p *musicRelayPeer) {
	s.mu.Lock()
	if p.removed {
		s.mu.Unlock()
		return
	}
	p.removed = true
	s.total--
	s.ips[p.ip]--
	if s.ips[p.ip] == 0 {
		delete(s.ips, p.ip)
	}
	var retire []*musicRelayPeer
	room := s.rooms[p.room]
	if room != nil && p.host && room.host == p {
		delete(s.rooms, p.room)
		for _, controller := range room.peers {
			retire = append(retire, controller)
		}
	} else if room != nil && room.peers[p.id] == p {
		delete(room.peers, p.id)
		left, _ := json.Marshal(musicRelayMessage{Event: "left", Peer: p.id})
		if !s.enqueue(room.host, left) {
			retire = append(retire, room.host)
		}
	}
	s.mu.Unlock()
	p.stop()
	s.drain(p)
	for _, peer := range retire {
		peer.stop()
	}
}

func (s *musicConnectRelay) close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.closed = true
	var peers []*musicRelayPeer
	for _, room := range s.rooms {
		peers = append(peers, room.host)
		for _, peer := range room.peers {
			peers = append(peers, peer)
		}
	}
	s.mu.Unlock()
	for _, peer := range peers {
		peer.stop()
	}
	s.wg.Wait()
}
