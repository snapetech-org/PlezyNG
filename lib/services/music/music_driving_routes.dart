import 'package:flutter/foundation.dart';

import '../../utils/serial_future_queue.dart';
import 'music_library_store.dart';
import 'music_system_audio_routes.dart';

class MusicDrivingRoute {
  const MusicDrivingRoute({required this.platform, required this.id, required this.name});
  final String platform, id, name;
  String get key => '$platform:$id';
  Map<String, Object> toJson() => {'platform': platform, 'id': id, 'name': name};

  factory MusicDrivingRoute.fromJson(Object? value) {
    if (value is! Map ||
        !const {'ios', 'android'}.contains(value['platform']) ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        (value['id'] as String).length > 512 ||
        (value['id'] as String).contains('\u0000') ||
        value['name'] is! String ||
        (value['name'] as String).length > 256 ||
        (value['name'] as String).contains('\u0000')) {
      throw const FormatException('Invalid driving route');
    }
    return MusicDrivingRoute(
      platform: value['platform'] as String,
      id: value['id'] as String,
      name: value['name'] as String,
    );
  }
}

/// Explicitly selected Bluetooth outputs, owned by one profile's store. Merely
/// seeing a device or receiving a route event never adds an automatic trigger.
class MusicDrivingRoutes extends ChangeNotifier {
  MusicDrivingRoutes(this.store) {
    ready = _load();
  }
  static const maximum = 32;
  final MusicLibraryStore store;
  late final Future<void> ready;
  late final _writes = SerialFutureQueue();
  bool _disposed = false, _available = false, _loaded = false;
  bool get loaded => _loaded;
  Map<String, MusicDrivingRoute> _routes = {};
  bool get available => !_disposed && store.active && _available;
  List<MusicDrivingRoute> get routes => List.unmodifiable(_routes.values);
  bool contains(String platform, String id) => available && _routes.containsKey('$platform:$id');

  Future<void> _load() async {
    try {
      final value = await store.document('driving', 'bluetoothRoutes');
      final routes = <String, MusicDrivingRoute>{};
      if (value != null) {
        final rows = value['routes'];
        if (value['version'] != 1 || rows is! List || rows.length > maximum) {
          throw const FormatException('Invalid saved driving routes');
        }
        for (final row in rows) {
          final route = MusicDrivingRoute.fromJson(row);
          if (routes.containsKey(route.key)) throw const FormatException('Duplicate saved driving route');
          routes[route.key] = route;
        }
      }
      if (_disposed || !store.active) return;
      _routes = routes;
      _available = true;
    } catch (_) {
      // Unreadable or newer-version preferences cannot arm an automatic route.
      if (_disposed) return;
      _routes = {};
      _available = false;
    }
    _loaded = true;
    if (!_disposed) notifyListeners();
  }

  bool matches(String platform, MusicSystemAudioRoute route) =>
      available && route.outputs.any((output) => output.bluetooth && contains(platform, output.id));

  Future<void> select({
    required String platform,
    required MusicSystemAudioOutput output,
    required bool Function() current,
  }) {
    if (!output.bluetooth) throw ArgumentError('Only a selected Bluetooth output can arm driving entry');
    final route = MusicDrivingRoute.fromJson({'platform': platform, 'id': output.id, 'name': output.name});
    return _change(current, (next) {
      if (!next.containsKey(route.key) && next.length >= maximum) throw StateError('Driving route limit reached');
      next[route.key] = route;
    });
  }

  Future<void> remove({required MusicDrivingRoute route, required bool Function() current}) =>
      _change(current, (next) => next.remove(route.key));

  Future<void> reset({required bool Function() current}) => _change(current, (next) => next.clear(), recover: true);

  Future<void> _change(
    bool Function() current,
    void Function(Map<String, MusicDrivingRoute>) change, {
    bool recover = false,
  }) => _writes.run(() async {
    await ready;
    bool authorized() => !_disposed && store.active && current();
    if (!authorized() || (!recover && !_available)) throw StateError('Driving route owner unavailable');
    final next = Map.of(_routes);
    change(next);
    await store.saveDocument('driving', 'bluetoothRoutes', {
      'version': 1,
      'routes': [for (final route in next.values) route.toJson()],
    });
    if (!authorized()) return;
    _routes = next;
    _available = true;
    notifyListeners();
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
