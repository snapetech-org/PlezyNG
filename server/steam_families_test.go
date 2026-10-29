package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const familyOther = "76561198000000002"

func testFamily() familySnapshot {
	return familySnapshot{FamilyID: "123", Role: 1, Group: familyGroup{Name: "Living room", FreeSpots: 4,
		Members: []familyMember{{familyID(cloudTestID), 1}, {familyID(familyOther), 2}}}}
}
func TestFamilyMutationPolicy(t *testing.T) {
	s := testFamily()
	for _, c := range []familyChange{
		{Action: "rename", Name: "New name"}, {Action: "invite", SteamID: "76561198000000003", Role: 1},
		{Action: "invite", SteamID: "76561198000000003", Role: 2}, {Action: "remove", SteamID: familyOther},
		{Action: "leave"}, {Action: "preferredLender", SteamID: familyOther, AppID: 620},
	} {
		if _, err := planFamilyChange(s, cloudTestID, c); err != nil {
			t.Errorf("valid change %s refused", c.Action)
		}
	}
	for _, c := range []familyChange{
		{Action: "create", Name: "New"}, {Action: "delete"}, {Action: "remove", SteamID: cloudTestID},
		{Action: "remove", SteamID: "76561198000000003"}, {Action: "invite", SteamID: familyOther, Role: 2},
		{Action: "invite", SteamID: "76561198000000003", Role: 5}, {Action: "rename", Name: "New", SteamID: familyOther},
		{Action: "ForceAcceptInvite"}, {Action: "SetFamilyCooldownOverrides"}, {Action: "rename", Name: "x\ny"},
	} {
		if _, err := planFamilyChange(s, cloudTestID, c); err == nil {
			t.Errorf("unsafe change %s accepted", c.Action)
		}
	}
	s.Role = 2
	s.Group.Members[0].Role = 2
	for _, c := range []familyChange{{Action: "rename", Name: "New"}, {Action: "leave"}, {Action: "remove", SteamID: familyOther}, {Action: "invite", SteamID: "76561198000000003", Role: 1}} {
		if _, err := planFamilyChange(s, cloudTestID, c); err == nil {
			t.Errorf("child permission widened: %s", c.Action)
		}
	}
	s = familySnapshot{NotMember: true, CanUndelete: true, LastFamilyID: "123", Invites: []familyInvite{{FamilyID: "456", InviteID: "7", Role: 1, Inviter: familyID(familyOther)}}}
	for _, c := range []familyChange{{Action: "create", Name: "Family"}, {Action: "restore"}, {Action: "join", FamilyID: "456"}} {
		if _, err := planFamilyChange(s, cloudTestID, c); err != nil {
			t.Errorf("eligible %s refused", c.Action)
		}
	}
	s.Invites[0].Awaiting = true
	if _, err := planFamilyChange(s, cloudTestID, familyChange{Action: "join", FamilyID: "456"}); err == nil {
		t.Fatal("2FA bypass")
	}
	s.Cooldown = 60
	if _, err := planFamilyChange(s, cloudTestID, familyChange{Action: "create", Name: "Family"}); err == nil {
		t.Fatal("cooldown bypass")
	}
}
func familyTestProxy(t *testing.T) (*oauthProxy, string, string, *familySnapshot, *atomic.Int32) {
	t.Helper()
	p := newOAuthProxy("https://plezy.test", map[string]oauthServiceConfig{}, clientIPResolver{})
	catalog := p.issueSteamCatalogGrant(cloudTestID)
	secret := randToken(32)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	state := testFamily()
	changes := &atomic.Int32{}
	api := &steamFamilyAPI{client: &http.Client{Transport: cloudTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.steampowered.com" {
			t.Fatal("unapproved origin")
		}
		if strings.Contains(r.URL.Path, "GetFamilyGroupForUser") {
			if r.Method != "GET" || r.URL.Query().Get("access_token") != "private-access" {
				t.Error("read authorization")
			}
			b, _ := json.Marshal(map[string]any{"response": state})
			return cloudReply(string(b)), nil
		}
		if r.Method != "POST" || r.URL.RawQuery != "" {
			t.Error("mutation credentials leaked into URL")
		}
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if r.PostForm.Get("access_token") != "private-access" {
			t.Error("wrong mutation authority")
		}
		changes.Add(1)
		return cloudReply(`{"response":{}}`), nil
	})}}
	p.steamFamilies = &steamFamiliesState{API: api, Sessions: map[[32]byte]*familySession{
		sha256.Sum256([]byte(secret)): {Binding: steamCloudBinding{Catalog: sha256.Sum256([]byte(catalog)), SteamID: cloudTestID}, Expires: time.Now().Add(time.Minute), Access: "private-access", Context: ctx, Cancel: cancel},
	}}
	return p, catalog, secret, &state, changes
}
func familyRequestTest(p *oauthProxy, catalog string, value any) *httptest.ResponseRecorder {
	b, _ := json.Marshal(value)
	r := httptest.NewRequest("POST", "https://plezy.test/auth/steam/families", strings.NewReader(string(b)))
	r.Header.Set("Authorization", "Bearer "+catalog)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	p.handleSteamFamilies(w, r)
	return w
}
func familyReviewTest(t *testing.T, p *oauthProxy, catalog, session string) string {
	t.Helper()
	w := familyRequestTest(p, catalog, familyRequest{Operation: "review", Session: session, Change: &familyChange{Action: "rename", Name: "New"}})
	if w.Code != 200 {
		t.Fatalf("review: %d %s", w.Code, w.Body.String())
	}
	var result struct {
		Review string `json:"review"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &result)
	if result.Review == "" {
		t.Fatal("missing review")
	}
	return result.Review
}
func TestFamilyReviewRechecksAndConsumesExactlyOnce(t *testing.T) {
	for _, change := range []string{"success", "stale", "expired", "role", "revoked"} {
		t.Run(change, func(t *testing.T) {
			p, catalog, session, state, count := familyTestProxy(t)
			review := familyReviewTest(t, p, catalog, session)
			s := p.steamFamilies.Sessions[sha256.Sum256([]byte(session))]
			switch change {
			case "stale":
				state.Group.Name = "Changed elsewhere"
			case "expired":
				s.Review.Expires = time.Now().Add(-time.Second)
			case "role":
				state.Role = 2
				state.Group.Members[0].Role = 2
			case "revoked":
				delete(p.steamCatalogGrants, sha256.Sum256([]byte(catalog)))
				p.cleanupSteamFamiliesLocked(time.Now())
			}
			request := familyRequest{Operation: "commit", Session: session, Review: review}
			w := familyRequestTest(p, catalog, request)
			if (w.Code == 200) != (change == "success") {
				t.Fatalf("commit code %d", w.Code)
			}
			if again := familyRequestTest(p, catalog, request); again.Code == 200 {
				t.Fatal("review replay accepted")
			}
			want := int32(0)
			if change == "success" {
				want = 1
			}
			if count.Load() != want {
				t.Fatal("unexpected upstream mutations")
			}
		})
	}
}
func TestFamilyBindingSchemaAndDisabledCompatibility(t *testing.T) {
	p, catalog, session, _, count := familyTestProxy(t)
	other := p.issueSteamCatalogGrant(familyOther)
	if familyRequestTest(p, other, familyRequest{Operation: "state", Session: session}).Code != 401 {
		t.Fatal("cross-profile session")
	}
	if familyRequestTest(p, catalog, map[string]any{"operation": "review", "session": session, "change": map[string]any{"action": "rename", "name": "New", "nonce": "injected"}}).Code != 400 {
		t.Fatal("unknown mutation field")
	}
	if count.Load() != 0 {
		t.Fatal("invalid requests mutated Steam")
	}
	p.steamFamilies = nil
	w := familyRequestTest(p, catalog, familyRequest{Operation: "capabilities"})
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"available":false`) {
		t.Fatal("disabled service is not discoverable")
	}
	if familyRequestTest(p, catalog, familyRequest{Operation: "start", Consent: true}).Code != 503 {
		t.Fatal("disabled service authenticates")
	}
}
func TestFamilyNoCredentialRedirectOrFalseSuccess(t *testing.T) {
	var requests atomic.Int32
	api := &steamFamilyAPI{client: &http.Client{Transport: cloudTransport(func(r *http.Request) (*http.Response, error) {
		requests.Add(1)
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": {"https://evil.test/"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}}
	if api.call(context.Background(), "secret", "FamilyGroups", "DeleteFamilyGroup", map[string]any{}, false, nil) == nil || requests.Load() != 1 {
		t.Fatal("redirect followed or accepted")
	}
	api.client.Transport = cloudTransport(func(r *http.Request) (*http.Response, error) {
		reply := cloudReply(`{"response":{}}`)
		reply.Header.Set("x-eresult", "15")
		return reply, nil
	})
	if api.call(context.Background(), "secret", "FamilyGroups", "DeleteFamilyGroup", map[string]any{}, false, nil) == nil {
		t.Fatal("HTTP 200 bypassed Valve failure")
	}
}
func familyJWT(id string) string {
	b, _ := json.Marshal(map[string]any{"sub": id, "aud": []string{"web"}, "exp": time.Now().Add(time.Hour).Unix()})
	return "header." + base64.RawURLEncoding.EncodeToString(b) + ".signature"
}
func TestFamilyQRIdentityAndRetirement(t *testing.T) {
	for _, correct := range []bool{true, false} {
		t.Run(map[bool]string{true: "same-account", false: "wrong-account"}[correct], func(t *testing.T) {
			p, catalog, old, state, _ := familyTestProxy(t)
			familyRequestTest(p, catalog, familyRequest{Operation: "close", Session: old})
			revoked := make(chan struct{}, 1)
			id := cloudTestID
			if !correct {
				id = familyOther
			}
			p.steamFamilies.API.client.Transport = cloudTransport(func(r *http.Request) (*http.Response, error) {
				switch {
				case strings.Contains(r.URL.Path, "BeginAuthSessionViaQR"):
					return cloudReply(`{"response":{"client_id":"123456","request_id":"YWJj","challenge_url":"https://s.team/q/1/123456"}}`), nil
				case strings.Contains(r.URL.Path, "PollAuthSessionStatus"):
					b, _ := json.Marshal(map[string]any{"response": map[string]string{"access_token": familyJWT(id), "refresh_token": "private-refresh"}})
					return cloudReply(string(b)), nil
				case strings.Contains(r.URL.Path, "RevokeToken"):
					_ = r.ParseForm()
					if !strings.Contains(r.PostForm.Get("input_json"), "private-refresh") {
						t.Error("wrong revocation")
					}
					revoked <- struct{}{}
					return cloudReply(`{"response":{}}`), nil
				default:
					b, _ := json.Marshal(map[string]any{"response": state})
					return cloudReply(string(b)), nil
				}
			})
			if familyRequestTest(p, catalog, familyRequest{Operation: "start"}).Code != 400 {
				t.Fatal("missing QR consent accepted")
			}
			w := familyRequestTest(p, catalog, familyRequest{Operation: "start", Consent: true})
			var begin struct {
				Session string `json:"session"`
			}
			_ = json.Unmarshal(w.Body.Bytes(), &begin)
			if w.Code != 200 || begin.Session == "" {
				t.Fatalf("start %d", w.Code)
			}
			p.steamFamilies.Sessions[sha256.Sum256([]byte(begin.Session))].PollAfter = time.Now().Add(-time.Second)
			w = familyRequestTest(p, catalog, familyRequest{Operation: "poll", Session: begin.Session})
			if (w.Code == 200) != correct {
				t.Fatalf("poll %d", w.Code)
			}
			if strings.Contains(w.Body.String(), "private-refresh") || strings.Contains(w.Body.String(), "signature") {
				t.Fatal("upstream token disclosed")
			}
			if correct {
				familyRequestTest(p, catalog, familyRequest{Operation: "close", Session: begin.Session})
			}
			select {
			case <-revoked:
			case <-time.After(time.Second):
				t.Fatal("minted Steam session not revoked")
			}
		})
	}
}
func TestFamilyChallengeAndLargeIdentity(t *testing.T) {
	for _, raw := range []string{"https://evil.test/q/1/2", "https://s.team.evil/q/1/2", "http://s.team/q/1/2", "https://user@s.team/q/1/2", "https://s.team/q/1/2?token=leak", "https://s.team/q/1/2#fragment"} {
		if familyChallenge(raw) {
			t.Errorf("unsafe QR %s", raw)
		}
	}
	var id familyID
	if json.Unmarshal([]byte(`"18446744073709551615"`), &id) != nil || string(id) != "18446744073709551615" {
		t.Fatal("family id rounded")
	}
	if json.Unmarshal([]byte(`18446744073709551616`), &id) == nil {
		t.Fatal("overflow accepted")
	}
}

func TestFamilyShutdownCancelsAndRevokesBeforeReturn(t *testing.T) {
	p, catalog, session, _, _ := familyTestProxy(t)
	s := p.steamFamilies.Sessions[sha256.Sum256([]byte(session))]
	s.Refresh = "private-refresh"
	started := make(chan struct{})
	requestDone := make(chan int, 1)
	var revoked atomic.Int32
	p.steamFamilies.API.client.Transport = cloudTransport(func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Path, "RevokeToken") {
			revoked.Add(1)
			return cloudReply(`{"response":{}}`), nil
		}
		close(started)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	go func() {
		requestDone <- familyRequestTest(p, catalog, familyRequest{Operation: "state", Session: session}).Code
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("state request did not start")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	p.closeSteamFamilies(ctx)
	select {
	case code := <-requestDone:
		if code == 200 {
			t.Fatal("retired state request succeeded")
		}
	case <-ctx.Done():
		t.Fatal("shutdown did not cancel request")
	}
	if revoked.Load() != 1 || len(p.steamFamilies.Sessions) != 0 || s.Access != "" || s.Refresh != "" {
		t.Fatal("shutdown retained authority")
	}
	if familyRequestTest(p, catalog, familyRequest{Operation: "start", Consent: true}).Code != 429 {
		t.Fatal("shutdown admitted a new session")
	}
	p.closeSteamFamilies(ctx)
	if revoked.Load() != 1 {
		t.Fatal("shutdown revocation repeated")
	}
}

func TestFamilyOnlyOneSessionPerSteamAccount(t *testing.T) {
	p, _, _, _, count := familyTestProxy(t)
	secondCatalog := p.issueSteamCatalogGrant(cloudTestID)
	if familyRequestTest(p, secondCatalog, familyRequest{Operation: "start", Consent: true}).Code != 409 || count.Load() != 0 {
		t.Fatal("same-account parallel authorization admitted")
	}
}
