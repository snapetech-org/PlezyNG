package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/url"
	"os"
	"time"
)

const familySessionTTL = 10 * time.Minute

type familyReview struct {
	ID      string
	Digest  [32]byte
	Plan    familyPlan
	Expires time.Time
}
type familySession struct {
	Binding                               steamCloudBinding
	Expires, PollAfter                    time.Time
	ClientID                              familyID
	RequestID, Challenge, Access, Refresh string
	Busy                                  bool
	Review                                *familyReview
	Context                               context.Context
	Cancel                                context.CancelFunc
}
type steamFamiliesState struct {
	API      *steamFamilyAPI
	Sessions map[[32]byte]*familySession // oauthProxy.mu guards all fields.
	Closed   bool
}

func validSteamID(s string) bool { return steamIDPattern.MatchString(s) && familyIDValid(s) }
func (p *oauthProxy) configureSteamFamilies() {
	if os.Getenv("STEAM_FAMILIES_ENABLED") != "true" {
		return
	}
	u, err := url.Parse(p.baseURL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return
	}
	p.steamFamilies = &steamFamiliesState{API: &steamFamilyAPI{client: p.steamClient}, Sessions: map[[32]byte]*familySession{}}
}
func (f *steamFamiliesState) revoke(token string) <-chan struct{} {
	done := make(chan struct{})
	if token == "" {
		close(done)
		return done
	}
	// Best effort, bounded, with no token/URL/error logging. Local authorization
	// is already removed regardless of Valve's revocation availability.
	go func() {
		defer close(done)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = f.API.call(ctx, "", "Authentication", "RevokeToken", map[string]any{"token": token, "revoke_action": 1}, false, nil)
	}()
	return done
}
func (p *oauthProxy) dropFamilyLocked(key [32]byte, s *familySession) <-chan struct{} {
	delete(p.steamFamilies.Sessions, key)
	s.Cancel()
	done := p.steamFamilies.revoke(s.Refresh)
	s.Refresh = ""
	s.Access = ""
	s.RequestID = ""
	s.Review = nil
	return done
}
func (p *oauthProxy) closeSteamFamilies(ctx context.Context) {
	if p == nil || p.steamFamilies == nil {
		return
	}
	p.mu.Lock()
	f := p.steamFamilies
	f.Closed = true
	done := make([]<-chan struct{}, 0, len(f.Sessions))
	for key, s := range f.Sessions {
		done = append(done, p.dropFamilyLocked(key, s))
	}
	p.mu.Unlock()
	for _, wait := range done {
		select {
		case <-wait:
		case <-ctx.Done():
			return
		}
	}
}
func (p *oauthProxy) cleanupSteamFamiliesLocked(now time.Time) {
	f := p.steamFamilies
	if f == nil {
		return
	}
	for key, s := range f.Sessions {
		catalog := p.steamCatalogGrants[s.Binding.Catalog]
		if !now.Before(s.Expires) || catalog == nil || !now.Before(catalog.expires) || catalog.steamID != s.Binding.SteamID {
			p.dropFamilyLocked(key, s)
		}
	}
}
func (p *oauthProxy) familyLiveLocked(key [32]byte, s *familySession) bool {
	c := p.steamCatalogGrants[s.Binding.Catalog]
	return !p.steamFamilies.Closed && p.steamFamilies.Sessions[key] == s && time.Now().Before(s.Expires) && c != nil && time.Now().Before(c.expires) && c.steamID == s.Binding.SteamID
}

type familyRequest struct {
	Operation string        `json:"operation"`
	Session   string        `json:"session,omitempty"`
	Consent   bool          `json:"consent,omitempty"`
	Change    *familyChange `json:"change,omitempty"`
	Review    string        `json:"review,omitempty"`
}

func (p *oauthProxy) handleSteamFamilies(w http.ResponseWriter, r *http.Request) {
	cloudHeaders(w)
	if r.Method != http.MethodPost || r.URL.RawQuery != "" {
		http.Error(w, "Invalid request", 400)
		return
	}
	if !p.cloudRate(w, r) {
		return
	}
	binding, ok := p.cloudCatalog(r)
	if !ok {
		http.Error(w, "Relink Steam", 401)
		return
	}
	var in familyRequest
	if !cloudJSON(w, r, 4096, &in) {
		http.Error(w, "Invalid request", 400)
		return
	}
	f := p.steamFamilies
	if in.Operation == "capabilities" {
		writeJSON(w, 200, map[string]any{"available": f != nil, "sessionSeconds": 600})
		return
	}
	if f == nil {
		http.Error(w, "Steam Families is not enabled", 503)
		return
	}
	if in.Operation == "start" {
		if !in.Consent || in.Session != "" || in.Change != nil || in.Review != "" {
			http.Error(w, "Explicit authorization required", 400)
			return
		}
		p.startSteamFamily(w, r, binding)
		return
	}
	bytes, err := base64.RawURLEncoding.DecodeString(in.Session)
	if len(in.Session) != 43 || err != nil || len(bytes) != 32 || in.Consent {
		http.Error(w, "Invalid session", 400)
		return
	}
	key := sha256.Sum256([]byte(in.Session))
	p.mu.Lock()
	p.cleanupSteamFamiliesLocked(time.Now())
	s := f.Sessions[key]
	if s == nil || s.Binding != binding {
		p.mu.Unlock()
		http.Error(w, "Authorization expired", 401)
		return
	}
	if in.Operation == "close" {
		p.dropFamilyLocked(key, s)
		p.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if s.Busy {
		p.mu.Unlock()
		http.Error(w, "Operation in progress", 409)
		return
	}
	active := 0
	for _, candidate := range f.Sessions {
		if candidate.Busy {
			active++
		}
	}
	if active >= 8 {
		p.mu.Unlock()
		http.Error(w, "Try later", 429)
		return
	}
	s.Busy = true
	access, client, requestID := s.Access, s.ClientID, s.RequestID
	pollAfter := s.PollAfter
	p.mu.Unlock()
	defer func() { p.mu.Lock(); s.Busy = false; p.mu.Unlock() }()
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	stop := context.AfterFunc(s.Context, cancel)
	defer stop()
	if in.Operation == "poll" {
		if in.Change != nil || in.Review != "" || access != "" || time.Now().Before(pollAfter) {
			http.Error(w, "Refresh authorization", 409)
			return
		}
		p.mu.Lock()
		s.PollAfter = time.Now().Add(5 * time.Second)
		p.mu.Unlock()
		var result struct {
			Client    familyID `json:"new_client_id"`
			Challenge string   `json:"new_challenge_url"`
			Access    string   `json:"access_token"`
			Refresh   string   `json:"refresh_token"`
		}
		err = f.API.call(ctx, "", "Authentication", "PollAuthSessionStatus", map[string]any{"client_id": string(client), "request_id": requestID}, false, &result)
		if err != nil {
			http.Error(w, "Steam authorization unavailable", 502)
			return
		}
		if result.Access != "" {
			id, valid := familyTokenSubject(result.Access, time.Now())
			if !valid || id != binding.SteamID || result.Refresh == "" || len(result.Refresh) > 16384 {
				f.revoke(result.Refresh)
				p.mu.Lock()
				if p.familyLiveLocked(key, s) {
					p.dropFamilyLocked(key, s)
				}
				p.mu.Unlock()
				http.Error(w, "Steam account does not match the linked account", 403)
				return
			}
			if _, err = f.API.snapshot(ctx, result.Access, binding.SteamID); err != nil {
				f.revoke(result.Refresh)
				http.Error(w, "Steam Families unavailable", 502)
				return
			}
		}
		p.mu.Lock()
		if !p.familyLiveLocked(key, s) {
			p.mu.Unlock()
			f.revoke(result.Refresh)
			http.Error(w, "Authorization retired", 401)
			return
		}
		if result.Access != "" {
			s.Access = result.Access
			s.Refresh = result.Refresh
			s.RequestID = ""
			s.Challenge = ""
			s.Expires = time.Now().Add(familySessionTTL)
		} else {
			if result.Client != "" && result.Client != "0" {
				s.ClientID = result.Client
			}
			if result.Challenge != "" {
				if !familyChallenge(result.Challenge) {
					p.mu.Unlock()
					http.Error(w, "Invalid Steam challenge", 502)
					return
				}
				s.Challenge = result.Challenge
			}
		}
		ready, challenge, expires := s.Access != "", s.Challenge, s.Expires.Unix()
		p.mu.Unlock()
		writeJSON(w, 200, map[string]any{"authorized": ready, "challenge": challenge, "expires": expires, "pollSeconds": 5, "steamId": binding.SteamID})
		return
	}
	if access == "" {
		http.Error(w, "Steam authorization required", 403)
		return
	}
	if in.Operation != "state" && in.Operation != "review" && in.Operation != "commit" {
		http.Error(w, "Invalid operation", 400)
		return
	}
	if (in.Operation == "review") != (in.Change != nil) || (in.Operation == "commit") != (in.Review != "") {
		http.Error(w, "Invalid operation", 400)
		return
	}
	var review *familyReview
	if in.Operation == "commit" {
		p.mu.Lock()
		review = s.Review
		s.Review = nil
		p.mu.Unlock()
		// Consume before any network I/O: even an ambiguous timeout cannot be
		// replayed by a double tap, transport retry or a retained dialog.
		if review == nil || in.Review != review.ID || !time.Now().Before(review.Expires) {
			http.Error(w, "Review expired; refresh", 409)
			return
		}
	}
	snapshot, err := f.API.snapshot(ctx, access, binding.SteamID)
	if err != nil {
		http.Error(w, "Steam Families unavailable; refresh before retrying", 409)
		return
	}
	p.mu.Lock()
	live := p.familyLiveLocked(key, s)
	p.mu.Unlock()
	if !live {
		http.Error(w, "Authorization retired", 401)
		return
	}
	if in.Operation == "state" {
		writeJSON(w, 200, map[string]any{"steamId": binding.SteamID, "state": snapshot})
		return
	}
	if in.Operation == "review" {
		plan, err := planFamilyChange(snapshot, binding.SteamID, *in.Change)
		if err != nil {
			http.Error(w, "Change not allowed; refresh", 409)
			return
		}
		review = &familyReview{ID: randToken(32), Digest: snapshot.digest(), Plan: plan, Expires: time.Now().Add(60 * time.Second)}
		p.mu.Lock()
		live = p.familyLiveLocked(key, s)
		if live {
			s.Review = review
		}
		p.mu.Unlock()
		if !live {
			http.Error(w, "Authorization retired", 401)
			return
		}
		writeJSON(w, 200, map[string]any{"review": review.ID, "change": plan.Change, "state": snapshot, "expires": review.Expires.Unix()})
		return
	}
	plan, err := planFamilyChange(snapshot, binding.SteamID, review.Plan.Change)
	if err != nil || snapshot.digest() != review.Digest {
		http.Error(w, "Family changed; refresh and review again", 409)
		return
	}
	var result struct {
		TwoFactor int `json:"two_factor_method"`
	}
	if err = f.API.call(ctx, access, "FamilyGroups", plan.Method, plan.Parameters, false, &result); err != nil {
		writeJSON(w, 409, map[string]any{"error": "outcome_unknown_refresh_required"})
		return
	}
	p.mu.Lock()
	live = p.familyLiveLocked(key, s)
	p.mu.Unlock()
	if !live {
		http.Error(w, "Authorization retired", 401)
		return
	}
	writeJSON(w, 200, map[string]any{"submitted": true, "steamConfirmationRequired": result.TwoFactor != 0})
}
func (p *oauthProxy) startSteamFamily(w http.ResponseWriter, r *http.Request, binding steamCloudBinding) {
	f := p.steamFamilies
	p.mu.Lock()
	p.cleanupSteamFamiliesLocked(time.Now())
	if f.Closed || len(f.Sessions) >= 64 {
		p.mu.Unlock()
		http.Error(w, "Try later", 429)
		return
	}
	active := 0
	for _, s := range f.Sessions {
		if s.Binding.SteamID == binding.SteamID {
			p.mu.Unlock()
			http.Error(w, "Close the existing Families session first", 409)
			return
		}
		if s.Busy {
			active++
		}
	}
	if active >= 8 {
		p.mu.Unlock()
		http.Error(w, "Try later", 429)
		return
	}
	secret := randToken(32)
	key := sha256.Sum256([]byte(secret))
	sctx, scancel := context.WithCancel(context.Background())
	s := &familySession{Binding: binding, Expires: time.Now().Add(3 * time.Minute), Busy: true, Context: sctx, Cancel: scancel}
	f.Sessions[key] = s
	p.mu.Unlock()
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	stop := context.AfterFunc(sctx, cancel)
	defer stop()
	var result struct {
		Client    familyID `json:"client_id"`
		Request   string   `json:"request_id"`
		Challenge string   `json:"challenge_url"`
	}
	err := f.API.call(ctx, "", "Authentication", "BeginAuthSessionViaQR", map[string]any{
		"device_friendly_name": "PlezyNG Steam Families (temporary)", "platform_type": 2, "website_id": "Community",
		"device_details": map[string]any{"device_friendly_name": "PlezyNG Steam Families (temporary)", "platform_type": 2},
	}, false, &result)
	decoded, e := base64.StdEncoding.DecodeString(result.Request)
	p.mu.Lock()
	if err != nil || e != nil || len(decoded) == 0 || len(decoded) > 256 || !familyIDValid(string(result.Client)) || !familyChallenge(result.Challenge) || !p.familyLiveLocked(key, s) {
		if f.Sessions[key] == s {
			p.dropFamilyLocked(key, s)
		}
		p.mu.Unlock()
		http.Error(w, "Steam authorization unavailable", 502)
		return
	}
	s.ClientID = result.Client
	s.RequestID = result.Request
	s.Challenge = result.Challenge
	s.Busy = false
	s.PollAfter = time.Now().Add(5 * time.Second)
	expires := s.Expires.Unix()
	p.mu.Unlock()
	writeJSON(w, 200, map[string]any{"session": secret, "challenge": result.Challenge, "expires": expires, "pollSeconds": 5, "steamId": binding.SteamID})
}

// Keep unsupported administrator and support-only endpoints out of this file:
// no household checks, parental permissions, cooldowns or two-factor checks
// are disabled. Valve always remains the final policy authority.
