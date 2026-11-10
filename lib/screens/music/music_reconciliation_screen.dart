import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_experience.dart';

class MusicReconciliationScreen extends StatefulWidget {
  const MusicReconciliationScreen({super.key});
  @override
  State<MusicReconciliationScreen> createState() => _MusicReconciliationScreenState();
}

class _MusicReconciliationScreenState extends State<MusicReconciliationScreen> {
  late final MusicExperience _experience = context.read<MusicExperience>();
  List<Map<String, dynamic>> _conflicts = [];
  (int, String)? _cursor;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      if (!more) await _experience.ratings.sync();
      final page = await _experience.store.documentPage('ratingConflict', limit: 50, after: more ? _cursor : null);
      if (!mounted || !_experience.store.active) return;
      setState(() {
        _conflicts = more ? [..._conflicts, ...page.entries] : page.entries;
        _cursor = page.cursor;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolve(Map<String, dynamic> conflict, bool keepLocal) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final resolved = await _experience.ratings.resolveConflict(
        conflict['id'] as String,
        conflict['revision'] as String,
        keepLocal: keepLocal,
      );
      if (mounted && !resolved) setState(() => _failed = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && !_failed) await _load();
  }

  String _value(Object? value) => switch (value) {
    true => t.common.yes,
    false => t.common.no,
    null => t.musicTools.missing,
    _ => value.toString(),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t.homeLayout.sync),
      actions: [TextButton(onPressed: _busy ? null : _load, child: Text(t.common.refresh))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_failed) Text(t.musicExperience.error),
        for (final conflict in _conflicts) ..._card(conflict),
        if (_cursor != null)
          TextButton(onPressed: _busy ? null : () => _load(more: true), child: Text(t.fileSources.loadMore)),
        if (!_busy && _conflicts.isEmpty) Text(t.fileSources.empty),
      ],
    ),
  );

  List<Widget> _card(Map<String, dynamic> conflict) {
    try {
      final item = MediaItem.fromJson(Map<String, dynamic>.from(conflict['item'] as Map));
      final client = _experience.clientFor(item);
      if (client == null || musicAccountScope(client) != conflict['scope']) return [];
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.displayTitle, style: Theme.of(context).textTheme.titleMedium),
                Text(conflict['kind'] == 'rating' ? t.libraries.sortLabels.userRating : t.rateSheet.favorite),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : () => _resolve(conflict, true),
                      child: Text('${t.fileSources.useLocal}: ${_value(conflict['value'])}'),
                    ),
                    FilledButton.tonal(
                      onPressed: _busy ? null : () => _resolve(conflict, false),
                      child: Text('${t.fileSources.useRemote}: ${_value(conflict['remote'])}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ];
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }
}
