# Steam Families management

PR #81 adds Families management to the existing Steam activity panel. The same
dialog is used on desktop, mobile and TV, with the app's theme, rounded icons,
adaptive menus, focus controls and QR authorization shell. Older or disabled
servers retain the confirmed Steam Families destination. This is optional
source integration with local regression coverage, not a qualified live Valve
service or an assertion of Valve approval.

## Authority and supported actions

Steam OpenID/catalog identity does **not** authorize Families changes. The user
must explicitly start a separate QR sign-in, then approve the displayed request
in their Steam mobile app. The dialog explains that this creates a broader
Steam account session. Only the same SteamID as the linked catalog account is
accepted. No Steam password, existing cookie, publisher key or token supplied
by the app is accepted as Families authority.

The server uses `IAuthenticationService` and a closed allowlist of user-level
`IFamilyGroupsService` methods on `https://api.steampowered.com`. These are Steam
client interfaces observed in the published protocol sources, not a documented
general third-party Steamworks API guarantee. They can change or reject this
client. A successful local mock is not evidence that Valve accepts the flow.

| Action | Preconditions checked again at confirmation |
| --- | --- |
| Create a family | No current family; no reported membership cooldown |
| Rename | Current adult member |
| Invite an adult or child | Adult, free slot, valid distinct SteamID, no duplicate member/invitation |
| Cancel or resend an invitation | Adult, invitation still present |
| Remove a member | Adult, target still present and not the acting account |
| Leave | Adult member; Valve applies its cooldown and household rules |
| Delete | Adult and sole member, with no pending invitations |
| Restore | No current family; Valve explicitly reports the previous family restorable |
| Join | An invitation for the acting account is still present and not awaiting Steam confirmation |
| Prefer another member's copy of this game | Current member, distinct current family member, nonzero AppID; Valve decides actual ownership/eligibility |

The app displays IDs exactly as strings, including uint64 family IDs. It never
rounds them through floating point. Adult/child roles are displayed explicitly;
the UI does not infer adulthood from the account's age or local profile.

Each action first fetches current state and creates a server-held, single-use
review valid for 60 seconds. Confirmation requires an explicit acknowledgement
and consumes that review **before** any mutation request. The server rereads
membership, roles, invitations and family identity, validates the action again,
and rejects a changed snapshot. Remaining cooldown seconds may naturally tick;
permissions and eligibility are still re-evaluated. Valve does not provide a
transactional compare-and-swap here: an external change can race the final
request and Valve remains the final authority.

An uncertain response never triggers an automatic retry. Refresh and review
again. Steam two-factor confirmation remains in Steam; the app does not collect
or bypass codes. It does not expose purchase approval/payment, parental-control
mutation, support-only rollback, forced invitation acceptance, cooldown
overrides or household restrictions. Cloud files use the separate scoped OAuth
flow in [STEAM_CLOUD.md](STEAM_CLOUD.md); Families authorization is not reused
to grant Cloud access or enable global Cloud synchronization.

## Credential and lifecycle boundaries

- Valve access/refresh tokens live only in server memory, for at most ten
  minutes after QR approval. The app holds a random opaque Plezy capability in
  memory. Neither is persisted to preferences, a URL or application logs.
- Pending QR sessions expire after three minutes and poll at most once per
  five seconds. QR URLs must be exactly an HTTPS `s.team/q/<id>/<id>` path with
  no query, fragment, user-info or alternate origin.
- The server binds each capability to the precise catalog grant and SteamID,
  admits one session per Steam account, caps sessions at 64 and active requests
  at eight, and applies existing request rate limits. Operations, payload size,
  response size and time are bounded. Unknown mutation fields are rejected.
- Closing the dialog, changing/removing a profile, unlinking Steam, expiry or
  graceful server shutdown removes local authority and cancels in-flight
  requests. Steam refresh-token revocation is best effort with a ten-second
  network bound; shutdown waits up to three seconds. A force-killed process or
  unreachable Valve endpoint cannot guarantee immediate upstream revocation.
  Steam's authorized-device controls remain available to the account holder.
- All upstream methods and origins are fixed in code. Redirects are rejected.
  Writes put credentials in POST bodies; read-only Steam requests require the
  token in the upstream HTTPS query, which must be excluded from proxy/APM logs.
  HTTP 200 alone is insufficient: `x-eresult: 1` is required. Errors returned to
  the app contain no upstream URL, body, token or other account's data.

These sessions have broader upstream authority than the allowlisted UI. Use
only a trusted, controlled server. QR consent does not make an untrusted relay
operator safe; the server could see the temporary Steam credentials. Do not
enable the feature merely because the public catalog works.

## Operator configuration

The feature defaults off. On the existing single-process HTTPS catalog server,
set `STEAM_FAMILIES_ENABLED=true` only after reviewing this trust model and
qualifying the flow with authorized test accounts. See
[steam-families.env.example](../../server/steam-families.env.example).
`docker-compose.yml` passes the switch through. Restarting the process clears
catalog grants and requires relinking; do not restart a production service as
a test shortcut. No publisher API key or Cloud client ID enables Families.

The app calls only `POST /auth/steam/families`, authenticated with its catalog
bearer. Operations are `capabilities`, `start`, `poll`, `state`, `review`,
`commit` and `close`. A disabled server advertises `available: false`; older
404/501 servers fall back to the existing Steam destination.

## Validation and live qualification

Automated cases cover policy restrictions, wrong-account authorization,
cross-profile capabilities, exact identifiers, malicious QR URLs, redirect
rejection, Steam failure codes, stale/expired/replayed reviews, upstream token
privacy, cancellation/revocation and one-session admission. Flutter cases cover
older servers, bounded replies, reviewed-target integrity, no retry after an
ambiguous mutation, explicit acknowledgement and profile retirement. The
review flow also runs in a 320-pixel-wide, 2x-text, RTL viewport.

Before enabling a real deployment:

1. Build the exact PR head and verify disabled/older-server behavior first.
2. Approve only a QR request just started in the app, using the displayed
   SteamID. Test a wrong account, denial, expiry and close during approval.
3. With account owners' consent, exercise each enabled action on test families;
   verify the resulting state independently in Steam. Membership changes can
   start real cooldowns; do not use production household membership casually.
4. Change state in Steam while a review is open. Test child restrictions,
   full families, ineligible shared copies and confirmations required by Steam.
5. Interrupt the network during commit. Verify no repeated write, refresh the
   actual state, and require a new review for any further attempt.
6. Close/unlink/change profile during all phases. Check Steam device/session
   controls and sanitized server logs. Test screen readers, D-pad/keyboard,
   large text and the pending-QR layout on physical TV/mobile devices.

The 29 new messages have explicit English fallback entries in the other 36
locales; translation review is still required. Live Steam service acceptance,
account outcomes, platform SDK builds and physical accessibility are not
established by these local tests.

Protocol references inspected for this implementation:

- [Valve Web API service encoding](https://partner.steamgames.com/doc/webapi_overview)
- [Steam Families rules](https://help.steampowered.com/en/faqs/view/054C-3167-DD7F-49D4)
- [Steam client Families protocol](https://github.com/SteamTracking/Protobufs/blob/master/webui/service_familygroups.proto)
- [Steam client authentication protocol](https://github.com/SteamTracking/Protobufs/blob/master/webui/service_authentication.proto)
- [SteamKit authentication implementation](https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Steam/Authentication/SteamAuthentication.cs)
- [Steam session Web API transport](https://github.com/DoctorMcKay/node-steam-session/blob/master/src/transports/WebApiTransport.ts)
