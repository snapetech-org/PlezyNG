# PlezyNG Steam Cloud host extension

This optional Decky plugin implements the account-wide Cloud setting through
Steam's own UI-side `SteamClient.Settings.SetSetting` and settings callbacks.
Host transport source is implemented for **Linux / SteamOS, Windows and macOS**. Any PlezyNG client
with Companion support can request a change on that paired host, including a
phone, desktop or TV. Host operation still requires a working, compatible Decky
installation on that OS; this change does not supply a Windows/macOS plugin loader.
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

1. Run Steam, the plugin backend and PlezyNG Companion as the same desktop user.
   On Linux, use `XDG_RUNTIME_DIR=/run/user/<uid>` pointing to that user's private
   runtime directory. macOS uses `/tmp/plezyng-steam-cloud-<uid>/` (mode 0700).
   Windows uses a local named pipe scoped to the desktop user's SID. No local
   firewall rule, secret file, administrator flag or network port is required.
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
  runtime directory on Linux, or a validated private UID directory on macOS.
  The socket is mode 0600 and checks `SO_PEERCRED` (Linux) or `getpeereid` (macOS).
  The macOS client also verifies the server's effective UID. Windows uses a
  protected same-SID DACL, `PIPE_REJECT_REMOTE_CLIENTS`, first-instance ownership,
  client token verification and client-side server process token verification.
  Identification-only client SQOS prevents delegation. Windows I/O is overlapped;
  cancellation completes before native buffers or handles are freed.
  These transports cap native connections at four and permit one active operation. There is no TCP listener. A stale
  socket is not silently replaced; after verifying the previous plugin is stopped,
  remove only the socket under that platform's directory before retrying installation.
  Windows refuses an existing pipe owner; named pipes disappear when all handles
  close. Never delete another process's endpoint to make installation succeed.
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

## Desktop build-agent transport gate

With the real plugin stopped, run from the repository root on **each** desktop OS:

```sh
python3 scripts/games/cloud_transport_probe.py --dart /path/to/dart
```

Use `python` on Windows and the installed Dart executable path. This launches the
actual Python IPC server and Dart client, verifies read, write/readback, stale
review, wrong account, malformed request, disabled consent and cancellation with
a simulated Steam observer. It does not change a Steam account. Existing sockets
are never replaced. Missing SDKs or unavailable native sockets fail the probe.
Run under the desktop user, and separately confirm a second OS user cannot
connect. Full app packaging and real Steam/Decky callback testing remain gates;
platform source and static analysis do not prove those builds or callbacks.

Native contracts: [Microsoft overlapped I/O cancellation](https://learn.microsoft.com/en-us/windows/win32/fileio/canceling-pending-i-o-operations),
[Apple getpeereid](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html),
and [Dart variadic FFI](https://api.dart.dev/dart-ffi/VarArgs-class.html).
The Darwin `fcntl` binding explicitly marks its variadic argument for Apple ARM64.
