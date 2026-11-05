import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../sources/podcast_automation.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import 'source_widgets.dart';

class PodcastSettingsScreen extends StatefulWidget {
  const PodcastSettingsScreen({super.key});
  @override
  State<PodcastSettingsScreen> createState() => _PodcastSettingsScreenState();
}

class _PodcastSettingsScreenState extends State<PodcastSettingsScreen> {
  final Map<String, PodcastPolicy> _policies = {};
  bool _loading = true;
  SourceController? _owner;
  int? _epoch;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.watch<SourceController>();
    if (!identical(owner, _owner) || _epoch != owner.generation) {
      _owner = owner; _epoch = owner.generation;
      _policies.clear(); _loading = true;
      _load(owner, owner.generation);
    }
  }
  Future<void> _load(SourceController owner, int epoch) async {
    try {
    await owner.ready;
    if (!mounted || !owner.current(epoch) || owner.blocked) return;
    final next = <String, PodcastPolicy>{};
    for (final source in owner.sources.where((s) => s.kind == FileSourceKind.podcastRss)) {
      next[source.id] = await owner.podcastAutomation.policy(source.id);
    }
    if (mounted && owner.current(epoch)) setState(() { _policies.addAll(next); _loading = false; _error = null; });
    } on Object catch (error) {
      if (mounted && owner.current(epoch)) setState(() { _error = error; _loading = false; });
    }
  }
  Future<void> _edit(FileSource source) async {
    final owner = _owner!, epoch = owner.generation;
    final current = _policies[source.id] ?? const PodcastPolicy();
    var count = current.keepLatest, days = current.removeFinishedDays;
    var notify = current.notify, wifi = current.wifiOnly;
    final policy = await showDialog<PodcastPolicy>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, change) => AlertDialog(title: Text(source.name), content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<int>(initialValue: count,
            decoration: InputDecoration(labelText: t.downloads.downloadNow),
            items: [for (final n in {0, 1, 3, 5, 10, 20, 50, count}) DropdownMenuItem(value: n, child: Text('$n'))],
            onChanged: (n) => change(() => count = n ?? 0)),
          SwitchListTile(title: Text(t.settings.downloadOnWifiOnly), value: wifi, onChanged: (value) => change(() => wifi = value)),
          SwitchListTile(title: Text(t.settings.newEpisodeNotifications), value: notify, onChanged: (value) => change(() => notify = value)),
          DropdownButtonFormField<int>(initialValue: days,
            decoration: InputDecoration(labelText: t.settings.autoRemoveWatchedDownloads),
            items: [for (final n in {0, 1, 7, 30, days}) DropdownMenuItem(value: n, child: Text(n == 0 ? t.common.off : '$n d'))],
            onChanged: (n) => change(() => days = n ?? 0)),
        ])), actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, PodcastPolicy(keepLatest: count,
            removeFinishedDays: days, notify: notify, wifiOnly: wifi)), child: Text(t.common.save)),
        ]),
    ));
    if (policy == null || !mounted || !owner.current(epoch)) return;
    await sourceAction(context, () async {
      owner.requireSession(epoch);
      await owner.podcastAutomation.savePolicy(source.id, policy);
      if (mounted && owner.current(epoch)) setState(() => _policies[source.id] = policy);
    });
  }
  @override
  Widget build(BuildContext context) {
    final feeds = _owner?.sources.where((s) => s.kind == FileSourceKind.podcastRss).toList() ?? <FileSource>[];
    return FocusedScrollScaffold(title: Text(t.podcasts.title), slivers: [
      if (_loading) const SliverToBoxAdapter(child: LinearProgressIndicator()),
      if (_error != null) SliverToBoxAdapter(child: SourceErrorMessage(message: sourceFailureText(_error!))),
      SliverList.builder(itemCount: feeds.length, itemBuilder: (context, index) {
        final source = feeds[index], policy = _policies[source.id];
        return FocusableListTile(title: Text(source.name),
          subtitle: Text('${t.downloads.downloadNow}: ${policy?.keepLatest ?? 0}'),
          onTap: _loading ? null : () => _edit(source));
      }),
    ]);
  }
}
