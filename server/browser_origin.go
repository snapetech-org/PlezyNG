package main

import (
	"net/http"
	"net/url"
	"os"
	"strings"
)

const browserOriginsEnv = "PLEAZYNG_ALLOWED_BROWSER_ORIGINS"

const defaultBrowserOrigins = "https://pleazyng.app,https://www.pleazyng.app"

// browserOriginAllowed permits native clients that do not send Origin and
// browser clients from explicitly configured Pleazyng origins. An Origin
// header is a browser boundary, not an authentication credential.
func browserOriginAllowed(r *http.Request) bool {
	origins := r.Header.Values("Origin")
	if len(origins) == 0 {
		return true
	}
	if len(origins) != 1 {
		return false
	}

	rawAllowed := defaultBrowserOrigins
	if configured, ok := os.LookupEnv(browserOriginsEnv); ok {
		rawAllowed = configured
	}
	allowed := parseBrowserOrigins(rawAllowed)
	origin, ok := normalizeBrowserOrigin(origins[0])
	if !ok {
		return false
	}
	_, ok = allowed[origin]
	return ok
}

func rejectUntrustedBrowserOrigin(w http.ResponseWriter, r *http.Request) bool {
	if browserOriginAllowed(r) {
		return false
	}
	http.Error(w, "Origin not allowed", http.StatusForbidden)
	return true
}

func parseBrowserOrigins(raw string) map[string]struct{} {
	allowed := make(map[string]struct{})
	for _, item := range strings.Split(raw, ",") {
		if origin, ok := normalizeBrowserOrigin(strings.TrimSpace(item)); ok {
			allowed[origin] = struct{}{}
		}
	}
	return allowed
}

func normalizeBrowserOrigin(value string) (string, bool) {
	if value == "" || len(value) > 1024 || strings.TrimSpace(value) != value || strings.ContainsAny(value, ",\\\r\n\t ") {
		return "", false
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Opaque != "" || parsed.User != nil || parsed.Host == "" || parsed.Path != "" ||
		parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Hostname() == "" {
		return "", false
	}
	host := strings.ToLower(parsed.Hostname())
	localHost := host == "localhost" || host == "127.0.0.1" || host == "::1"
	if parsed.Scheme != "https" && !(parsed.Scheme == "http" && localHost) {
		return "", false
	}
	return strings.ToLower(parsed.Scheme) + "://" + strings.ToLower(parsed.Host), true
}
