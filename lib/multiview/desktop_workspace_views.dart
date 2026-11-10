import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native windows add views to the current engine. They receive presentation
/// metadata only; players, credentials and provider sessions never leave Dart.
class DesktopWorkspaceViews extends ChangeNotifier with WidgetsBindingObserver {
  DesktopWorkspaceViews({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.pleazyng/workspace_views') {
    _handlerOwner = this;
    _channel.setMethodCallHandler(_onNative);
    WidgetsBinding.instance.addObserver(this);
  }

  static DesktopWorkspaceViews? _handlerOwner;
  final MethodChannel _channel;
  final Map<String, _ViewLease> _leases = {};
  bool _disposed = false;
  bool? _available;

  bool get supportedPlatform =>
      !kIsWeb &&
      const {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

  ui.FlutterView? view(String id) => _leases[id]?.view;
  bool detached(String id) => view(id) != null;
  Iterable<String> get detachedIds =>
      _leases.entries.where((entry) => entry.value.view != null).map((entry) => entry.key);

  Future<bool> open(String id, {required String geometryKey, required String title}) async {
    if (_disposed || !supportedPlatform || _leases.containsKey(id) || _leases.length >= 8) {
      return false;
    }
    final random = Random.secure();
    final token = base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
    final cleanTitle = title.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    var opened = false;
    final lease = _ViewLease(token);
    _leases[id] = lease;
    bool current() => !_disposed && identical(_leases[id], lease);
    try {
      _available ??= await _channel.invokeMethod<bool>('available').timeout(const Duration(seconds: 3)) ?? false;
      if (!current() || !_available!) return false;
      final existingViewIds = WidgetsBinding.instance.platformDispatcher.views.map((view) => view.viewId).toSet();
      final result = await _channel
          .invokeMapMethod<String, Object?>('create', {
            'token': token,
            'geometryKey': geometryKey,
            'title': String.fromCharCodes(cleanTitle.runes.take(256)),
            'width': 900,
            'height': 640,
          })
          .timeout(const Duration(seconds: 5));
      final viewId = result?['viewId'];
      if (!current() || viewId is! int || viewId < 0 || existingViewIds.contains(viewId)) return false;
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (current() && DateTime.now().isBefore(deadline)) {
        final views = WidgetsBinding.instance.platformDispatcher.views.where((view) => view.viewId == viewId);
        if (views.isNotEmpty) {
          lease.view = views.single;
          notifyListeners();
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
          if (!current()) return false;
          await _channel.invokeMethod<void>('show', {'token': token}).timeout(const Duration(seconds: 3));
          opened = current();
          return opened;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return false;
    } on MissingPluginException {
      _available = false;
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      if (!opened) {
        if (identical(_leases[id], lease)) {
          await close(id);
        } else {
          await _closeNative(token);
        }
      }
    }
  }

  Future<bool> close(String id) async {
    final lease = _leases.remove(id);
    if (lease == null) return true;
    if (!_disposed) notifyListeners();
    if (lease.view != null) {
      // Unmount the View before its native renderer is destroyed.
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
    await _closeNative(lease.token);
    return true;
  }

  Future<void> _closeNative(String token) async {
    try {
      await _channel.invokeMethod<void>('close', {'token': token}).timeout(const Duration(seconds: 3));
    } on Object {
      // Native engine teardown also closes every child view.
    }
  }

  Future<void> _onNative(MethodCall call) async {
    if (_disposed || call.method != 'closeRequested' || call.arguments is! Map) {
      return;
    }
    final token = (call.arguments as Map)['token'];
    final ids = _leases.entries.where((entry) => entry.value.token == token).map((entry) => entry.key).toList();
    for (final id in ids) {
      await close(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_handlerOwner, this)) {
      _handlerOwner = null;
      _channel.setMethodCallHandler(null);
    }
    for (final id in _leases.keys.toList()) {
      unawaited(close(id));
    }
    super.dispose();
  }
}

class _ViewLease {
  _ViewLease(this.token);
  final String token;
  ui.FlutterView? view;
}
