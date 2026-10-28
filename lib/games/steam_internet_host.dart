import 'dart:async';

import '../services/companion_remote/remote_auth_context.dart';
import 'steam_internet_tunnel.dart';
import 'steam_tunnel_codec.dart';

/// Desktop host listeners follow the existing Companion server's profile and
/// pairing lifetime. Disabled permissions cause no network activity. Retries
/// are bounded in frequency and never resurrect a retired profile/pairing.
class SteamInternetHost {
  SteamInternetHost(List<RemoteAuthContext> contexts, this.allowed, this.admission) {
    final unique = <String, RemoteAuthContext>{};
    for (final context in contexts) {
      unique[SteamTunnelCodec.roomToken(context)] = context;
    }
    _contexts = unique.values.take(4).toList();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _maintain());
    _maintain();
  }
  final bool Function() allowed;
  final Future<String?> Function() admission;
  late final List<RemoteAuthContext> _contexts;
  late final Timer _timer;
  final _tunnels = <RemoteAuthContext, SteamInternetTunnel>{};
  final _pending = <RemoteAuthContext>{};
  final _retryAt = <RemoteAuthContext, DateTime>{};
  bool _closed = false;
  bool get current => !_closed && allowed();
  void _maintain() {
    if (!current) {
      for (final tunnel in _tunnels.values) {
        tunnel.close();
      }
      _tunnels.clear();
      return;
    }
    for (final context in _contexts) {
      if (_pending.contains(context) ||
          _tunnels.containsKey(context) ||
          DateTime.now().isBefore(_retryAt[context] ?? DateTime.fromMillisecondsSinceEpoch(0))) {
        continue;
      }
      _pending.add(context);
      unawaited(_listen(context));
    }
  }

  Future<void> _listen(RemoteAuthContext context) async {
    SteamInternetTunnel? tunnel;
    try {
      final grant = await admission();
      if (!current || grant == null) return;
      tunnel = await SteamInternetTunnel.connect(
        context,
        host: true,
        allowed: () => current,
        waitForPeer: false,
        admission: grant,
      );
      if (!current) {
        tunnel.close();
        return;
      }
      _tunnels[context] = tunnel;
      await tunnel.done;
    } catch (_) {
      // No token, room capability, account identity or endpoint in logs.
    } finally {
      tunnel?.close();
      tunnel?.path.dispose();
      _tunnels.remove(context);
      _pending.remove(context);
      _retryAt[context] = DateTime.now().add(const Duration(seconds: 15));
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    for (final tunnel in _tunnels.values) {
      tunnel.close();
    }
    _tunnels.clear();
  }
}
