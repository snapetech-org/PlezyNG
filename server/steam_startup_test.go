package main

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func clearSteamStartupEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{"OAUTH_BASE_URL", "STEAM_STREAM_RELAY_ENABLED", "STEAM_STREAM_RELAY_UDP_PORT", "STEAM_STREAM_RELAY_MIB_PER_SECOND", "STEAM_FAMILIES_ENABLED", "STEAM_CLOUD_CLIENT_ID", "STEAM_CLOUD_READ_APPIDS", "STEAM_CLOUD_WRITE_APPIDS", "STEAM_CLOUD_STORAGE_HOSTS"} {
		t.Setenv(key, "")
	}
}

func TestSteamStartupDisabledRemainsCompatible(t *testing.T) {
	clearSteamStartupEnv(t)
	if err := validateSteamStartup(nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestSteamStartupRejectsIncompleteOptInsWithoutSecrets(t *testing.T) {
	for _, key := range []string{"STEAM_STREAM_RELAY_ENABLED", "STEAM_FAMILIES_ENABLED", "STEAM_CLOUD_CLIENT_ID", "STEAM_CLOUD_WRITE_APPIDS"} {
		t.Run(key, func(t *testing.T) {
			clearSteamStartupEnv(t)
			t.Setenv(key, "true")
			if err := validateSteamStartup(nil, nil); err == nil {
				t.Fatal("requested but unconfigured feature accepted")
			}
		})
	}
	clearSteamStartupEnv(t)
	t.Setenv("STEAM_FAMILIES_ENABLED", "sensitive-invalid-value")
	err := validateSteamStartup(nil, nil)
	if err == nil || strings.Contains(err.Error(), "sensitive-invalid-value") {
		t.Fatal("invalid flag accepted or value leaked")
	}
}

func TestSteamStartupConfiguredServices(t *testing.T) {
	clearSteamStartupEnv(t)
	t.Setenv("OAUTH_BASE_URL", "https://relay.example")
	t.Setenv("STEAM_STREAM_RELAY_ENABLED", "true")
	t.Setenv("STEAM_FAMILIES_ENABLED", "true")
	t.Setenv("STEAM_CLOUD_CLIENT_ID", "approved-client")
	t.Setenv("STEAM_CLOUD_READ_APPIDS", "10")
	t.Setenv("STEAM_CLOUD_WRITE_APPIDS", "10")
	t.Setenv("STEAM_CLOUD_STORAGE_HOSTS", "storage.example")
	resolver := newClientIPResolver(nil)
	oauth, _ := oauthConfigFromEnv(resolver)
	relay := registerSteamRelay(http.NewServeMux(), resolver, oauth)
	defer relay.close()
	if err := validateSteamStartup(oauth, relay); err != nil {
		t.Fatal(err)
	}
}

func TestSteamStartupOccupiedUDPPortCannotLookHealthy(t *testing.T) {
	clearSteamStartupEnv(t)
	occupied, err := net.ListenUDP("udp4", &net.UDPAddr{Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	t.Setenv("OAUTH_BASE_URL", "https://relay.example")
	t.Setenv("STEAM_STREAM_RELAY_ENABLED", "true")
	t.Setenv("STEAM_STREAM_RELAY_UDP_PORT", strconv.Itoa(occupied.LocalAddr().(*net.UDPAddr).Port))
	resolver := newClientIPResolver(nil)
	oauth, _ := oauthConfigFromEnv(resolver)
	relay := registerSteamRelay(http.NewServeMux(), resolver, oauth)
	defer relay.close()
	if err := validateSteamStartup(oauth, relay); err == nil {
		t.Fatal("occupied requested UDP port accepted")
	}
}
