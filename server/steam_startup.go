package main

import (
	"errors"
	"os"
	"strings"
)

// Explicit opt-ins must not produce a healthy process with missing routes.
// Return fixed diagnostics: config values can contain credentials or tokens.
func validateSteamStartup(oauth *oauthProxy, relay *steamRelay) error {
	for _, key := range []string{"STEAM_STREAM_RELAY_ENABLED", "STEAM_FAMILIES_ENABLED"} {
		value := os.Getenv(key)
		if value != "" && value != "true" && value != "false" {
			return errors.New(key + " must be true or false")
		}
	}
	if os.Getenv("STEAM_STREAM_RELAY_ENABLED") == "true" && relay == nil {
		return errors.New("Steam relay requested but unavailable: check HTTPS origin, bandwidth, UDP port and port availability")
	}
	if os.Getenv("STEAM_FAMILIES_ENABLED") == "true" && (oauth == nil || oauth.steamFamilies == nil) {
		return errors.New("Steam Families requested but unavailable: check HTTPS origin")
	}
	cloudRequested := false
	for _, key := range []string{"STEAM_CLOUD_CLIENT_ID", "STEAM_CLOUD_READ_APPIDS", "STEAM_CLOUD_WRITE_APPIDS", "STEAM_CLOUD_STORAGE_HOSTS"} {
		cloudRequested = cloudRequested || strings.TrimSpace(os.Getenv(key)) != ""
	}
	if cloudRequested && (oauth == nil || oauth.steamCloud == nil) {
		return errors.New("Steam Cloud requested but unavailable: check client ID, HTTPS origin, AppID grants and storage hosts")
	}
	return nil
}
