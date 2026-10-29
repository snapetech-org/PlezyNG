package main

import (
	"crypto/sha256"
	"encoding/base64"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
)

func TestSteamSignInPageKeepsCredentialsAtValve(t *testing.T) {
	p := &oauthProxy{baseURL: "https://plezy.test", steamOpenIDEndpoint: steamOpenIDEndpoint}
	w := httptest.NewRecorder()
	p.handleSteamAuthorize(w, httptest.NewRequest(http.MethodGet, "/auth/steam", nil), &oauthSession{browserState: "one-use-state"})
	if w.Code != http.StatusOK {
		t.Fatal(w.Code)
	}
	body := w.Body.String()
	links := regexp.MustCompile(`href="([^"]+)"`).FindAllStringSubmatch(body, -1)
	if len(links) != 1 {
		t.Fatal("one explicit sign-in destination required")
	}
	target, err := url.Parse(html.UnescapeString(links[0][1]))
	if err != nil || target.Scheme != "https" || target.Host != "steamcommunity.com" || target.Path != "/openid/login" {
		t.Fatal("unsafe destination", target)
	}
	returned, err := url.Parse(target.Query().Get("openid.return_to"))
	if err != nil || returned.Query().Get("state") != "one-use-state" {
		t.Fatal("lost OpenID state")
	}
	if strings.Contains(body, "<form") || strings.Contains(body, "<script") || strings.Contains(body, "src=\"https:") || !strings.Contains(body, `alt="Sign in through Steam"`) {
		t.Fatal("unexpected credential form, script or remote image")
	}
	for key, part := range map[string]string{"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "frame-ancestors 'none'", "X-Frame-Options": "DENY"} {
		if !strings.Contains(w.Header().Get(key), part) {
			t.Fatal("missing security header", key)
		}
	}
	styles := regexp.MustCompile(`<style>(.*?)</style>`).FindStringSubmatch(body)
	if len(styles) != 2 {
		t.Fatal("expected one self-contained style block")
	}
	digest := sha256.Sum256([]byte(styles[1]))
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "'sha256-"+base64.StdEncoding.EncodeToString(digest[:])+"'") {
		t.Fatal("the browser would reject the page stylesheet")
	}
}

func TestSteamSignInRejectsInvalidDestinationAndMethod(t *testing.T) {
	p := &oauthProxy{baseURL: "https://plezy.test", steamOpenIDEndpoint: "https://evil.test/openid/login"}
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		w := httptest.NewRecorder()
		p.handleSteamAuthorize(w, httptest.NewRequest(method, "/auth/steam", nil), &oauthSession{browserState: "state"})
		if w.Code < 400 || strings.Contains(w.Body.String(), `href="https://evil.test`) {
			t.Fatal("invalid authorize request accepted")
		}
	}
}
