import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/extras/extras_models.dart';
import 'package:plezy/extras/extras_policy.dart';

void main() {
  const subject = ExtrasSubject(
    key: 'movie/tmdb:120',
    identities: {'movie/tmdb:120'},
    title: 'Fellowship',
    watched: true,
  );
  const policy = ExtrasPolicy();
  ExtraEntry entry({
    String id = '12345678901',
    Set<String> parents = const {'movie/tmdb:120'},
    bool verified = true,
    bool associated = true,
    bool reviewed = false,
    ExtraKind kind = ExtraKind.makingOf,
    ExtraScope scope = ExtraScope.work,
    String label = '',
    String group = '',
  }) => ExtraEntry(
    id: id,
    parentIdentities: parents,
    title: 'Making of',
    kind: kind,
    origin: ExtraOrigin.catalog,
    url: Uri.https('www.youtube.com', '/watch', {'v': id}),
    verifiedPublisher: verified,
    catalogAssociated: associated,
    reviewedAssociation: reviewed,
    scope: scope,
    scopeLabel: label,
    publisherId: 'studio',
    contentGroup: group,
  );
  test('publisher reputation cannot admit another film or remake', () {
    expect(
      policy.select(
        [
          entry(parents: {'movie/tmdb:121'}),
        ],
        subject,
        const ExtrasPreferences(),
      ),
      isEmpty,
    );
    expect(
      policy.select(
        [
          entry(parents: {'show/tmdb:120'}),
        ],
        subject,
        const ExtrasPreferences(),
      ),
      isEmpty,
    );
  });
  test('catalogue association and publisher verification are independent', () {
    expect(
      policy.select(
        [entry(verified: false)],
        subject,
        const ExtrasPreferences(),
      ),
      isEmpty,
    );
    expect(
      policy.select(
        [entry(associated: false)],
        subject,
        const ExtrasPreferences(),
      ),
      isEmpty,
    );
    expect(
      policy.select(
        [entry(verified: false, associated: false, reviewed: true)],
        subject,
        const ExtrasPreferences(),
      ),
      hasLength(1),
    );
  });
  test('franchise associations must disclose their broader scope', () {
    expect(
      policy.select(
        [entry(scope: ExtraScope.franchise)],
        subject,
        const ExtrasPreferences(),
      ),
      isEmpty,
    );
    expect(
      policy.select(
        [entry(scope: ExtraScope.franchise, label: 'About the trilogy')],
        subject,
        const ExtrasPreferences(),
      ),
      hasLength(1),
    );
  });
  test(
    'AI mode does not change admission, including a single weak candidate',
    () {
      for (final mode in ExtrasAiMode.values) {
        expect(
          policy.select(
            [entry(verified: false)],
            subject,
            ExtrasPreferences(aiMode: mode),
          ),
          isEmpty,
        );
      }
    },
  );
  test('unknown spoiler status is not assumed safe', () {
    const unwatched = ExtrasSubject(
      key: 'movie/tmdb:120',
      identities: {},
      title: 'Fellowship',
    );
    expect(
      policy.select([entry()], unwatched, const ExtrasPreferences()),
      isEmpty,
    );
    expect(
      policy.select(
        [entry()],
        unwatched,
        const ExtrasPreferences(showSpoilers: true),
      ),
      hasLength(1),
    );
  });
  test('restricted and offline profiles never receive external candidates', () {
    for (final s in [
      const ExtrasSubject(
        key: 'movie/tmdb:120',
        identities: {},
        title: '',
        watched: true,
        restricted: true,
      ),
      const ExtrasSubject(
        key: 'movie/tmdb:120',
        identities: {},
        title: '',
        watched: true,
        offline: true,
      ),
    ]) {
      expect(policy.select([entry()], s, const ExtrasPreferences()), isEmpty);
    }
  });
  test('user exclusions persist beyond rediscovery', () {
    for (final prefs in [
      const ExtrasPreferences(hiddenIds: {'12345678901'}),
      const ExtrasPreferences(hiddenPublishers: {'studio'}),
      const ExtrasPreferences(wrongMatches: {'movie/tmdb:120|12345678901'}),
    ]) {
      expect(policy.select([entry()], subject, prefs), isEmpty);
    }
  });
  test('analysis requires opt-in and other content cannot pad the row', () {
    expect(
      policy.select(
        [entry(kind: ExtraKind.analysis), entry(kind: ExtraKind.other)],
        subject,
        const ExtrasPreferences(),
      ),
      isEmpty,
    );
    expect(
      policy.select(
        [entry(kind: ExtraKind.analysis)],
        subject,
        const ExtrasPreferences(includeAnalysis: true),
      ),
      hasLength(1),
    );
  });
  test('deduplicates provider URLs and reviewed content groups', () {
    expect(
      policy.select([entry(), entry()], subject, const ExtrasPreferences()),
      hasLength(1),
    );
    expect(
      policy.select(
        [entry(group: 'film'), entry(id: 'abcdefghijk', group: 'film')],
        subject,
        const ExtrasPreferences(),
      ),
      hasLength(1),
    );
  });
  test(
    'preview is diverse, deterministic and at most four without padding',
    () {
      final entries = List.generate(
        10,
        (i) => entry(
          id: '1234567890$i',
          kind: i < 7 ? ExtraKind.makingOf : ExtraKind.interview,
        ),
      );
      final preview = policy.preview(
        policy.select(entries, subject, const ExtrasPreferences()),
      );
      expect(preview, hasLength(4));
      expect(preview[1].kind, ExtraKind.interview);
      expect(policy.preview([entry()]), hasLength(1));
      expect(policy.preview([]), isEmpty);
    },
  );
  test(
    'watch URL normalization strips tracking and rejects hostile routes',
    () {
      expect(
        canonicalExtraUrl(Uri.parse('https://youtu.be/abcdefghijk?t=20')),
        Uri.parse('https://www.youtube.com/watch?v=abcdefghijk'),
      );
      for (final value in [
        'javascript:alert(1)',
        'https://youtube.com.evil.test/watch?v=abcdefghijk',
        'https://secret@youtube.com/watch?v=abcdefghijk',
        'https://youtube.com:8443/watch?v=abcdefghijk',
        'https://youtube.com/redirect?q=https://evil.test',
        'http://youtube.com/watch?v=abcdefghijk',
      ]) {
        expect(canonicalExtraUrl(Uri.parse(value)), isNull);
      }
    },
  );
  test('metadata cannot create local playback or confer user approval', () {
    final candidate = ExtraEntry.parse({
      ...entry().toJson(),
      'origin': 'library',
      'nativeKey': 'server-secret',
    });
    expect(candidate?.isLibrary, false);
    expect(candidate?.origin, ExtraOrigin.search);
    expect(
      ExtraEntry.parse({...entry().toJson(), 'origin': 'user'})?.origin,
      ExtraOrigin.search,
    );
  });
  test('conventional topic and transcript search works with AI off', () {
    expect(
      extraMatchesQuery(
        entry(kind: ExtraKind.makeup),
        'how they made the prosthetics',
      ),
      true,
    );
    const extra = ExtraEntry(
      id: 'local',
      parentIdentities: {},
      title: '',
      kind: ExtraKind.makingOf,
      origin: ExtraOrigin.library,
      analysisAllowed: true,
      passages: [
        ExtraPassage(
          startSeconds: 20,
          endSeconds: 30,
          text: 'The prosthetics were fitted here.',
        ),
      ],
    );
    expect(searchExtraPassages(extra, 'prosthetics').single.startSeconds, 20);
  });
}
