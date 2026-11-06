import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/podcast_automation.dart';

void main() {
  test('existing subscriptions refresh without silently enabling downloads or alerts', () {
    final rules = PodcastPolicy.fromJson({});
    expect(rules.keepLatest, 0);
    expect(rules.notify, isFalse);
    expect(rules.wifiOnly, isTrue);
    expect(rules.removeFinishedDays, 0);
  });
  test('stored per-show rules round trip and stay bounded', () {
    final rules = PodcastPolicy.fromJson({
      'keepLatest': 99999,
      'removeFinishedDays': -1,
      'notify': true,
      'wifiOnly': false,
    });
    final restored = PodcastPolicy.fromJson(rules.toJson());
    expect(restored.keepLatest, 50);
    expect(restored.removeFinishedDays, 0);
    expect(restored.notify, isTrue);
    expect(restored.wifiOnly, isFalse);
  });
}
