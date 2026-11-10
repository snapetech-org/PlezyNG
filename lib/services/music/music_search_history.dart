import 'music_library_store.dart';

class MusicSearchHistory {
  MusicSearchHistory(this.store);
  final MusicLibraryStore store;
  static const int limit = 20;
  static const int maxQueryLength = 256;

  Future<List<String>> load() async {
    final document = await store.document('search', 'recent');
    if (!store.active || document?['version'] != 1 || document?['queries'] is! List) return [];
    final queries = <String>[], seen = <String>{};
    for (final value in (document!['queries'] as List).take(100)) {
      if (value is! String) continue;
      final query = value.trim();
      if (query.isEmpty || query.length > maxQueryLength || !seen.add(query.toLowerCase())) continue;
      queries.add(query);
      if (queries.length == limit) break;
    }
    return queries;
  }

  Future<void> record(String value) async {
    final query = value.trim();
    if (query.isEmpty || query.length > maxQueryLength) return;
    await _edit((queries) => [query, ...queries.where((other) => other.toLowerCase() != query.toLowerCase())]);
  }

  Future<void> remove(String query) =>
      _edit((queries) => queries.where((other) => other.toLowerCase() != query.toLowerCase()).toList());

  Future<void> clear() => _edit((_) => []);

  Future<void> _edit(List<String> Function(List<String>) edit) => store.database.transaction(() async {
    if (!store.active) return;
    final queries = edit(await load()).take(limit).toList();
    if (!store.active) return;
    if (queries.isEmpty) {
      await store.deleteDocument('search', 'recent');
    } else {
      await store.saveDocument('search', 'recent', {'version': 1, 'queries': queries});
    }
  });
}
