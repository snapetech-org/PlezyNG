import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../games/game_models.dart';
import '../i18n/strings.g.dart';
import '../screens/games/game_stream_status.dart';

const moonlightGamePlatformViewType = 'com.plezy/games/moonlight_stream';

/// A GameStream connection owned by the workspace and presented by an Android
/// PlatformView. Pane focus and audio ownership are forwarded to the receiver.
class MoonlightGameWorkspaceSession {
  static MoonlightGameWorkspaceSession? _activeWorkspaceSession;

  MoonlightGameWorkspaceSession({
    required this.host,
    required this.game,
    required this.touchControls,
    this.onFirstConnection,
  }) : _sessionKey = _newSessionKey() {
    if (_activeWorkspaceSession != null) {
      throw StateError('Moonlight allows one live GameStream session at a time');
    }
    _activeWorkspaceSession = this;
  }

  static final Random _random = Random.secure();
  static int _nextViewGeneration = 0;
  static bool get hasActiveSession => _activeWorkspaceSession != null;

  final GameHost host;
  final StreamGame game;
  final bool touchControls;
  final VoidCallback? onFirstConnection;
  final ValueNotifier<String> sessionState = ValueNotifier('connecting');
  final GlobalKey _surfaceKey = GlobalKey();
  String _sessionKey;
  MethodChannel? _channel;
  bool _audioEnabled = false;
  bool _inputEnabled = false;
  bool _disposed = false;
  bool _reconnecting = false;
  bool _reportedFirstConnection = false;
  bool _nativeDisconnected = false;
  Future<void>? _retirementFuture;

  static String _newSessionKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final key = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '$key-0';
  }

  static String channelNameForViewId(int viewId) => 'com.plezy/games/moonlight_stream/$viewId';

  Map<String, Object?> get creationParams => {
    'sessionKey': _sessionKey,
    'hostId': host.id,
    'address': host.address,
    'port': host.port,
    'appId': game.id,
    'appName': game.name,
    'hostName': host.name,
    'hdr': game.hdr,
    'touchControls': touchControls,
    'audioEnabled': _audioEnabled,
    'connectingLabel': t.games.connecting,
    'failedLabel': t.games.streamConnectHelp,
    'inputUnavailableLabel': t.games.inputUnavailable,
  };

  void attachPlatformView(int viewId) {
    if (_disposed) {
      unawaited(MethodChannel(channelNameForViewId(viewId)).invokeMethod<void>('disconnect').catchError((_) {}));
      return;
    }
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel(channelNameForViewId(viewId));
    _channel = channel;
    _nativeDisconnected = false;
    channel.setMethodCallHandler((call) async {
      if (_disposed || _channel != channel) return null;
      if (call.method == 'sessionState' && call.arguments is String) {
        _stateChanged(call.arguments as String);
      }
      return null;
    });
    unawaited(_replayOwnership(channel));
    unawaited(
      channel
          .invokeMethod<String>('getSessionState')
          .then((state) {
            if (!_disposed && _channel == channel && state != null) _stateChanged(state);
          })
          .catchError((_) {}),
    );
  }

  Future<void> _replayOwnership(MethodChannel channel) async {
    try {
      await channel.invokeMethod<void>('setAudioEnabled', {'enabled': _audioEnabled});
      if (_disposed || _channel != channel) return;
      await channel.invokeMethod<void>('setInputEnabled', {'enabled': _inputEnabled});
    } catch (_) {
      // Native surface creation reports its state independently.
    }
  }

  void _stateChanged(String state) {
    if (_disposed) return;
    sessionState.value = state;
    if (state == 'playing' && !_reportedFirstConnection) {
      _reportedFirstConnection = true;
      onFirstConnection?.call();
    }
  }

  Future<void> setAudioEnabled(bool enabled) async {
    _audioEnabled = enabled;
    await _invoke('setAudioEnabled', {'enabled': enabled});
  }

  Future<void> setInputEnabled(bool enabled) async {
    _inputEnabled = enabled;
    await _invoke('setInputEnabled', {'enabled': enabled});
  }

  Future<void> resetInput() => _invoke('resetInput');

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    final channel = _channel;
    if (_disposed || channel == null) return;
    try {
      await channel.invokeMethod<void>(method, arguments).timeout(const Duration(seconds: 4));
    } catch (_) {
      // A disposed PlatformView can race a workspace focus update.
    }
  }

  Future<void> reconnect() async {
    if (_disposed || _reconnecting) return;
    _reconnecting = true;
    sessionState.value = 'reconnecting';
    final old = _channel;
    if (old != null && !_nativeDisconnected) {
      try {
        await old.invokeMethod<void>('disconnect').timeout(const Duration(seconds: 14));
      } catch (error) {
        // The native factory removes its channel after a completed teardown.
        // A missing handler therefore means the old receiver is already gone.
        if (_isMissingChannelError(error)) {
          _nativeDisconnected = true;
        } else {
          if (!_disposed) sessionState.value = 'failed';
          _reconnecting = false;
          return;
        }
      }
      if (!_nativeDisconnected) _nativeDisconnected = true;
    }
    if (_disposed) {
      _reconnecting = false;
      return;
    }
    old?.setMethodCallHandler(null);
    if (_channel == old) _channel = null;
    _sessionKey = _newSessionKey();
    _revision.value = ++_nextViewGeneration;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!_disposed) sessionState.value = 'connecting';
    _reconnecting = false;
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    sessionState.value = 'disconnecting';
    final channel = _channel;
    if (channel == null) {
      if (!_disposed) sessionState.value = 'disconnected';
      return;
    }
    try {
      await channel.invokeMethod<void>('disconnect').timeout(const Duration(seconds: 14));
      _nativeDisconnected = true;
      if (!_disposed) sessionState.value = 'disconnected';
    } catch (_) {
      if (!_disposed) sessionState.value = 'failed';
    }
  }

  bool _isMissingChannelError(Object error) => error is MissingPluginException;

  final ValueNotifier<int> _revision = ValueNotifier(0);

  Widget workspaceSurface() => _MoonlightGameSurface(key: _surfaceKey, session: this);

  Future<void> retire() => _retirementFuture ??= _retireNativeSession();

  Future<void> _retireNativeSession() async {
    if (_disposed) return;
    _disposed = true;
    final channel = _channel;
    _channel = null;
    channel?.setMethodCallHandler(null);
    sessionState.dispose();
    _revision.dispose();
    if (channel == null || _nativeDisconnected) {
      _releaseSessionSlot();
      return;
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await channel.invokeMethod<void>('disconnect').timeout(const Duration(seconds: 14));
        _nativeDisconnected = true;
        break;
      } on MissingPluginException {
        _nativeDisconnected = true;
        break;
      } on PlatformException catch (error) {
        if (error.code != 'STREAM_STOP_PENDING') break;
      } on TimeoutException {
        // Native teardown uses a bounded wait too; retry its idempotent close.
      } catch (_) {
        break;
      }
      if (attempt < 3) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (_nativeDisconnected) _releaseSessionSlot();
  }

  void _releaseSessionSlot() {
    if (identical(_activeWorkspaceSession, this)) _activeWorkspaceSession = null;
  }

  void dispose() {
    unawaited(retire());
  }
}

class _MoonlightGameSurface extends StatefulWidget {
  const _MoonlightGameSurface({super.key, required this.session});
  final MoonlightGameWorkspaceSession session;

  @override
  State<_MoonlightGameSurface> createState() => _MoonlightGameSurfaceState();
}

class _MoonlightGameSurfaceState extends State<_MoonlightGameSurface> {
  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<int>(
          valueListenable: session._revision,
          builder: (_, generation, _) => AndroidView(
            key: ValueKey(generation),
            viewType: moonlightGamePlatformViewType,
            creationParams: session.creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: session.attachPlatformView,
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: session.sessionState,
          builder: (context, state, _) => state == 'playing'
              ? const SizedBox.shrink()
              : GameStreamStatus(
                  state: state,
                  gameName: session.game.name,
                  computerName: session.host.name,
                  showSteamBadge: false,
                  onReconnect: () => unawaited(session.reconnect()),
                  onDisconnect: () => unawaited(session.disconnect()),
                ),
        ),
      ],
    );
  }
}
