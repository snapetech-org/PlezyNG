# Remote Back navigation

Back belongs to the innermost visible UI. During TV playback it returns from
an options subpage (including Audio Output) to options, closes options, hides
the paused OSD, then leaves the player. Each press performs one step. Explicit
Back can hide controls held for scrubbing/pointer interaction; automatic
hide retains those holds. A second press during the OSD fade can leave playback.
Phone Back retains its direct player-exit behavior.

`BackKeyOwner` owns both the physical key and a focused `SystemBackIntent`.
`InputModeTracker` dispatches native/gesture Back to the innermost action before
the navigator, retaining Android's held-key duplicate suppression. Do not add
independent nested `PopScope` handlers for sheet subpages: Flutter can notify
every vetoing scope on one Back. The sheet host handles pushed pages and closes
only after the internal page owner declines. Focus must land inside even
pointer-opened pages so neither key nor native Back skips the inner owner.
Use an autofocus Back-owner **scope**, leaving controls unfocused until the
viewer navigates or taps. Do not focus the first descendant on pointer entry:
it can open text inputs, mutate a resizing sheet during layout, and override
the filter editor's intended entry row. A scope also lets that row acquire
autofocus when the viewer starts a D-pad session. Filter selections stay staged
when Back returns to the parent editor and commit when the editor is dismissed.
Covered routes cannot consume Back through stale focus.

The native webOS runner claims `_WEBOS_ACCESS_POLICY_KEYS_BACK` before Dart
starts. Otherwise webOS intercepts the key and shows its exit dialog while
menus remain open. [Kodi's webOS shell](https://github.com/xbmc/xbmc/blob/master/xbmc/windowing/wayland/ShellSurfaceWebOSShell.cpp)
uses this same window property to receive Back. `MainScreen` updates the
`com.plezy/webos_system_navigation` channel to allow system passthrough only
at the home root with sidebar focus, no profile picker/sheet, and a current
route. The existing tvOS Menu bridge uses the same root policy. Keep updates
serialized so a delayed home acknowledgement cannot enable exit over playback.

Regression coverage lives in `back_press_test.dart`,
`navigator_back_handler_test.dart`, `video_settings_sheet_test.dart`,
`video_controls_test.dart`, `main_screen_layout_test.dart`, the component
geometry/library-filter/hub-detail tests, and the two TV
navigation-service tests. The settings tests exercise both native Back and
remote key presses against the actual sheet. The release's
`tools/webos/check_audio_plugin_syntax.sh` also compiles the runner against the
checksum-pinned LG ARM SDK before the expensive native build.

Device acceptance requires a fresh TV test window; do not switch inputs or
launch the app while someone is watching. Check submenu → options → OSD →
hidden OSD → browse, other-tab → home, and native exit only at home. Headless
tests and SDK compilation establish routing correctness; they do not claim a
physical remote/device qualification.

## Upstream sources

These authors made the linked contributions or suggestions to upstream Plezy.
Pleazyng independently adapted or reviewed the relevant behavior; the feature
status and limits above remain authoritative.

Related remote-input foundation: [D-pad hold-select/context-menu handling](https://github.com/edde746/plezy/commit/0ef47f2711ecb5ff30089831410b6f29b580cdcb)
by [@adamsparsons](https://github.com/adamsparsons), authored upstream and
independently adapted in Pleazyng. That commit concerns held Select and context
menus; the Back ownership and TV exit fixes described here are downstream work.

See the [full source ledger and dispositions](../../UPSTREAM_ATTRIBUTION.md).
