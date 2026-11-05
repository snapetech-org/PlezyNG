import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/remote_streams/remote_stream_models.dart';

void main() {
  const gib = 1024 * 1024 * 1024;
  test('old profiles migrate to the 64 GiB native cache policy', () {
    final snapshot = RemoteStreamSnapshot.decode('{"version":1,"nativePeerEnabled":true}');
    expect(snapshot.nativePeerEnabled, isTrue);
    expect(snapshot.nativeCacheQuotaBytes, 64 * gib);
  });
  test('native quota survives profile persistence and rejects unbounded inputs', () {
    final saved = const RemoteStreamSnapshot().copyWith(nativeCacheQuotaBytes: 128 * gib);
    expect(RemoteStreamSnapshot.decode(saved.encode()).nativeCacheQuotaBytes, 128 * gib);
    expect(RemoteStreamSnapshot.decode('{"version":1,"nativeCacheQuotaBytes":-1}').nativeCacheQuotaBytes, gib);
    expect(RemoteStreamSnapshot.decode('{"version":1,"nativeCacheQuotaBytes":999999999999999}').nativeCacheQuotaBytes, 1024 * gib);
  });
}
