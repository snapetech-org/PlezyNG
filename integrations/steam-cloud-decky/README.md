# PlezyNG Steam Cloud host extension

This optional Decky plugin implements the account-wide Cloud setting through
Steam's own UI-side `SteamClient.Settings.SetSetting` and settings callbacks.
The implemented host transport is **Linux / SteamOS only**. Any PlezyNG client
with Companion support can request a change on that paired host, including a
phone, desktop or TV. Windows/macOS host transports are not implemented here.
This is a community client interface, not a Valve-supported OAuth/Web API.

## Build and install

Use Node 20+ and Python 3.10+ on the build agent:

```sh
npm ci --ignore-scripts
npm test
npm run build
npx tsc --noEmit
python3 -m unittest discover -p 'test_*.py'
python3 package.py --output build/plezyng-steam-cloud.zip
```

Install the archive using Decky's explicit local-plugin installation flow on the
chosen gaming computer. The package requests **no root flag**. It must run as the
Steam desktop user; the backend refuses privileged execution on another user's
behalf. No CEF debugging setting is changed. This extension relies on an existing
working Decky installation; PlezyNG does not install or modify Steam or Decky.

1. Run Steam and PlezyNG Companion as the same desktop user, with
   `XDG_RUNTIME_DIR=/run/user/<uid>` pointing to that user's private runtime directory.
2. In the host PlezyNG profile's Games settings, enable host actions and the
   separate **Allow Steam Cloud settings changes** permission.
3. In Decky, explicitly enable **Allow Cloud settings changes**. It resets off
   on backend or frontend reload. Reloading or disabling the plugin retires access.
4. Pair Companion and import this computer's inventory in PlezyNG. Link the same
   Steam account on the receiving client. Open that computer's game-route menu,
   select **Steam Cloud on computer**, review the observed state, then confirm
   enable or disable. Missing permission, account mismatch, absent bridge or
   unknown settings leave the mutation unavailable.

A disabled or uninstalled bridge changes none of the ordinary library, streaming,
Cloud-file or existing host settings behavior. Hosts without the new Companion
capability do not show the action. This plugin's own small consent panel currently
uses English; the PlezyNG action, review, errors and permission use app localization
with tracked English fallback in all 37 locales.

## Narrow contract

- Companion carries only a version, one-use request ID, expected SteamID, operation,
  and (for writes) expected/desired booleans. No URL, executable, path, script or
  account token is accepted. The host binds work to the current paired connection
  and profile. Disabling permission or retiring the peer closes the local request.
- The backend exposes only a fixed Unix socket inside the user-owned mode-0700
  runtime directory. The socket is mode 0600, checks `SO_PEERCRED`, caps clients
  at four and permits one active operation. There is no TCP listener. A stale
  socket is not silently replaced; after verifying the previous plugin is stopped,
  remove only `/run/user/<uid>/plezyng-steam-cloud.sock` before retrying installation.
- Backend requests are bounded to 2 KiB, seven seconds and one claim. Claims
  expire, cannot be replayed and are retired on disconnect. Frontend sessions and
  monotonically increasing consent revisions reject stale consent/response work.
- The Steam context requires the exact account, an explicitly observed boolean,
  the reviewed prior state and current consent. It serializes only protobuf field
  10000. Setter acceptance alone is insufficient: a subsequent settings callback
  must expose the requested boolean for the same identity generation. Missing
  protobuf fields remain unknown. The observed-state check is not an atomic CAS
  against Steam's own UI or another extension.
- A timeout is an unknown outcome. Neither client nor bridge retries, rolls back,
  edits VDF files or claims propagation to other signed-in computers. Cancelling
  cannot undo a setter already issued to Steam. Same-OS-user applications are
  inside the local trust boundary, just as the Steam client and plugin are.

## Source provenance and qualification

The contract references and exact upstream revisions are in
[`STEAM_CLOUD.md`](../../docs/games/STEAM_CLOUD.md). Decky's official plugin template
provides the `@decky/api` event/callable and `@decky/ui` integration pattern; npm
versions and transitive integrity hashes are locked in package-lock.json.

Automated tests use simulated Steam callbacks. The actual plugin bundle builds
and typechecks. These do not establish a live Valve contract. Before use, test
on an identified Steam/Decky build with a disposable account: both directions,
setter rejection, missing field, account switch/logout, lost reply, permission
revocation, plugin reload, Steam restart persistence and a second computer.
Verify unchanged unrelated settings and save files. Report observed per-host
state separately from account-setting propagation. A backend socket test skipped
because the execution environment denies Unix sockets is not a passing test.
