import 'extras_models.dart';

enum ExtraRejection { unrelated, unsupported, unverified, hidden, unavailable, restricted, spoilers, disabled }

/// An empty result is successful. No score, popularity, AI output or shortage
/// of candidates can override these independent admission checks.
class ExtrasPolicy {
  const ExtrasPolicy();
  ExtraRejection? rejection(ExtraEntry entry, ExtrasSubject subject, ExtrasPreferences prefs) {
    if (!entry.parentIdentities.any(subject.allIdentities.contains)) {
      return ExtraRejection.unrelated;
    }
    if (prefs.hiddenIds.contains(entry.id) ||
        prefs.wrongMatches.contains('${subject.key}|${entry.id}') ||
        (entry.publisherId.isNotEmpty && prefs.hiddenPublishers.contains(entry.publisherId))) {
      return ExtraRejection.hidden;
    }
    if (!entry.available) return ExtraRejection.unavailable;
    if (!entry.isLibrary && (subject.restricted || subject.offline)) {
      return ExtraRejection.restricted;
    }
    if (!entry.isLibrary && !prefs.externalEnabled) {
      return ExtraRejection.disabled;
    }
    if (!entry.isLibrary && canonicalExtraUrl(entry.url) == null) {
      return ExtraRejection.unsupported;
    }
    if (entry.scope != ExtraScope.work && entry.scopeLabel.trim().isEmpty) {
      return ExtraRejection.unrelated;
    }
    if (entry.origin != ExtraOrigin.user && !entry.isLibrary) {
      if (entry.kind == ExtraKind.other || (entry.kind == ExtraKind.analysis && !prefs.includeAnalysis)) {
        return ExtraRejection.unsupported;
      }
      if (!entry.reviewedAssociation && !(entry.verifiedPublisher && entry.catalogAssociated)) {
        return ExtraRejection.unverified;
      }
    }
    // Explicitly added links remain accessible inside this title. They never
    // authorize another title, publisher, or automatically found candidate.
    if (!subject.watched && !prefs.showSpoilers && !entry.spoilerSafe && entry.origin != ExtraOrigin.user) {
      return ExtraRejection.spoilers;
    }
    return null;
  }

  List<ExtraEntry> select(Iterable<ExtraEntry> candidates, ExtrasSubject subject, ExtrasPreferences prefs) {
    final eligible = candidates.where((e) => rejection(e, subject, prefs) == null).toList();
    int priority(ExtraEntry e) =>
        (e.isLibrary
                ? 0
                : e.origin == ExtraOrigin.user
                ? 1
                : e.reviewedAssociation
                ? 2
                : 3) *
            10 +
        (e.kind == ExtraKind.trailer
            ? 5
            : e.kind == ExtraKind.analysis
            ? 6
            : 0);
    eligible.sort((a, b) {
      final result = priority(a).compareTo(priority(b));
      return result != 0 ? result : a.id.compareTo(b.id);
    });
    final seen = <String>{}, groups = <String>{};
    final result = <ExtraEntry>[];
    for (final entry in eligible) {
      if (!seen.add(entry.duplicateKey)) continue;
      if (entry.contentGroup.isNotEmpty && !groups.add(entry.contentGroup)) {
        continue;
      }
      result.add(entry);
    }
    return List.unmodifiable(result);
  }

  List<ExtraEntry> preview(List<ExtraEntry> eligible) {
    final kinds = <ExtraKind>{};
    final diverse = <ExtraEntry>[], remainder = <ExtraEntry>[];
    for (final entry in eligible) {
      (kinds.add(entry.kind) ? diverse : remainder).add(entry);
    }
    return [...diverse, ...remainder].take(4).toList(growable: false);
  }
}

const extraTopicWords = <ExtraKind, List<String>>{
  ExtraKind.makingOf: ['making', 'production', 'behind', 'scenes', 'filming', 'sets', 'miniatures'],
  ExtraKind.effects: ['effects', 'vfx', 'cgi', 'animation', 'creatures', 'stunts'],
  ExtraKind.makeup: ['makeup', 'prosthetics', 'costumes', 'creatures'],
  ExtraKind.interview: ['interview', 'cast', 'director', 'crew'],
  ExtraKind.deletedScene: ['deleted', 'extended', 'alternate'],
  ExtraKind.bloopers: ['bloopers', 'outtakes', 'gag'],
  ExtraKind.commentary: ['commentary'],
  ExtraKind.trailer: ['trailer', 'teaser'],
  ExtraKind.analysis: ['analysis'],
};

Set<String> extraQueryWords(String value) => value
    .toLowerCase()
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where(
      (s) =>
          s.length > 1 &&
          !const {'the', 'how', 'they', 'did', 'made', 'with', 'and', 'about', 'this', 'show', 'me'}.contains(s),
    )
    .toSet();

bool extraMatchesQuery(ExtraEntry entry, String query) {
  final words = extraQueryWords(query);
  if (words.isEmpty) return true;
  final text = '${entry.title} ${entry.description} ${entry.publisher} ${extraTopicWords[entry.kind]?.join(' ') ?? ''}'
      .toLowerCase();
  return words.any(text.contains) ||
      (entry.analysisAllowed && entry.passages.any((p) => words.any(p.text.toLowerCase().contains)));
}

List<ExtraPassage> searchExtraPassages(ExtraEntry entry, String query) {
  if (!entry.analysisAllowed) return const [];
  final words = extraQueryWords(query);
  if (words.isEmpty) return entry.passages.take(8).toList();
  final passages = entry.passages.where((p) => words.any(p.text.toLowerCase().contains)).toList();
  passages.sort(
    (a, b) =>
        words.where(b.text.toLowerCase().contains).length.compareTo(words.where(a.text.toLowerCase().contains).length),
  );
  return passages.take(8).toList();
}

/// MediaBrowser policy must be known before external, unrated providers can
/// appear beside a user's filtered server library. Shared by Jellyfin/Emby.
bool mediaBrowserAllowsExternalExtras(Object? policy) {
  if (policy is! Map || policy['EnableMediaPlayback'] != true || policy['IsDisabled'] == true) return false;
  if (policy['MaxParentalRating'] != null || policy['EnableAllFolders'] == false) return false;
  for (final key in ['BlockedTags', 'BlockedMediaFolders', 'BlockUnratedItems', 'AccessSchedules']) {
    final value = policy[key];
    if (value != null && (value is! List || value.isNotEmpty)) return false;
  }
  return true;
}
