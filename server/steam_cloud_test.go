package main

import (
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
)

const cloudTestID = "76561198000000001"

type cloudTransport func(*http.Request) (*http.Response, error)

func (f cloudTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func cloudReply(body string) *http.Response {
	return &http.Response{StatusCode: 200, Header: http.Header{"X-Eresult": {"1"}}, Body: io.NopCloser(strings.NewReader(body))}
}
func cloudTestAPI(t *testing.T, fail string) (*steamCloudAPI, *[]string) {
	t.Helper()
	calls := []string{}
	client := &http.Client{Transport: cloudTransport(func(r *http.Request) (*http.Response, error) {
		method := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/ICloudService/"), "/v1/")
		calls = append(calls, method)
		if r.URL.Host == "storage.steam.test" {
			calls[len(calls)-1] = "PUT"
			if r.Header.Get("Authorization") != "signed-storage" {
				t.Error("missing storage signature")
			}
			if fail == "PUT" {
				return nil, errors.New("transport failed with private URL")
			}
			return cloudReply(""), nil
		}
		if r.URL.Host != "api.steampowered.com" {
			t.Fatal("unexpected origin")
		}
		if method == "EnumerateUserFiles" {
			if r.Method != "GET" || r.URL.Query().Get("access_token") != "upstream-token" {
				t.Error("read contract")
			}
			return cloudReply(`{"response":{"total_files":1,"files":[{"appid":620,"filename":"save/slot1.sav","file_size":3,"timestamp":"1700000000","steamid_creator":"` + cloudTestID + `","file_sha":"a9993e364706816aba3e25717850c26c9cd0d89d","url":"https://storage.steam.test/save","platforms_to_sync":["Windows","linux"]}]}}`), nil
		}
		if r.Method != "POST" || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			t.Error("mutation must use form POST")
		}
		if r.ParseForm() != nil || r.PostForm.Get("access_token") != "upstream-token" {
			t.Error("missing scoped token")
		}
		var input map[string]any
		if json.Unmarshal([]byte(r.PostForm.Get("input_json")), &input) != nil {
			t.Fatal("missing input_json")
		}
		if input["appid"] != float64(620) {
			t.Error("wrong app")
		}
		if method == fail {
			reply := cloudReply(`{"response":{}}`)
			reply.Header.Set("x-eresult", "15")
			return reply, nil
		}
		switch method {
		case "BeginAppUploadBatch":
			return cloudReply(`{"response":{"batch_id":"18446744073709551614"}}`), nil
		case "BeginHTTPUpload":
			if input["upload_batch_id"] != "18446744073709551614" {
				t.Error("batch ID rounded")
			}
			platforms := input["platforms_to_sync"].([]any)
			if len(platforms) != 2 || platforms[0] != "windows" {
				t.Error("replacement lost platform restriction")
			}
			return cloudReply(`{"response":{"url_host":"storage.steam.test","url_path":"/save?signature=secret","use_https":true,"request_headers":[{"name":"Authorization","value":"signed-storage"}]}}`), nil
		case "CommitHTTPUpload":
			if input["transfer_succeeded"] != (fail != "PUT") {
				t.Error("incorrect transfer outcome")
			}
			return cloudReply(`{"response":{"file_committed":true}}`), nil
		case "CompleteAppUploadBatch":
			want := float64(1)
			if fail != "" {
				want = 2
			}
			if input["batch_eresult"] != want {
				t.Errorf("batch outcome %v, want %v", input["batch_eresult"], want)
			}
			return cloudReply(""), nil
		case "Delete":
			return cloudReply(""), nil
		}
		t.Fatalf("unexpected method %s", method)
		return nil, nil
	})}
	return &steamCloudAPI{api: client, storage: client, storageHosts: map[string]bool{"storage.steam.test": true}}, &calls
}
func TestSteamCloudBatchSuccessAndFailureCleanup(t *testing.T) {
	for _, failure := range []string{"", "PUT", "BeginHTTPUpload", "CommitHTTPUpload", "Delete", "CompleteAppUploadBatch"} {
		t.Run(failure, func(t *testing.T) {
			api, calls := cloudTestAPI(t, failure)
			err := api.mutate(context.Background(), "upstream-token", cloudTestID, 620, "save/slot1.sav", "a9993e364706816aba3e25717850c26c9cd0d89d", []byte("new"), failure == "Delete")
			if (err == nil) != (failure == "") {
				t.Fatalf("unexpected result %v", err)
			}
			if (*calls)[len(*calls)-1] != "CompleteAppUploadBatch" {
				t.Fatal("batch not finalized")
			}
			if failure == "PUT" && !strings.Contains(strings.Join(*calls, ","), "PUT,CommitHTTPUpload,CompleteAppUploadBatch") {
				t.Fatal("failed transfer not committed/finalized")
			}
		})
	}
}
func TestSteamCloudConflictAndOriginBoundaries(t *testing.T) {
	api, calls := cloudTestAPI(t, "")
	if api.mutate(context.Background(), "upstream-token", cloudTestID, 620, "save/slot1.sav", "", nil, false) != errSteamCloudConflict {
		t.Fatal("blind overwrite allowed")
	}
	if len(*calls) != 1 {
		t.Fatal("conflict issued mutation")
	}
	for _, u := range []string{"http://storage.steam.test/save", "https://evil.test/save", "https://user@storage.steam.test/save", "https://storage.steam.test:443/save", "https://storage.steam.test/save#secret", "https://storage.steam.test.evil/save"} {
		if _, err := api.storageURL(u); err == nil {
			t.Errorf("accepted %s", u)
		}
	}
	for _, ip := range []string{"127.0.0.1", "10.0.0.1", "100.64.1.1", "169.254.169.254", "::1", "::ffff:127.0.0.1", "fd00::1", "64:ff9b::a00:1", "198.18.0.1"} {
		if steamCloudPublicIP(netip.MustParseAddr(ip)) {
			t.Errorf("accepted private address %s", ip)
		}
	}
	if !steamCloudPublicIP(netip.MustParseAddr("1.1.1.1")) {
		t.Fatal("rejected public address")
	}
}
func TestSteamCloudDownloadIntegrityAndRedirect(t *testing.T) {
	api, _ := cloudTestAPI(t, "")
	sum := sha1.Sum([]byte("abc"))
	file := steamCloudFile{Size: 3, SHA: hex.EncodeToString(sum[:]), URL: "https://storage.steam.test/save"}
	api.storage = &http.Client{Transport: cloudTransport(func(*http.Request) (*http.Response, error) { return cloudReply("abc"), nil })}
	if data, err := api.download(context.Background(), file); err != nil || string(data) != "abc" {
		t.Fatal("valid download failed")
	}
	file.Size = 2
	if _, err := api.download(context.Background(), file); err == nil {
		t.Fatal("wrong size accepted")
	}
	file.Size = 3
	file.SHA = strings.Repeat("0", 40)
	if _, err := api.download(context.Background(), file); err == nil {
		t.Fatal("wrong hash accepted")
	}
	api.storage = &http.Client{Transport: cloudTransport(func(*http.Request) (*http.Response, error) {
		r := cloudReply("")
		r.StatusCode = 302
		r.Header.Set("Location", "https://evil.test")
		return r, nil
	})}
	if _, err := api.download(context.Background(), file); err == nil {
		t.Fatal("followed storage redirect")
	}
}
func cloudTestProxy(t *testing.T) (*oauthProxy, string, string) {
	t.Helper()
	p := newOAuthProxy("https://plezy.test", map[string]oauthServiceConfig{"steam": {}, "steam-cloud": {ClientID: "approved-client"}}, clientIPResolver{})
	catalog := p.issueSteamCatalogGrant(cloudTestID)
	api, _ := cloudTestAPI(t, "")
	p.steamCloud = &steamCloudState{clientID: "approved-client", readApps: map[uint32]bool{620: true}, writeApps: map[uint32]bool{620: true}, api: api, grants: map[[32]byte]*steamCloudGrant{}, busy: map[string]bool{}}
	grant := strings.Repeat("g", 43)
	digest := sha256.Sum256([]byte(grant))
	p.steamCloud.grants[digest] = &steamCloudGrant{binding: steamCloudBinding{Catalog: sha256.Sum256([]byte(catalog)), SteamID: cloudTestID, AppID: 620}, token: "upstream-token", expires: time.Now().Add(time.Minute)}
	return p, catalog, grant
}
func cloudRequest(p *oauthProxy, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://plezy.test"+path, strings.NewReader(body))
	r.RemoteAddr = "192.0.2.1:1234"
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	switch path {
	case "/cap":
		p.handleSteamCloudCapabilities(w, r)
	case "/start":
		p.handleSteamCloudStart(w, r)
	default:
		p.handleSteamCloudFiles(w, r)
	}
	return w
}
func TestSteamCloudGrantSeparationAndRevocation(t *testing.T) {
	p, catalog, grant := cloudTestProxy(t)
	if w := cloudRequest(p, "/files", catalog, `{"action":"list"}`); w.Code != 401 {
		t.Fatal("catalog used as Cloud authority")
	}
	if w := cloudRequest(p, "/files", grant, `{"action":"delete","filename":"save/slot1.sav","expectedSha":"a9993e364706816aba3e25717850c26c9cd0d89d"}`); w.Code != 403 {
		t.Fatal("read grant allowed write")
	}
	if w := cloudRequest(p, "/start", catalog, `{"appId":999,"write":true}`); w.Code != 403 {
		t.Fatal("unapproved app accepted")
	}
	if w := cloudRequest(p, "/files", grant, `{"action":"list"}`); w.Code != 200 || strings.Contains(w.Body.String(), "storage.steam.test") || strings.Contains(w.Body.String(), "upstream-token") {
		t.Fatalf("listing failed/leaked %d", w.Code)
	}
	delete(p.steamCatalogGrants, sha256.Sum256([]byte(catalog)))
	if w := cloudRequest(p, "/files", grant, `{"action":"list"}`); w.Code != 401 {
		t.Fatal("revoked identity retained access")
	}
}
func TestSteamCloudOAuthIdentityAndOrigin(t *testing.T) {
	p, catalog, _ := cloudTestProxy(t)
	started := cloudRequest(p, "/start", catalog, `{"appId":620,"write":true}`)
	if started.Code != 200 {
		t.Fatal(started.Body.String())
	}
	var session *oauthSession
	for _, s := range p.browserStates {
		session = s
	}
	payload := `{"state":"` + session.browserState + `","token":"another-user-token","tokenType":"steam"}`
	p.steamClient = &http.Client{Transport: cloudTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.steampowered.com" || !strings.HasPrefix(r.URL.Path, "/ISteamUserOAuth/") {
			t.Fatal("wrong identity endpoint")
		}
		return cloudReply(`{"response":{"steamid":"76561198000000002"}}`), nil
	})}
	post := func(origin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "https://plezy.test/auth/steam-cloud/callback", strings.NewReader(payload))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		p.handleSteamCloudCallback(w, r)
		return w
	}
	if post("https://evil.test").Code != 403 || session.callbackClaimed {
		t.Fatal("cross-origin callback accepted/consumed")
	}
	if post("https://plezy.test").Code != 403 || !session.callbackClaimed {
		t.Fatal("wrong Steam identity accepted")
	}
	if post("https://plezy.test").Code != 404 {
		t.Fatal("callback replay accepted")
	}
}

func TestSteamCloudOAuthGrantAndExpiry(t *testing.T) {
	p, catalog, _ := cloudTestProxy(t)
	p.steamCloud.api.api = &http.Client{Transport: cloudTransport(func(*http.Request) (*http.Response, error) {
		return cloudReply(`{"response":{"total_files":0,"files":[]}}`), nil
	})}
	for _, write := range []bool{false, true} {
		body, _ := json.Marshal(map[string]any{"appId": 620, "write": write})
		started := cloudRequest(p, "/start", catalog, string(body))
		if started.Code != 200 {
			t.Fatal("authorization did not start")
		}
		var session *oauthSession
		for _, s := range p.browserStates {
			if !s.callbackClaimed {
				session = s
			}
		}
		p.steamClient = &http.Client{Transport: cloudTransport(func(*http.Request) (*http.Response, error) {
			return cloudReply(`{"response":{"steamid":` + cloudTestID + `}}`), nil
		})}
		r := httptest.NewRequest("POST", "https://plezy.test/auth/steam-cloud/callback", strings.NewReader(`{"state":"`+session.browserState+`","token":"upstream-token-value","tokenType":"steam"}`))
		r.Header.Set("Origin", "https://plezy.test")
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		p.handleSteamCloudCallback(w, r)
		if w.Code != 204 || session.result.SteamID != cloudTestID || session.result.SteamCloudToken == "" || session.result.AccessToken != "" {
			t.Fatalf("invalid grant: HTTP %d", w.Code)
		}
		key := sha256.Sum256([]byte(session.result.SteamCloudToken))
		grant := p.steamCloud.grants[key]
		if grant == nil || grant.binding.Write != write || grant.binding.AppID != 620 || grant.binding.SteamID != cloudTestID {
			t.Fatal("grant lost identity/read-write binding")
		}
		p.cleanupSteamCloudLocked(time.Now().Add(steamCloudTTL + time.Second))
		if p.steamCloud.grants[key] != nil || grant.token != "" {
			t.Fatal("expired upstream token retained")
		}
	}
	r := httptest.NewRequest("GET", "https://plezy.test/auth/steam-cloud/callback", nil)
	w := httptest.NewRecorder()
	p.handleSteamCloudCallback(w, r)
	if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") || !strings.Contains(w.Body.String(), "history.replaceState") {
		t.Fatal("unsafe OAuth landing page")
	}
	r = httptest.NewRequest("GET", "https://plezy.test/auth/steam-cloud/callback?access_token=secret", nil)
	w = httptest.NewRecorder()
	p.handleSteamCloudCallback(w, r)
	if w.Code != 404 || strings.Contains(w.Body.String(), "secret") {
		t.Fatal("query token accepted or echoed")
	}
}

type cloudDeadlineWriter struct {
	*httptest.ResponseRecorder
	deadline time.Time
	err      error
}

func (w *cloudDeadlineWriter) SetWriteDeadline(value time.Time) error {
	w.deadline = value
	return w.err
}
func TestSteamCloudTransferDeadlineAndCancellation(t *testing.T) {
	p, _, grant := cloudTestProxy(t)
	r := httptest.NewRequest("POST", "https://plezy.test/auth/steam/cloud/files", strings.NewReader(`{"action":"list"}`))
	r.Header.Set("Authorization", "Bearer "+grant)
	w := &cloudDeadlineWriter{ResponseRecorder: httptest.NewRecorder()}
	p.handleSteamCloudFiles(w, r)
	if w.Code != 200 || time.Until(w.deadline) < 120*time.Second {
		t.Fatal("Cloud inherited the shorter ordinary write deadline")
	}
	api, calls := cloudTestAPI(t, "PUT")
	original := api.storage.Transport
	ctx, cancel := context.WithCancel(context.Background())
	api.storage = &http.Client{Transport: cloudTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "storage.steam.test" {
			cancel()
		}
		if strings.Contains(r.URL.Path, "CommitHTTPUpload") || strings.Contains(r.URL.Path, "CompleteAppUploadBatch") {
			if r.Context().Err() != nil {
				t.Error("mandatory cleanup inherited cancellation")
			}
		}
		return original.RoundTrip(r)
	})}
	api.api = api.storage
	if api.mutate(ctx, "upstream-token", cloudTestID, 620, "save/slot1.sav", "a9993e364706816aba3e25717850c26c9cd0d89d", []byte("new"), false) == nil {
		t.Fatal("cancelled mutation reported success")
	}
	if !strings.Contains(strings.Join(*calls, ","), "PUT,CommitHTTPUpload,CompleteAppUploadBatch") {
		t.Fatal("cancelled upload left batch open")
	}
}

func TestSteamCloudConfigurationFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name, base, id, read, write, hosts string
		enabled                            bool
	}{
		{name: "default", base: "https://plezy.test"},
		{name: "valid", base: "https://plezy.test", id: "approved", read: "620", hosts: "storage.steam.test", enabled: true},
		{name: "bad-write", base: "https://plezy.test", id: "approved", read: "620", write: "999", hosts: "storage.steam.test"},
		{name: "cleartext", base: "http://plezy.test", id: "approved", read: "620", hosts: "storage.steam.test"},
		{name: "wildcard", base: "https://plezy.test", id: "approved", read: "620", hosts: "*.steam.test"},
		{name: "overflow", base: "https://plezy.test", id: "approved", read: "4294967296", hosts: "storage.steam.test"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("STEAM_CLOUD_CLIENT_ID", tc.id)
			t.Setenv("STEAM_CLOUD_READ_APPIDS", tc.read)
			t.Setenv("STEAM_CLOUD_WRITE_APPIDS", tc.write)
			t.Setenv("STEAM_CLOUD_STORAGE_HOSTS", tc.hosts)
			p := newOAuthProxy(tc.base, map[string]oauthServiceConfig{}, clientIPResolver{})
			p.configureSteamCloud()
			if (p.steamCloud != nil) != tc.enabled {
				t.Fatal("invalid eligibility configuration accepted")
			}
		})
	}
}
