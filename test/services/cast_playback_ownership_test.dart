import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/cast_playback_ownership.dart';

void main() {
  test('dispatches load before waiting and catches synchronous acknowledgement', () async {
    final statuses = StreamController<String>.broadcast(sync: true);
    var loaded = false;
    await loadAcknowledgedCastMedia(
      statuses: statuses.stream,
      acknowledge: (status) => status == 'owned',
      load: () async {
        loaded = true;
        statuses.add('foreign');
        statuses.add('owned');
      },
    );
    expect(loaded, isTrue);
    expect(statuses.hasListener, isFalse);
    await statuses.close();
  });

  test('load failures cancel the acknowledgement listener immediately', () async {
    final statuses = StreamController<String>.broadcast();
    await expectLater(
      loadAcknowledgedCastMedia(
        statuses: statuses.stream,
        acknowledge: (_) => true,
        load: () async => throw StateError('load failed'),
      ),
      throwsStateError,
    );
    expect(statuses.hasListener, isFalse);
    await statuses.close();
  });

  test('foreign status cannot acknowledge a timed-out load', () async {
    final statuses = StreamController<String>.broadcast(sync: true);
    await expectLater(
      loadAcknowledgedCastMedia(
        statuses: statuses.stream,
        acknowledge: (status) => status == 'owned',
        load: () async => statuses.add('foreign'),
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(statuses.hasListener, isFalse);
    await statuses.close();
  });

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

  test('a stuck load remains bounded after its receiver acknowledgement', () async {
    final statuses = StreamController<String>.broadcast(sync: true);
    final pending = Completer<void>();
    await expectLater(
      loadAcknowledgedCastMedia(
        statuses: statuses.stream,
        acknowledge: (status) => status == 'owned',
        load: () {
          statuses.add('owned');
          return pending.future;
        },
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(statuses.hasListener, isFalse);
    pending.complete();
    await statuses.close();
  });

  test('connection invalidation cancels an acknowledged load still waiting for native completion', () async {
    final statuses = StreamController<String>.broadcast(sync: true);
    final invalidated = StreamController<void>.broadcast(sync: true);
    final pending = Completer<void>();
    final loading = loadAcknowledgedCastMedia(
      statuses: statuses.stream,
      invalidated: invalidated.stream,
      acknowledge: (status) => status == 'owned',
      load: () {
        statuses.add('owned');
        return pending.future;
      },
    );
    final failure = expectLater(loading, throwsStateError);
    invalidated.add(null);
    await failure;
    expect(statuses.hasListener, isFalse);
    expect(invalidated.hasListener, isFalse);
    pending.complete();
    await statuses.close();
    await invalidated.close();
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
