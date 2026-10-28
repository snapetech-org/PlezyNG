package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const steamCloudTTL = 30 * time.Minute

type steamCloudBinding struct {
	Catalog [32]byte
	SteamID string
	AppID   uint32
	Write   bool
}
type steamCloudGrant struct {
	binding steamCloudBinding
	token   string
	expires time.Time
	cancel  context.CancelFunc
}
type steamCloudState struct {
	clientID            string
	readApps, writeApps map[uint32]bool
	api                 *steamCloudAPI
	// Guarded by oauthProxy.mu. Grants are independent short-lived capabilities,
	// bound to the still-live catalog identity and exactly one approved AppID.
	grants map[[32]byte]*steamCloudGrant
	busy   map[string]bool
	active int
}

func steamCloudApps(raw string) (map[uint32]bool, bool) {
	result := map[uint32]bool{}
	if raw == "" {
		return result, true
	}
	fields := strings.Split(raw, ",")
	if len(fields) > 256 {
		return nil, false
	}
	for _, field := range fields {
		n, err := strconv.ParseUint(strings.TrimSpace(field), 10, 32)
		if err != nil || n == 0 {
			return nil, false
		}
		result[uint32(n)] = true
	}
	return result, true
}
func (p *oauthProxy) configureSteamCloud() {
	id := strings.TrimSpace(os.Getenv("STEAM_CLOUD_CLIENT_ID"))
	if id == "" {
		return
	}
	base, err := url.Parse(p.baseURL)
	if err != nil || base.Scheme != "https" || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" || len(id) > 128 || strings.ContainsAny(id, "\r\n\x00") {
		return
	}
	read, ok := steamCloudApps(os.Getenv("STEAM_CLOUD_READ_APPIDS"))
	if !ok || len(read) == 0 {
		return
	}
	write, ok := steamCloudApps(os.Getenv("STEAM_CLOUD_WRITE_APPIDS"))
	if !ok {
		return
	}
	for app := range write {
		if !read[app] {
			return
		}
	}
	hosts := map[string]bool{}
	for _, host := range strings.Split(os.Getenv("STEAM_CLOUD_STORAGE_HOSTS"), ",") {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" || len(host) > 253 || !strings.Contains(host, ".") || net.ParseIP(host) != nil || strings.ContainsAny(host, ":/@?#\\* \r\n\x00") {
			return
		}
		hosts[host] = true
	}
	p.steamCloud = &steamCloudState{clientID: id, readApps: read, writeApps: write, api: newSteamCloudAPI(p.steamClient, hosts), grants: map[[32]byte]*steamCloudGrant{}, busy: map[string]bool{}}
	p.services["steam-cloud"] = oauthServiceConfig{ClientID: id}
}
func cloudHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store, private")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
}
func cloudBearer(r *http.Request) ([32]byte, bool) {
	var empty [32]byte
	headers := r.Header.Values("Authorization")
	if len(headers) != 1 || !strings.HasPrefix(headers[0], "Bearer ") {
		return empty, false
	}
	token := strings.TrimPrefix(headers[0], "Bearer ")
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(token) != 43 || len(decoded) != 32 {
		return empty, false
	}
	return sha256.Sum256([]byte(token)), true
}
func cloudJSON(w http.ResponseWriter, r *http.Request, limit int64, value any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit))
	decoder.DisallowUnknownFields()
	return decoder.Decode(value) == nil && decoder.Decode(new(any)) == io.EOF
}
func (p *oauthProxy) cloudRate(w http.ResponseWriter, r *http.Request) bool {
	ip, err := p.clientIPs.resolve(r)
	if err != nil {
		http.Error(w, "Invalid client address", 400)
		return false
	}
	if allowed, _ := p.pollAllow(ip); !allowed {
		w.Header().Set("Retry-After", "30")
		http.Error(w, "Try later", 429)
		return false
	}
	return true
}
func (p *oauthProxy) cloudCatalog(r *http.Request) (steamCloudBinding, bool) {
	digest, ok := cloudBearer(r)
	if !ok {
		return steamCloudBinding{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	grant := p.steamCatalogGrants[digest]
	if grant == nil || !time.Now().Before(grant.expires) {
		return steamCloudBinding{}, false
	}
	return steamCloudBinding{Catalog: digest, SteamID: grant.steamID}, true
}
func (p *oauthProxy) handleSteamCloudCapabilities(w http.ResponseWriter, r *http.Request) {
	cloudHeaders(w)
	if r.Method != http.MethodPost || r.URL.RawQuery != "" {
		http.Error(w, "Invalid request", 400)
		return
	}
	if !p.cloudRate(w, r) {
		return
	}
	if _, ok := p.cloudCatalog(r); !ok {
		http.Error(w, "Relink Steam", 401)
		return
	}
	var input struct {
		AppID uint32 `json:"appId"`
	}
	if !cloudJSON(w, r, 512, &input) || input.AppID == 0 {
		http.Error(w, "Invalid game", 400)
		return
	}
	read, write := false, false
	if p.steamCloud != nil {
		read = p.steamCloud.readApps[input.AppID]
		write = p.steamCloud.writeApps[input.AppID]
	}
	writeJSON(w, 200, map[string]any{"appId": input.AppID, "read": read, "write": write, "familiesWrite": false, "maxFileBytes": steamCloudMaxFile})
}
func (p *oauthProxy) handleSteamCloudStart(w http.ResponseWriter, r *http.Request) {
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
	var input struct {
		AppID uint32 `json:"appId"`
		Write bool   `json:"write"`
	}
	if !cloudJSON(w, r, 512, &input) || input.AppID == 0 {
		http.Error(w, "Invalid game", 400)
		return
	}
	c := p.steamCloud
	if c == nil || !c.readApps[input.AppID] || (input.Write && !c.writeApps[input.AppID]) {
		http.Error(w, "Cloud access is not configured for this game", 403)
		return
	}
	binding.AppID = input.AppID
	binding.Write = input.Write
	secret := randToken(oauthPollSecretBytes)
	session := &oauthSession{browserState: randToken(oauthBrowserStateBytes), pollDigest: digestPollSecret(secret), service: "steam-cloud", createdAt: time.Now(), done: make(chan struct{}), steamCloud: &binding}
	p.mu.Lock()
	if len(p.browserStates) >= oauthMaxSessions || p.browserStates[session.browserState] != nil || p.pollDigests[session.pollDigest] != nil {
		p.mu.Unlock()
		http.Error(w, "Server busy", 503)
		return
	}
	p.addSessionLocked(session)
	p.mu.Unlock()
	writeJSON(w, 200, map[string]any{"session": secret, "url": p.baseURL + "/auth/steam-cloud?state=" + url.QueryEscape(session.browserState), "expiresIn": int(oauthSessionTTL.Seconds())})
}
func (p *oauthProxy) handleSteamCloudAuthorize(w http.ResponseWriter, r *http.Request, session *oauthSession) {
	cloudHeaders(w)
	if p.steamCloud == nil || session.steamCloud == nil {
		http.Error(w, "Cloud authorization unavailable", 403)
		return
	}
	values := url.Values{"response_type": {"token"}, "client_id": {p.steamCloud.clientID}, "state": {session.browserState}}
	http.Redirect(w, r, "https://steamcommunity.com/oauth/login?"+values.Encode(), http.StatusFound)
}
func (p *oauthProxy) handleSteamCloudCallback(w http.ResponseWriter, r *http.Request) {
	cloudHeaders(w)
	if p.steamCloud == nil || r.URL.RawQuery != "" {
		http.Error(w, "Cloud authorization unavailable", 404)
		return
	}
	if r.Method == http.MethodGet {
		// The token arrives in a fragment, not an HTTP URL. Remove it from history
		// before a same-origin POST; no analytics, external scripts or token echo.
		nonce := randToken(18)
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Steam Cloud · PlezyNG</title><body><p id="status" role="status">Completing Steam Cloud authorization…</p><script nonce="%s">(async()=>{const f=new URLSearchParams(location.hash.slice(1));history.replaceState(null,'',location.pathname);const s=document.getElementById('status');try{const keys=['state','access_token','token_type','error'];if(keys.some(k=>f.getAll(k).length>1))throw 0;const body={state:f.get('state')||'',token:f.get('access_token')||'',tokenType:f.get('token_type')||'',error:f.get('error')||''};const r=await fetch(location.pathname,{method:'POST',credentials:'omit',redirect:'error',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});body.token='';s.textContent=r.ok?'Return to PlezyNG.':'Authorization failed. Start again in PlezyNG.';}catch(_){s.textContent='Authorization failed. Start again in PlezyNG.'}})();</script></body></html>`, nonce)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", 405)
		return
	}
	base, err := url.Parse(p.baseURL)
	if err != nil || r.Header.Get("Origin") != base.Scheme+"://"+base.Host || !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		http.Error(w, "Invalid callback", 403)
		return
	}
	var input struct {
		State string `json:"state"`
		Token string `json:"token"`
		Type  string `json:"tokenType"`
		Error string `json:"error"`
	}
	if !cloudJSON(w, r, 8192, &input) || len(input.State) > 128 || (input.Error == "" && (input.Type != "steam" || len(input.Token) < 16 || len(input.Token) > 4096 || strings.ContainsAny(input.Token, "\r\n\x00"))) {
		http.Error(w, "Invalid callback", 400)
		return
	}
	p.mu.Lock()
	session := p.browserStates[input.State]
	valid := session != nil && session.service == "steam-cloud" && session.steamCloud != nil && !session.callbackClaimed && time.Since(session.createdAt) < oauthSessionTTL
	if valid {
		session.callbackClaimed = true
	}
	p.mu.Unlock()
	if !valid {
		http.Error(w, "Authorization expired", 404)
		return
	}
	fail := func() {
		p.completeSession(session, oauthTokenResult{Error: "authorization_failed"})
		http.Error(w, "Authorization failed", 403)
	}
	if input.Error != "" {
		p.completeSession(session, oauthTokenResult{Error: "access_denied"})
		w.WriteHeader(204)
		return
	}
	binding := *session.steamCloud
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	steamID, err := p.steamCloudIdentity(ctx, input.Token)
	if err != nil || steamID != binding.SteamID {
		fail()
		return
	}
	// Verify actual read access before issuing any app capability; configured
	// allowlists alone do not establish that Valve granted this token access.
	if _, err = p.steamCloud.api.files(ctx, input.Token, binding.SteamID, binding.AppID); err != nil {
		fail()
		return
	}
	secret := randToken(32)
	digest := sha256.Sum256([]byte(secret))
	grant := &steamCloudGrant{binding: binding, token: input.Token, expires: time.Now().Add(steamCloudTTL)}
	p.mu.Lock()
	p.cleanupSteamCloudLocked(time.Now())
	catalog := p.steamCatalogGrants[binding.Catalog]
	valid = catalog != nil && catalog.steamID == binding.SteamID && time.Now().Before(catalog.expires) && len(p.steamCloud.grants) < 256
	if valid {
		p.steamCloud.grants[digest] = grant
	}
	p.mu.Unlock()
	if !valid {
		fail()
		return
	}
	if !p.completeSession(session, oauthTokenResult{SteamID: steamID, SteamCloudToken: secret}) {
		p.mu.Lock()
		delete(p.steamCloud.grants, digest)
		p.mu.Unlock()
		http.Error(w, "Authorization expired", 404)
		return
	}
	w.WriteHeader(204)
}
func (p *oauthProxy) steamCloudIdentity(ctx context.Context, token string) (string, error) {
	endpoint := "https://api.steampowered.com/ISteamUserOAuth/GetTokenDetails/v1/?" + url.Values{"access_token": {token}}.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", errSteamCloud
	}
	client := *p.steamClient
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(request)
	if err != nil {
		return "", errSteamCloud
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || (response.Header.Get("x-eresult") != "" && response.Header.Get("x-eresult") != "1") {
		return "", errSteamCloud
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(data) > 65536 {
		return "", errSteamCloud
	}
	var result struct {
		Response struct {
			SteamID steamCloudNumber `json:"steamid"`
		} `json:"response"`
	}
	if json.Unmarshal(data, &result) != nil || !steamIDPattern.MatchString(result.Response.SteamID.String()) {
		return "", errSteamCloud
	}
	return result.Response.SteamID.String(), nil
}
func (p *oauthProxy) cleanupSteamCloudLocked(now time.Time) {
	if p.steamCloud == nil {
		return
	}
	for digest, grant := range p.steamCloud.grants {
		catalog := p.steamCatalogGrants[grant.binding.Catalog]
		if !now.Before(grant.expires) || catalog == nil || !now.Before(catalog.expires) {
			if grant.cancel != nil {
				grant.cancel()
			}
			grant.token = ""
			delete(p.steamCloud.grants, digest)
		}
	}
}
func (p *oauthProxy) handleSteamCloudFiles(w http.ResponseWriter, r *http.Request) {
	cloudHeaders(w)
	if (r.Method != http.MethodPost && r.Method != http.MethodDelete) || r.URL.RawQuery != "" {
		http.Error(w, "Invalid request", 400)
		return
	}
	if !p.cloudRate(w, r) {
		return
	}
	digest, ok := cloudBearer(r)
	if !ok || p.steamCloud == nil {
		http.Error(w, "Authorize Steam Cloud", 401)
		return
	}
	c := p.steamCloud
	p.mu.Lock()
	p.cleanupSteamCloudLocked(time.Now())
	grant := c.grants[digest]
	if grant == nil {
		p.mu.Unlock()
		http.Error(w, "Authorize Steam Cloud", 401)
		return
	}
	if r.Method == http.MethodDelete {
		if grant.cancel != nil {
			grant.cancel()
		}
		grant.token = ""
		delete(c.grants, digest)
		p.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	binding := grant.binding
	key := binding.SteamID + ":" + strconv.FormatUint(uint64(binding.AppID), 10)
	if c.active >= 8 || c.busy[key] {
		p.mu.Unlock()
		http.Error(w, "Cloud operation already in progress", 429)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	grant.cancel = cancel
	token := grant.token
	c.active++
	c.busy[key] = true
	p.mu.Unlock()
	defer func() {
		cancel()
		p.mu.Lock()
		c.active--
		delete(c.busy, key)
		grant.cancel = nil
		p.mu.Unlock()
	}()
	// The normal server write deadline is shorter than a Cloud transfer plus
	// its two mandatory bounded finalizers. Extend only this authenticated
	// request, before any upstream mutation; the next request resets its deadline.
	if err := http.NewResponseController(w).SetWriteDeadline(time.Now().Add(125 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
		http.Error(w, "Cloud transport unavailable", 503)
		return
	}
	var input struct {
		Action   string `json:"action"`
		Name     string `json:"filename"`
		Expected string `json:"expectedSha"`
		Data     []byte `json:"data"`
	}
	if !cloudJSON(w, r, 12<<20, &input) {
		http.Error(w, "Invalid Cloud request", 400)
		return
	}
	var result any
	var err error
	switch input.Action {
	case "list":
		var files []steamCloudFile
		files, err = c.api.files(ctx, token, binding.SteamID, binding.AppID)
		if err == nil {
			rows := make([]map[string]any, 0, len(files))
			for _, file := range files {
				rows = append(rows, map[string]any{"name": file.Name, "size": file.Size, "sha": file.SHA, "modified": uint64(file.Timestamp)})
			}
			result = map[string]any{"appId": binding.AppID, "steamId": binding.SteamID, "write": binding.Write, "files": rows}
		}
	case "download":
		if !cloudName(input.Name) || !cloudSHA(input.Expected) {
			http.Error(w, "Invalid file", 400)
			return
		}
		var files []steamCloudFile
		files, err = c.api.files(ctx, token, binding.SteamID, binding.AppID)
		if err == nil {
			err = errSteamCloudConflict
			for _, file := range files {
				if file.Name == input.Name && strings.EqualFold(file.SHA, input.Expected) {
					var data []byte
					data, err = c.api.download(ctx, file)
					result = map[string]any{"name": file.Name, "data": data, "sha": file.SHA}
					break
				}
			}
		}
	case "upload", "delete":
		if !binding.Write {
			http.Error(w, "Write authorization required", 403)
			return
		}
		if !cloudName(input.Name) || len(input.Data) > steamCloudMaxFile || (input.Expected != "" && !cloudSHA(input.Expected)) || (input.Action == "delete" && (input.Expected == "" || len(input.Data) != 0)) {
			http.Error(w, "Invalid file change", 400)
			return
		}
		err = c.api.mutate(ctx, token, binding.SteamID, binding.AppID, input.Name, input.Expected, input.Data, input.Action == "delete")
		result = map[string]any{"completed": true}
	default:
		http.Error(w, "Invalid Cloud action", 400)
		return
	}
	if err != nil {
		writeJSON(w, 409, map[string]any{"error": "refresh_required"})
		return
	}
	p.mu.Lock()
	current := c.grants[digest] == grant && p.steamCatalogGrants[binding.Catalog] != nil && time.Now().Before(grant.expires)
	p.mu.Unlock()
	if !current {
		http.Error(w, "Cloud authorization retired", 401)
		return
	}
	writeJSON(w, 200, result)
}
