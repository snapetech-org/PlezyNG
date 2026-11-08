import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/artwork_failure_cache.dart';

void main() {
  test('transient failures expire instead of persisting for the app lifetime', () {
    var now = DateTime.utc(2026);
    final cache = ArtworkFailureCache(now: () => now);
    cache.remember('https://a.example/image/42');
    expect(cache.contains('https://a.example/image/42'), isTrue);
    expect(cache.contains('https://b.example/image/42'), isFalse);
    now = now.add(const Duration(minutes: 2));
    expect(cache.contains('https://a.example/image/42'), isFalse);
  });

  test('failure memory stays bounded and refreshes recently failed URLs', () {
    final cache = ArtworkFailureCache(maxEntries: 2);
    cache.remember('a');
    cache.remember('b');
    cache.remember('a');
    cache.remember('c');
    expect(cache.contains('a'), isTrue);
    expect(cache.contains('b'), isFalse);
    expect(cache.contains('c'), isTrue);
    cache.remember(null);
    cache.remember('');
    expect(cache.contains(null), isFalse);
    expect(cache.contains(''), isFalse);
  });
}
