import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/platform_detector.dart';
import 'dpad_navigator.dart';

/// Which event of a physical Back press performs the action.
///
/// Delivery model (Flutter 3.47.1, including API 36 device qualification):
///
/// * Android: `FlutterView.dispatchKeyEvent` claims every key and only
///   redispatches it to the Activity — where `onKeyUp(KEYCODE_BACK)` becomes
///   `onBackPressed` → `popRoute` — when the framework reports the event
///   **unhandled**. However, after IME use Android can also invoke system Back
///   between a handled KeyDown and its KeyUp. `InputModeTracker` consumes that
///   duplicate while the physical press is owned by a [BackPressGate].
/// * tvOS (custom engine): Menu arrives as an engine-synthesized `escape`
///   press. The KeyUp is not delivered reliably, so the action runs on KeyDown.
/// * Desktop: `escape` / `browserBack` are plain key presses. There is no
///   system back.
/// * Handheld gestures (iOS swipe, Android 13+) arrive only as `popRoute` and
///   never as key events.
///
/// A press can also act twice inside the framework: an action that runs on
/// KeyDown (Apple TV, a TV text field whose IME would swallow the KeyUp) moves
/// focus or pops a route, and the KeyUp reaches a *different* focus chain.
/// [BackPressGate] closes that by
/// only acting on a KeyUp whose KeyDown it saw itself.
enum BackPhase { keyDown, keyUp }

/// The phase on which a Back handler acts for [event], unless the owner has a
/// reason of its own (a TV text field under a native IME passes
/// [BackPhase.keyDown] explicitly).
BackPhase backPhaseFor(KeyEvent event) => PlatformDetector.isAppleTV() ? BackPhase.keyDown : BackPhase.keyUp;

/// Per-owner state for a Back key press: acts once per physical press, on the
/// configured phase, and never on a KeyUp whose KeyDown it did not see.
///
/// Owners are the widgets that consume Back *before* the route stack — a text
/// field dismissing its IME, a sheet closing a nested page, the player hiding
/// its content strip, a screen moving focus from content to the sidebar. Each
/// owner holds one gate; it costs two booleans. Everything that is not such an
/// owner lets the press bubble to [NavigatorBackHandler], which turns it into
/// `Navigator.maybePop` so the route's `PopScope` is the single place a screen
/// decides its back policy for both key and system back.
///
/// Results:
/// * KeyDown → `handled`, press armed; the action runs now when the phase is
///   [BackPhase.keyDown].
/// * KeyRepeat → `handled` while armed, otherwise `ignored`.
/// * KeyUp of an armed press → `handled`; the action runs now when the phase is
///   [BackPhase.keyUp].
/// * KeyUp without an armed press (the press started on another focus chain)
///   → `ignored`, so it bubbles to the navigator handler, which swallows it.
///   Returning `handled` here would be wrong for a press the owner declined.
/// * A KeyDown while still armed (the previous KeyUp was swallowed off-app,
///   e.g. by a closing TV IME) is a fresh press and re-arms.
class BackPressGate {
  static KeyDownEvent? _claimedPlatformBack;

  /// Observe every hardware Back event, including ones declined by focus.
  /// The hardware observer may run before or after focus dispatch: preserve a
  /// claim only when it belongs to this exact KeyDown, never an earlier press
  /// whose release was lost with an IME or disposed focus chain.
  static void observeHardwareEvent(KeyEvent event) {
    if (!event.logicalKey.isBackKey) return;
    if (event is KeyUpEvent || (event is KeyDownEvent && !identical(_claimedPlatformBack, event))) {
      _claimedPlatformBack = null;
    }
  }

  static bool get ownsHeldPlatformBack {
    final claimed = _claimedPlatformBack;
    return claimed != null && HardwareKeyboard.instance.physicalKeysPressed.contains(claimed.physicalKey);
  }

  static void clearPlatformClaim() => _claimedPlatformBack = null;

  bool _armed = false;
  bool _fired = false;

  /// Whether a press is in flight between its KeyDown and KeyUp.
  bool get isArmed => _armed;

  KeyEventResult handle(KeyEvent event, VoidCallback onBack, {BackPhase? phase}) {
    if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;
    final effectivePhase = phase ?? backPhaseFor(event);

    if (event is KeyDownEvent) {
      _claimedPlatformBack = event;
      _armed = true;
      _fired = effectivePhase == BackPhase.keyDown;
      if (_fired) onBack();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      return _armed ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      if (!_armed) return KeyEventResult.ignored;
      _armed = false;
      final fired = _fired;
      _fired = false;
      if (!fired) onBack();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Forget an in-flight press. Call when the owner leaves the focus chain
  /// mid-press and must not act on the eventual KeyUp.
  void reset() {
    _armed = false;
    _fired = false;
  }
}

/// Native/gesture Back follows the same innermost focused owner as key Back.
/// A single action dispatch avoids notifying every PopScope on the route,
/// which would close a submenu and its parent on the same press.
class SystemBackIntent extends Intent {
  const SystemBackIntent();

  static bool dispatch() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (!isCurrentRouteChain(context)) return false;
    return Actions.maybeInvoke(context, const SystemBackIntent()) == true;
  }
}

/// Include enclosing navigators: a root dialog can cover the active page of
/// the profile navigator without changing that nested page's isCurrent flag.
bool isCurrentRouteChain(BuildContext context) {
  var route = ModalRoute.of(context);
  while (route != null) {
    if (!route.isCurrent) return false;
    final navigatorContext = route.navigator?.context;
    if (navigatorContext == null) break;
    route = ModalRoute.of(navigatorContext);
  }
  return true;
}

class SystemBackHandler extends StatelessWidget {
  const SystemBackHandler({super.key, required this.onBack, required this.child});

  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      SystemBackIntent: CallbackAction<SystemBackIntent>(
        onInvoke: (_) {
          onBack();
          return true;
        },
      ),
    },
    child: child,
  );
}

/// A non-focusable [Focus] that consumes Back for its subtree with its own
/// [BackPressGate], for owners that are not already a `State` holding a gate:
/// a sheet sub-page returning to its parent, a screen region whose Back moves
/// focus rather than popping the route.
///
/// A route's own back policy does not belong here — put it in `PopScope`, where
/// [NavigatorBackHandler] delivers key back and the platform delivers system
/// back.
class BackKeyOwner extends StatefulWidget {
  const BackKeyOwner({super.key, required this.onBack, this.phase, required this.child});

  final VoidCallback onBack;

  /// Overrides [backPhaseFor] for this owner.
  final BackPhase? phase;

  final Widget child;

  @override
  State<BackKeyOwner> createState() => _BackKeyOwnerState();
}

class _BackKeyOwnerState extends State<BackKeyOwner> {
  final BackPressGate _gate = BackPressGate();

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    return _gate.handle(event, widget.onBack, phase: widget.phase);
  }

  @override
  Widget build(BuildContext context) {
    return SystemBackHandler(
      onBack: widget.onBack,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        debugLabel: 'BackKeyOwner',
        onKeyEvent: _handleKeyEvent,
        child: widget.child,
      ),
    );
  }
}
