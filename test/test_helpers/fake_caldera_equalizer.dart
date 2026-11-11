import 'dart:async';
import 'package:plezy/services/music/caldera_mesh_equalizer.dart';

class FakeCalderaEqualizer implements CalderaEqualizerControls {
  @override
  PlayerParametricEqualizer calderaEqualizer = const PlayerParametricEqualizer();
  final writes = <PlayerParametricEqualizer>[];
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<void> setCalderaEqualizer(PlayerParametricEqualizer value, {required bool Function() current}) async {
    await gate?.future;
    if (!current() || fail) throw StateError('Native equalizer retired or rejected');
    calderaEqualizer = value.snapshot();
    writes.add(calderaEqualizer);
  }
}
