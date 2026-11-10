import 'dart:async';

import '../../models/companion_remote/remote_command.dart';
import '../companion_remote/companion_remote_peer_service.dart';
import 'music_connect_channel.dart';
import 'music_device_endpoint.dart';
import 'music_device_link.dart';

/// A music link shares the established pairing and encryption protocol. An
/// outbound link is independent of the app's general remote-control session,
/// so preparing another device does not tear down the currently playing one.
class MusicDevicePeer {
  MusicDevicePeer({
    required this.transport,
    required this.endpoint,
    required this.current,
    required this.ownsTransport,
    required this.changed,
    String? name,
    bool negotiated = false,
  }) {
    channel = MusicConnectChannel(
      send: (message) => transport.sendCommand(RemoteCommand(type: RemoteCommandType.musicConnect, data: message)),
      handle: endpoint.handle,
      allowed: () => !_closed && current() && transport.isConnected,
    );
    output = MusicDeviceLink(
      name: name ?? 'Pleazyng',
      request: channel.request,
      isConnected: () => !_closed && current() && transport.isConnected && _negotiated,
    );
    _negotiated = negotiated;
    if (negotiated) _ready.complete(true);
    _subscriptions.add(
      transport.onCommandReceived.listen((command) {
        if (_closed || !current()) return;
        if (command.type == RemoteCommandType.musicConnect && _negotiated) {
          channel.receive(command.data);
        } else if (command.type == RemoteCommandType.deviceInfo && !_ready.isCompleted) {
          _negotiated = command.data?['musicConnectVersion'] == 1;
          _ready.complete(_negotiated);
        }
      }),
    );
    _subscriptions.add(
      transport.onDeviceDisconnected.listen((_) {
        channel.close();
        if (!_ready.isCompleted) _ready.complete(false);
        output.connectionChanged();
        changed();
      }),
    );
    _subscriptions.add(
      transport.onError.listen((_) {
        if (!_ready.isCompleted) _ready.complete(false);
        output.connectionChanged();
        changed();
      }),
    );
  }

  final CompanionRemotePeerService transport;
  final MusicDeviceEndpoint endpoint;
  final bool Function() current;
  final bool ownsTransport;
  final void Function() changed;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _ready = Completer<bool>();
  late final MusicConnectChannel channel;
  late final MusicDeviceLink output;
  bool _negotiated = false;
  bool _closed = false;

  Future<bool> ready() => _ready.future.timeout(const Duration(seconds: 5), onTimeout: () => false);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.complete(false);
    channel.close();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    output.dispose();
    if (ownsTransport) await transport.dispose();
  }
}
