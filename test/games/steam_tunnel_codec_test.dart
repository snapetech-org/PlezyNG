import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/steam_tunnel_codec.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';

RemoteAuthContext identity({
  int secret = 7,
  bool paired = true,
  String user = 'member',
  List<String> allowed = const ['member'],
}) => RemoteAuthContext(
  id: 'test',
  backend: 'plex',
  connectionId: 'profile',
  homeSecret: List.filled(32, secret),
  discoveryKey: const [],
  clientIdentifier: 'client',
  userUuid: user,
  allowedUserUuids: allowed,
  isPaired: paired,
);
Future<(SteamTunnelCodec, SteamTunnelCodec)> pair() async {
  final a = await SteamTunnelCodec.create(identity(), host: true),
      b = await SteamTunnelCodec.create(identity(), host: false);
  await a.acceptHello(b.hello);
  await b.acceptHello(a.hello);
  return (a, b);
}

void main() {
  test('pairing, member authorization and role reflection are mandatory', () async {
    expect(() => SteamTunnelCodec.roomToken(identity(paired: false)), throwsFormatException);
    final host = await SteamTunnelCodec.create(identity(), host: true);
    final wrong = await SteamTunnelCodec.create(identity(secret: 8), host: false);
    final revoked = await SteamTunnelCodec.create(identity(user: 'revoked'), host: false);
    await expectLater(host.acceptHello(host.hello), throwsFormatException);
    await expectLater(host.acceptHello(wrong.hello), throwsFormatException);
    await expectLater(host.acceptHello(revoked.hello), throwsFormatException);
    host.close();
    wrong.close();
    revoked.close();
  });
  test('directional keys, authenticated payloads, reordering and replay window', () async {
    final (a, b) = await pair();
    final first = await a.seal(1, [3, 0, 1, 42]), second = await a.seal(1, [4, 0, 1, 43]);
    final damaged = Uint8List.fromList(second)..[12] ^= 1;
    expect(await b.open(damaged), isNull);
    expect((await b.open(second))!.payload, [4, 0, 1, 43]);
    expect((await b.open(first))!.payload, [3, 0, 1, 42]);
    expect(await b.open(first), isNull);
    expect(await a.open(first), isNull);
    final reply = await b.seal(0, []);
    expect((await a.open(reply))!.kind, 0);
    // A new DH handshake cannot decrypt old-session ciphertext.
    final (c, d) = await pair();
    expect(await d.open(first), isNull);
    a.close();
    b.close();
    c.close();
    d.close();
  });
  test('old packets expire, invalid tags do not advance counters, closed keys cannot send', () async {
    final (a, b) = await pair();
    final old = await a.seal(0, []);
    for (var i = 0; i < 2049; i++) {
      await b.open(await a.seal(0, []));
    }
    expect(await b.open(old), isNull);
    final next = await a.seal(1, [5, 0, 1, 1]);
    final forged = Uint8List.fromList(next);
    ByteData.sublistView(forged).setUint64(2, 0x1fffffffffffff);
    expect(await b.open(forged), isNull);
    expect(await b.open(next), isNotNull);
    a.close();
    await expectLater(a.seal(0, []), throwsFormatException);
    b.close();
  });
}
