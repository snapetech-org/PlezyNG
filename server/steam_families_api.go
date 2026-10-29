package main

// Families is a Steam user-session service, not an OpenID or publisher-key
// privilege. Only tokens minted by an explicit QR approval enter this adapter.
import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

var errSteamFamily = errors.New("Steam Families unavailable")

type familyID string

func (id *familyID) UnmarshalJSON(b []byte) error {
	var n steamCloudNumber
	if err := json.Unmarshal(b, &n); err != nil {
		return errSteamFamily
	}
	*id = familyID(n.String())
	return nil
}
func familyIDValid(s string) bool {
	n, err := strconv.ParseUint(s, 10, 64)
	return err == nil && n != 0 && strconv.FormatUint(n, 10) == s
}
func familyName(s string) bool {
	if strings.TrimSpace(s) != s || s == "" || !utf8.ValidString(s) || utf8.RuneCountInString(s) > 64 {
		return false
	}
	for _, c := range s {
		if unicode.IsControl(c) {
			return false
		}
	}
	return true
}

type familyMember struct {
	SteamID familyID `json:"steamid"`
	Role    int      `json:"role"`
}
type familyInvite struct {
	FamilyID familyID `json:"family_groupid"`
	InviteID familyID `json:"invite_id"`
	Inviter  familyID `json:"inviter_steamid"`
	Role     int      `json:"role"`
	Awaiting bool     `json:"awaiting_2fa"`
}
type familyGroup struct {
	Name      string         `json:"name"`
	Members   []familyMember `json:"members"`
	Invites   []familyMember `json:"pending_invites"`
	FreeSpots uint32         `json:"free_spots"`
	Cooldown  uint32         `json:"slot_cooldown_remaining_seconds"`
}
type familySnapshot struct {
	FamilyID     familyID       `json:"family_groupid,omitempty"`
	NotMember    bool           `json:"is_not_member_of_any_group"`
	Role         int            `json:"role"`
	Cooldown     uint32         `json:"cooldown_seconds_remaining"`
	LastFamilyID familyID       `json:"latest_joined_family_groupid,omitempty"`
	CanUndelete  bool           `json:"can_undelete_last_joined_family"`
	Invites      []familyInvite `json:"pending_group_invites"`
	Group        familyGroup    `json:"family_group"`
}

func (s familySnapshot) digest() [32]byte {
	// Remaining seconds naturally tick while a review is open. Membership,
	// permissions, pending invitations and identity must still match exactly.
	s.Cooldown = 0
	s.Group.Cooldown = 0
	data, _ := json.Marshal(s)
	return sha256.Sum256(data)
}

type familyChange struct {
	Action   string `json:"action"`
	Name     string `json:"name,omitempty"`
	SteamID  string `json:"steamId,omitempty"`
	FamilyID string `json:"familyId,omitempty"`
	Role     int    `json:"role,omitempty"`
	AppID    uint32 `json:"appId,omitempty"`
}
type familyPlan struct {
	Method     string
	Parameters map[string]any
	Change     familyChange
}

func planFamilyChange(s familySnapshot, actor string, c familyChange) (familyPlan, error) {
	p := familyPlan{Change: c, Parameters: map[string]any{}}
	member := familyIDValid(string(s.FamilyID)) && !s.NotMember
	adult := member && s.Role == 1
	if member {
		p.Parameters["family_groupid"] = string(s.FamilyID)
	}
	find := func(entries []familyMember, id string) bool {
		for _, m := range entries {
			if string(m.SteamID) == id {
				return true
			}
		}
		return false
	}
	// A closed union prevents hidden/irrelevant fields from changing a review.
	allowed := familyChange{Action: c.Action}
	switch c.Action {
	case "create":
		if member || !s.NotMember || s.Cooldown != 0 || !familyName(c.Name) {
			return p, errSteamFamily
		}
		allowed.Name = c.Name
		p.Method = "CreateFamilyGroup"
		p.Parameters["name"] = c.Name
	case "rename":
		if !adult || !familyName(c.Name) {
			return p, errSteamFamily
		}
		allowed.Name = c.Name
		p.Method = "ModifyFamilyGroupDetails"
		p.Parameters["name"] = c.Name
	case "invite":
		if !adult || !validSteamID(c.SteamID) || c.SteamID == actor || (c.Role != 1 && c.Role != 2) || s.Group.FreeSpots == 0 || find(s.Group.Members, c.SteamID) || find(s.Group.Invites, c.SteamID) {
			return p, errSteamFamily
		}
		allowed.SteamID = c.SteamID
		allowed.Role = c.Role
		p.Method = "InviteToFamilyGroup"
		p.Parameters["receiver_steamid"] = c.SteamID
		p.Parameters["receiver_role"] = c.Role
	case "cancelInvite", "resendInvite":
		if !adult || !find(s.Group.Invites, c.SteamID) {
			return p, errSteamFamily
		}
		allowed.SteamID = c.SteamID
		if c.Action == "cancelInvite" {
			p.Method = "CancelFamilyGroupInvite"
			p.Parameters["steamid_to_cancel"] = c.SteamID
		} else {
			p.Method = "ResendInvitationToFamilyGroup"
			p.Parameters["steamid"] = c.SteamID
		}
	case "remove":
		if !adult || c.SteamID == actor || !find(s.Group.Members, c.SteamID) {
			return p, errSteamFamily
		}
		allowed.SteamID = c.SteamID
		p.Method = "RemoveFromFamilyGroup"
		p.Parameters["steamid_to_remove"] = c.SteamID
	case "leave":
		if !adult {
			return p, errSteamFamily
		}
		p.Method = "RemoveFromFamilyGroup"
		p.Parameters["steamid_to_remove"] = actor
	case "delete":
		if !adult || len(s.Group.Members) != 1 || len(s.Group.Invites) != 0 {
			return p, errSteamFamily
		}
		p.Method = "DeleteFamilyGroup"
	case "restore":
		if member || !s.NotMember || !s.CanUndelete || !familyIDValid(string(s.LastFamilyID)) {
			return p, errSteamFamily
		}
		p.Method = "UndeleteFamilyGroup"
		p.Parameters["family_groupid"] = string(s.LastFamilyID)
	case "join":
		found := false
		for _, invite := range s.Invites {
			if string(invite.FamilyID) == c.FamilyID && !invite.Awaiting {
				found = true
			}
		}
		if member || !s.NotMember || !found {
			return p, errSteamFamily
		}
		allowed.FamilyID = c.FamilyID
		p.Method = "JoinFamilyGroup"
		p.Parameters["family_groupid"] = c.FamilyID
	case "preferredLender":
		if !member || c.AppID == 0 || !find(s.Group.Members, c.SteamID) || c.SteamID == actor {
			return p, errSteamFamily
		}
		allowed.SteamID = c.SteamID
		allowed.AppID = c.AppID
		p.Method = "SetPreferredLender"
		p.Parameters["appid"] = c.AppID
		p.Parameters["lender_steamid"] = c.SteamID
	default:
		return p, errSteamFamily
	}
	if allowed != c {
		return p, errSteamFamily
	}
	return p, nil
}

type steamFamilyAPI struct{ client *http.Client }

func (a *steamFamilyAPI) call(ctx context.Context, token, service, method string, params any, read bool, output any) error {
	encoded, err := json.Marshal(params)
	if err != nil {
		return errSteamFamily
	}
	values := url.Values{"input_json": {string(encoded)}, "format": {"json"}}
	if token != "" {
		values.Set("access_token", token)
	}
	endpoint := "https://api.steampowered.com/I" + service + "Service/" + method + "/v1/"
	verb := http.MethodPost
	var body io.Reader = strings.NewReader(values.Encode())
	if read {
		verb = http.MethodGet
		endpoint += "?" + values.Encode()
		body = nil
	}
	req, err := http.NewRequestWithContext(ctx, verb, endpoint, body)
	if err != nil {
		return errSteamFamily
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "PlezyNG Steam Families")
	client := *a.client
	client.Timeout = 15 * time.Second
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(req)
	if err != nil {
		return errSteamFamily
	} // Never expose a credential-bearing URL.
	defer response.Body.Close()
	if response.StatusCode != 200 || response.Header.Get("x-eresult") != "1" {
		return errSteamFamily
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 128*1024+1))
	if err != nil || len(data) > 128*1024 {
		return errSteamFamily
	}
	var envelope struct {
		Response json.RawMessage `json:"response"`
	}
	if json.Unmarshal(data, &envelope) != nil || len(envelope.Response) == 0 || string(envelope.Response) == "null" {
		return errSteamFamily
	}
	if output != nil && json.Unmarshal(envelope.Response, output) != nil {
		return errSteamFamily
	}
	return nil
}
func (a *steamFamilyAPI) snapshot(ctx context.Context, token, actor string) (familySnapshot, error) {
	var s familySnapshot
	err := a.call(ctx, token, "FamilyGroups", "GetFamilyGroupForUser", map[string]any{"steamid": actor, "include_family_group_response": true}, true, &s)
	if err != nil {
		return s, err
	}
	if len(s.Group.Members) > 6 || len(s.Group.Invites) > 6 || len(s.Invites) > 32 || s.Group.FreeSpots > 6 {
		return s, errSteamFamily
	}
	member := familyIDValid(string(s.FamilyID))
	if member == s.NotMember || (member && !familyName(s.Group.Name)) {
		return s, errSteamFamily
	}
	found := false
	seen := map[familyID]bool{}
	for _, m := range s.Group.Members {
		if !validSteamID(string(m.SteamID)) || (m.Role != 1 && m.Role != 2) || seen[m.SteamID] {
			return s, errSteamFamily
		}
		seen[m.SteamID] = true
		if string(m.SteamID) == actor && m.Role == s.Role {
			found = true
		}
	}
	if member && !found {
		return s, errSteamFamily
	}
	for _, m := range s.Group.Invites {
		if !validSteamID(string(m.SteamID)) || (m.Role != 1 && m.Role != 2) || seen[m.SteamID] {
			return s, errSteamFamily
		}
		seen[m.SteamID] = true
	}
	for _, i := range s.Invites {
		if !familyIDValid(string(i.FamilyID)) || !familyIDValid(string(i.InviteID)) || !validSteamID(string(i.Inviter)) || (i.Role != 1 && i.Role != 2) {
			return s, errSteamFamily
		}
	}
	sort.Slice(s.Group.Members, func(i, j int) bool { return s.Group.Members[i].SteamID < s.Group.Members[j].SteamID })
	sort.Slice(s.Group.Invites, func(i, j int) bool { return s.Group.Invites[i].SteamID < s.Group.Invites[j].SteamID })
	sort.Slice(s.Invites, func(i, j int) bool { return s.Invites[i].InviteID < s.Invites[j].InviteID })
	return s, nil
}
func familyTokenSubject(token string, now time.Time) (string, bool) {
	// Never accepts user-supplied JWTs. Called only on the fixed Valve HTTPS
	// authentication response; the live authenticated family request follows.
	if len(token) > 16384 {
		return "", false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", false
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", false
	}
	var claims struct {
		Sub string   `json:"sub"`
		Exp int64    `json:"exp"`
		Aud []string `json:"aud"`
	}
	if json.Unmarshal(data, &claims) != nil || !validSteamID(claims.Sub) || claims.Exp <= now.Unix() {
		return "", false
	}
	for _, a := range claims.Aud {
		if a == "web" {
			return claims.Sub, true
		}
	}
	return "", false
}
func familyChallenge(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "s.team" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || len(raw) > 512 {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
	return len(parts) == 3 && parts[0] == "q" && familyIDValid(parts[1]) && familyIDValid(parts[2])
}
