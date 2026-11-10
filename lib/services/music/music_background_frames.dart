import 'dart:async';

import 'package:flutter/widgets.dart';

/// Lets the ordinary profile/bootstrap tree settle in a car-launched engine
/// without a visible Flutter surface. No alternate account bootstrap or player
/// is created. The existing auth, profile picker and PIN gates still run.
///
/// Only dirty widget builds request a warm-up frame; there is no polling timer
/// or synthetic resumed lifecycle. A visible phone continues using real vsync.
class MusicBackgroundFrames {
  MusicBackgroundFrames(this.binding, {VoidCallback? warmUp, bool Function()? active})
    : _warmUp = warmUp ?? binding.scheduleWarmUpFrame,
      _active = active ?? (() => true);
  static final Set<MusicBackgroundFrames> _controllers = {};
  static bool _carConnected = false;
  static bool get carConnected => _carConnected;
  static set carConnected(bool value) {
    if (_carConnected == value) return;
    _carConnected = value;
    // A phone can have already-dirty widgets before the car binds. Those
    // widgets do not schedule another build until the pending build runs.
    if (value) {
      for (final controller in _controllers) {
        controller._requestWarmUp();
      }
    }
  }

  final bool Function() _active;
  final WidgetsBinding binding;
  final VoidCallback _warmUp;
  VoidCallback? _previous;
  VoidCallback? _installed;
  bool _queued = false;

  void install() {
    if (_installed != null) return;
    final owner = binding.buildOwner;
    if (owner == null) return;
    _previous = owner.onBuildScheduled;
    _installed = () {
      _previous?.call();
      _requestWarmUp();
    };
    owner.onBuildScheduled = _installed;
    _controllers.add(this);
  }

  void _requestWarmUp() {
    if (_queued || !_active() || binding.lifecycleState == AppLifecycleState.resumed) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_installed != null && _active() && binding.lifecycleState != AppLifecycleState.resumed) _warmUp();
    });
  }

  void dispose() {
    _controllers.remove(this);
    final owner = binding.buildOwner;
    if (owner?.onBuildScheduled == _installed) owner?.onBuildScheduled = _previous;
    _installed = null;
  }
}
