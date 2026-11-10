import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/cast_playback_ownership.dart';

void main() {
  test('requires matching receiver acknowledgement before accepting status', () {
    final owner = CastPlaybackOwnership()..begin('one', () => true);
    expect(owner.owns('one', 1), isFalse);
    expect(owner.acknowledge('other', 1), isFalse);
    expect(owner.acknowledge('one', 0), isFalse);
    expect(owner.acknowledge('one', 1), isTrue);
    expect(owner.owns('one', 1), isTrue);
    expect(owner.owns(null, 1), isTrue);
    expect(owner.owns('other', 1), isFalse);
    expect(owner.owns('one', 2), isFalse);
    expect(owner.acknowledge('one', 2), isFalse);
  });

  test('profile and authentication revocation immediately deny old status', () {
    var authorized = true;
    final owner = CastPlaybackOwnership()..begin('one', () => authorized);
    expect(owner.acknowledge('one', 1), isTrue);
    authorized = false;
    expect(owner.authorized, isFalse);
    expect(owner.owns('one', 1), isFalse);
    expect(owner.acknowledge('one', 1), isFalse);
  });

  test('new load and disconnect cannot reuse a previous media session', () {
    final owner = CastPlaybackOwnership()..begin('one', () => true);
    owner.acknowledge('one', 1);
    final revision = owner.revision;
    owner.begin('two', () => true);
    expect(owner.revision, greaterThan(revision));
    expect(owner.acknowledge('one', 1), isFalse);
    expect(owner.owns('two', 1), isFalse);
    expect(owner.acknowledge('two', 2), isTrue);
    owner.clear();
    expect(owner.revision, greaterThan(revision + 1));
    expect(owner.authorized, isFalse);
    expect(owner.owns('two', 2), isFalse);
  });
}
