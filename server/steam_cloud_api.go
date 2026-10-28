package main

// Valve's OAuth Cloud API is AppID-scoped. This adapter has no publisher key,
// browser cookie, Steam password or implicit authority from an OpenID catalog.
import (
	"bytes"
	"context"
	"crypto/sha1" // Steam's wire checksum, not an authentication primitive.
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const steamCloudMaxFile = 8 << 20

var errSteamCloud = errors.New("Steam Cloud operation unavailable")
var errSteamCloudConflict = errors.New("Steam Cloud file changed; refresh before trying again")

// Steam serializes uint64 values both as JSON strings and numbers. Never round
// identities, batch IDs or timestamps through a float64.
type steamCloudNumber uint64

func (n *steamCloudNumber) UnmarshalJSON(data []byte) error {
	text := string(data)
	if len(data) > 0 && data[0] == '"' {
		if json.Unmarshal(data, &text) != nil {
			return errSteamCloud
		}
	}
	if text == "" || strings.Trim(text, "0123456789") != "" {
		return errSteamCloud
	}
	value, err := strconv.ParseUint(text, 10, 64)
	if err != nil {
		return errSteamCloud
	}
	*n = steamCloudNumber(value)
	return nil
}
func (n steamCloudNumber) String() string { return strconv.FormatUint(uint64(n), 10) }

type steamCloudFile struct {
	AppID     uint32           `json:"appid"`
	Name      string           `json:"filename"`
	Size      uint32           `json:"file_size"`
	Timestamp steamCloudNumber `json:"timestamp"`
	Creator   steamCloudNumber `json:"steamid_creator"`
	SHA       string           `json:"file_sha"`
	URL       string           `json:"url"`
	// Preserve Valve's platform restriction when replacing a file. The upstream
	// representation has varied between a list and a comma-delimited string.
	Platforms json.RawMessage `json:"platforms_to_sync"`
}
type steamCloudAPI struct {
	api          *http.Client
	storage      *http.Client
	storageHosts map[string]bool // Exact operator-reviewed Valve storage hosts.
}

func newSteamCloudAPI(api *http.Client, hosts map[string]bool) *steamCloudAPI {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = steamCloudPublicDial
	return &steamCloudAPI{api: api, storage: &http.Client{Transport: transport, Timeout: 30 * time.Second}, storageHosts: hosts}
}
func steamCloudPublicIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsValid() || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	// Includes carrier NAT, benchmarking, documentation and transition ranges;
	// an approved hostname must never turn the proxy into an internal connector.
	for _, raw := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "::/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/32", "2001:db8::/32", "2002::/16"} {
		if netip.MustParsePrefix(raw).Contains(ip) {
			return false
		}
	}
	return true
}
func steamCloudPublicDial(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil || port != "443" {
		return nil, errSteamCloud
	}
	addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(addresses) == 0 {
		return nil, errSteamCloud
	}
	for _, ip := range addresses {
		if !steamCloudPublicIP(ip) {
			return nil, errSteamCloud
		}
	}
	dialer := net.Dialer{Timeout: 10 * time.Second}
	for _, ip := range addresses {
		connection, e := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if e == nil {
			return connection, nil
		}
	}
	return nil, errSteamCloud
}
func cloudName(name string) bool {
	if name == "" || len(name) > 1024 || !utf8.ValidString(name) {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true // Opaque Cloud key; never joined to a local filesystem path.
}
func cloudSHA(value string) bool {
	_, err := hex.DecodeString(value)
	return len(value) == 40 && err == nil
}
func cloudPlatforms(raw json.RawMessage) ([]string, error) {
	var result []string
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errSteamCloud
	}
	if json.Unmarshal(raw, &result) != nil {
		var text string
		if json.Unmarshal(raw, &text) != nil {
			return nil, errSteamCloud
		}
		result = strings.Split(text, ",")
	}
	if len(result) == 0 || len(result) > 7 {
		return nil, errSteamCloud
	}
	seen := map[string]bool{}
	for i, p := range result {
		p = strings.ToLower(strings.TrimSpace(p))
		result[i] = p
		switch p {
		case "all", "windows", "macos", "linux", "android", "iphoneos", "switch":
		default:
			return nil, errSteamCloud
		}
		if seen[p] {
			return nil, errSteamCloud
		}
		seen[p] = true
	}
	return result, nil
}
func (a *steamCloudAPI) call(ctx context.Context, token, method string, params map[string]any, result any) error {
	// method is selected only by this package, never supplied by the request.
	endpoint := "https://api.steampowered.com/ICloudService/" + method + "/v1/"
	values := url.Values{"access_token": {token}}
	verb := http.MethodPost
	var body io.Reader
	if method == "EnumerateUserFiles" {
		verb = http.MethodGet
		for key, value := range params {
			values.Set(key, fmt.Sprint(value))
		}
		endpoint += "?" + values.Encode()
	} else {
		encoded, err := json.Marshal(params)
		if err != nil {
			return errSteamCloud
		}
		values.Set("input_json", string(encoded))
		body = strings.NewReader(values.Encode())
	}
	request, err := http.NewRequestWithContext(ctx, verb, endpoint, body)
	if err != nil {
		return errSteamCloud
	}
	if verb == http.MethodPost {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	client := *a.api
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(request)
	if err != nil {
		return errSteamCloud
	}
	defer response.Body.Close()
	// Steam can report a failed operation with HTTP 200.
	if response.StatusCode != http.StatusOK || (response.Header.Get("x-eresult") != "" && response.Header.Get("x-eresult") != "1") {
		return errSteamCloud
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if err != nil || len(data) > 2<<20 {
		return errSteamCloud
	}
	if result == nil {
		return nil
	}
	var envelope struct {
		Response json.RawMessage `json:"response"`
	}
	if json.Unmarshal(data, &envelope) != nil || len(envelope.Response) == 0 || json.Unmarshal(envelope.Response, result) != nil {
		return errSteamCloud
	}
	return nil
}
func (a *steamCloudAPI) files(ctx context.Context, token, steamID string, appID uint32) ([]steamCloudFile, error) {
	files := make([]steamCloudFile, 0)
	names := map[string]bool{}
	for start := 0; start < 2000; start += 200 {
		var page struct {
			Files []steamCloudFile `json:"files"`
			Total uint32           `json:"total_files"`
		}
		if a.call(ctx, token, "EnumerateUserFiles", map[string]any{"appid": appID, "extended_details": 1, "count": 200, "start_index": start}, &page) != nil {
			return nil, errSteamCloud
		}
		if page.Total > 2000 || len(page.Files) > 200 || len(files)+len(page.Files) > int(page.Total) {
			return nil, errSteamCloud
		}
		for _, file := range page.Files {
			if file.AppID != appID || file.Creator.String() != steamID || !cloudName(file.Name) || !cloudSHA(file.SHA) || names[file.Name] {
				return nil, errSteamCloud
			}
			names[file.Name] = true
			file.SHA = strings.ToLower(file.SHA)
			files = append(files, file)
		}
		if len(files) == int(page.Total) {
			return files, nil
		}
		if len(page.Files) != 200 {
			return nil, errSteamCloud
		}
	}
	return nil, errSteamCloud
}
func (a *steamCloudAPI) storageURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" || u.Port() != "" || u.Host != u.Hostname() || !a.storageHosts[strings.ToLower(u.Hostname())] || len(raw) > 8192 {
		return nil, errSteamCloud
	}
	return u, nil
}
func (a *steamCloudAPI) transfer(request *http.Request) (*http.Response, error) {
	client := *a.storage
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(request)
	if err != nil {
		return nil, errSteamCloud
	}
	return response, nil
}
func (a *steamCloudAPI) download(ctx context.Context, file steamCloudFile) ([]byte, error) {
	if file.Size > steamCloudMaxFile {
		return nil, errSteamCloud
	}
	u, err := a.storageURL(file.URL)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, errSteamCloud
	}
	response, err := a.transfer(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errSteamCloud
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, steamCloudMaxFile+1))
	if err != nil || len(data) != int(file.Size) {
		return nil, errSteamCloud
	}
	sum := sha1.Sum(data)
	if !strings.EqualFold(hex.EncodeToString(sum[:]), file.SHA) {
		return nil, errSteamCloud
	}
	return data, nil
}
func (a *steamCloudAPI) put(ctx context.Context, token string, appID uint32, batch steamCloudNumber, name string, data []byte, platforms []string) (err error) {
	sum := sha1.Sum(data)
	sha := hex.EncodeToString(sum[:])
	var destination struct {
		Host    string `json:"url_host"`
		Path    string `json:"url_path"`
		HTTPS   bool   `json:"use_https"`
		Headers []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		} `json:"request_headers"`
	}
	if a.call(ctx, token, "BeginHTTPUpload", map[string]any{"appid": appID, "filename": name, "file_size": len(data), "file_sha": sha, "is_public": false, "platforms_to_sync": platforms, "upload_batch_id": batch.String()}, &destination) != nil {
		return errSteamCloud
	}
	transferred := false
	// Commit a begun transfer even when its PUT fails or the client disconnects.
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
		defer cancel()
		var result struct {
			Committed bool `json:"file_committed"`
		}
		e := a.call(cleanup, token, "CommitHTTPUpload", map[string]any{"appid": appID, "filename": name, "file_sha": sha, "transfer_succeeded": transferred}, &result)
		if e != nil || !transferred || !result.Committed {
			err = errSteamCloud
		}
	}()
	if !destination.HTTPS || destination.Host == "" || strings.ContainsAny(destination.Host, "/@?#\\") || !strings.HasPrefix(destination.Path, "/") || strings.HasPrefix(destination.Path, "//") || len(destination.Headers) > 32 {
		return errSteamCloud
	}
	u, e := a.storageURL("https://" + destination.Host + destination.Path)
	if e != nil {
		return e
	}
	request, e := http.NewRequestWithContext(ctx, http.MethodPut, u.String(), bytes.NewReader(data))
	if e != nil {
		return errSteamCloud
	}
	for _, header := range destination.Headers {
		name := http.CanonicalHeaderKey(header.Name)
		if name == "" || len(name) > 128 || len(header.Value) > 4096 || strings.ContainsAny(header.Value, "\r\n\x00") {
			return errSteamCloud
		}
		switch name {
		case "Host", "Content-Length", "Connection", "Transfer-Encoding", "Te", "Trailer", "Upgrade", "Proxy-Authorization", "Proxy-Connection":
			return errSteamCloud
		}
		request.Header.Add(name, header.Value)
	}
	response, e := a.transfer(request)
	if e != nil {
		return e
	}
	defer response.Body.Close()
	transferred = response.StatusCode == 200 || response.StatusCode == 201 || response.StatusCode == 204
	if !transferred {
		return errSteamCloud
	}
	return nil
}

// The caller serializes mutations by SteamID/AppID and supplies a freshly read
// fingerprint. Completion is not atomic rollback; an ambiguous failure must be
// refreshed and reviewed by the user, never retried automatically.
func (a *steamCloudAPI) mutate(ctx context.Context, token, steamID string, appID uint32, name, expected string, data []byte, remove bool) (err error) {
	if !cloudName(name) || (expected != "" && !cloudSHA(expected)) || len(data) > steamCloudMaxFile {
		return errSteamCloud
	}
	files, err := a.files(ctx, token, steamID, appID)
	if err != nil {
		return err
	}
	var existing *steamCloudFile
	for i := range files {
		if files[i].Name == name {
			existing = &files[i]
			break
		}
	}
	if (existing == nil && (expected != "" || remove)) || (existing != nil && !strings.EqualFold(existing.SHA, expected)) {
		return errSteamCloudConflict
	}
	platforms := []string{"all"}
	if existing != nil && !remove {
		platforms, err = cloudPlatforms(existing.Platforms)
		if err != nil {
			return err
		}
	}
	uploads, deletes := []string{}, []string{}
	if remove {
		deletes = append(deletes, name)
	} else {
		uploads = append(uploads, name)
	}
	var batch struct {
		ID steamCloudNumber `json:"batch_id"`
	}
	if a.call(ctx, token, "BeginAppUploadBatch", map[string]any{"appid": appID, "machine_name": "PlezyNG", "files_to_upload": uploads, "files_to_delete": deletes}, &batch) != nil || batch.ID == 0 {
		return errSteamCloud
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
		defer cancel()
		result := 1
		if err != nil {
			result = 2
		}
		if a.call(cleanup, token, "CompleteAppUploadBatch", map[string]any{"appid": appID, "batch_id": batch.ID.String(), "batch_eresult": result}, nil) != nil {
			err = errSteamCloud
		}
	}()
	if remove {
		return a.call(ctx, token, "Delete", map[string]any{"appid": appID, "filename": name}, nil)
	}
	return a.put(ctx, token, appID, batch.ID, name, data, platforms)
}
