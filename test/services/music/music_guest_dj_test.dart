import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/music/music_guest_dj.dart';
import '../../test_helpers/music_experience_fakes.dart';

void main() {
  late ExperienceMusic music;
  late ExperienceClient client;
  late MusicGuestDj dj;
  setUp(() {
    music = ExperienceMusic()..items = [musicTrack('a'), musicTrack('b')];
    client = ExperienceClient()..rows = [musicTrack('a'), musicTrack('guest'), musicTrack('b')];
    dj = MusicGuestDj(music, (_) => client);
  });
  tearDown(() {
    dj.dispose();
    music.dispose();
  });
  test('twofer inserts one new track, and off preserves original queue', () async {
    await dj.select(MusicDjMode.twofer);
    expect(music.queue.map((t) => t.id), ['a', 'guest', 'b']);
    expect(MusicGuestDj.isGenerated(music.queue[1]), isTrue);
    await dj.select(MusicDjMode.off);
    expect(music.queue.map((t) => t.id), ['a', 'b']);
  });
  test('manual insertion invalidates a pending response', () async {
    final pending = Completer<List<MediaItem>>();
    client.sonic = (_) => pending.future;
    final work = dj.select(MusicDjMode.gemini);
    music.addNext([musicTrack('manual')]);
    pending.complete([musicTrack('guest')]);
    await work;
    expect(music.queue.map((t) => t.id), ['a', 'manual', 'b']);
  });
  test('disabled DJ rejects late completion', () async {
    final pending = Completer<List<MediaItem>>();
    client.sonic = (_) => pending.future;
    final work = dj.select(MusicDjMode.freeze);
    await dj.select(MusicDjMode.off);
    pending.complete([musicTrack('guest')]);
    await work;
    expect(music.queue.map((t) => t.id), ['a', 'b']);
    expect(dj.busy, isFalse);
  });
  test('authentication replacement invalidates late catalog results', () async {
    final pending = Completer<List<MediaItem>>();
    client.sonic = (_) => pending.future;
    final work = dj.select(MusicDjMode.gemini);
    client.authenticationSessionId = Object();
    pending.complete([musicTrack('guest')]);
    await work;
    expect(music.queue.map((t) => t.id), ['a', 'b']);
  });
  test('track transition while busy retries the new occurrence', () async {
    final pending = Completer<List<MediaItem>>();
    final calls = <String>[];
    client.sonic = (id) {
      calls.add(id);
      return id == 'a' ? pending.future : Future.value([musicTrack('new-guest')]);
    };
    final work = dj.select(MusicDjMode.gemini);
    music.moveTo(1);
    pending.complete([musicTrack('old-guest')]);
    await work;
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['a', 'b']);
    expect(music.queue.map((t) => t.id), ['a', 'b', 'new-guest']);
  });
  test('generated tracks do not recursively expand Twofer', () async {
    await dj.select(MusicDjMode.twofer);
    music.moveTo(1);
    await Future<void>.delayed(Duration.zero);
    expect(music.queue, hasLength(3));
    music.session++;
    music.changed();
    expect(dj.mode, MusicDjMode.off);
  });
  test('contempo verifies era even if the server ignores filters', () async {
    client.rows = [musicTrack('old', year: 1900), musicTrack('near', year: 2004), musicTrack('unknown', year: null)];
    await dj.select(MusicDjMode.contempo);
    expect(music.queue.map((t) => t.id), ['a', 'near', 'b']);
  });
}
