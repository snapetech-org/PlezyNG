import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../i18n/strings.g.dart';
import '../../sources/gpodder_client.dart';
import '../../sources/podcast_sync.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import 'source_widgets.dart';

class PodcastSyncScreen extends StatefulWidget {
  const PodcastSyncScreen({super.key});
  @override
  State<PodcastSyncScreen> createState() => _PodcastSyncScreenState();
}

class _PodcastSyncScreenState extends State<PodcastSyncScreen> {
  final _endpoint = TextEditingController(), _username = TextEditingController(), _password = TextEditingController();
  SourceController? _owner;
  int? _epoch;
  String _device = '';
  bool _loading = true, _busy = false, _consent = false, _subscriptions = true, _progress = true;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.watch<SourceController>();
    if (!identical(owner, _owner) || owner.generation != _epoch) {
      _owner = owner; _epoch = owner.generation;
      _endpoint.clear(); _username.clear(); _password.clear();
      _device = ''; _consent = false; _loading = true; _busy = false; _error = null;
      _load(owner, owner.generation);
    }
  }
  Future<void> _load(SourceController owner, int epoch) async {
    try {
      await owner.ready;
      owner.requireSession(epoch);
      final config = await owner.podcastSync.config();
      if (!mounted || !owner.current(epoch)) return;
      setState(() {
        _endpoint.text = config?.endpoint ?? 'https://gpodder.net'; _username.text = config?.username ?? '';
        _password.text = config?.password ?? ''; _device = config?.device ?? 'plezyng-${const Uuid().v4()}';
        _consent = config != null; _subscriptions = config?.subscriptions ?? true;
        _progress = config?.progress ?? true; _loading = false;
      });
    } on Object catch (error) {
      if (mounted && owner.current(epoch)) setState(() { _error = error; _loading = false; });
    }
  }
  Future<void> _perform(Future<void> Function(SourceController, int) operation) async {
    final owner = _owner!, epoch = owner.generation;
    setState(() { _busy = true; _error = null; });
    try { owner.requireSession(epoch); await operation(owner, epoch); }
    on Object catch (error) { if (mounted && owner.current(epoch)) setState(() => _error = error); }
    finally { if (mounted && owner.current(epoch)) setState(() => _busy = false); }
  }
  Future<void> _save() => _perform((owner, epoch) async {
    await owner.podcastSync.configure(GpodderConfig(endpoint: _endpoint.text.trim(), username: _username.text.trim(),
      password: _password.text, device: _device, subscriptions: _subscriptions, progress: _progress));
    owner.requireSession(epoch);
    await owner.podcastSync.run();
  });
  Future<void> _conflicts() async {
    final owner = _owner!, epoch = owner.generation;
    final conflicts = await owner.podcastSync.conflicts();
    owner.requireSession(epoch);
    for (final conflict in conflicts) {
      final key = conflict['key'] as String;
      final current = await owner.repository.progress(owner.profileId!, key);
      final entry = await owner.repository.entryByKey(owner.profileId!, conflict['entry'] as String);
      owner.requireSession(epoch);
      if (!mounted || current == null) return;
      final remote = PublicationProgress.fromJson(sourceMap(conflict['remote']));
      final useRemote = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(entry?.displayTitle ?? t.podcasts.title),
        content: Text('${t.fileSources.conflict}\n\n${t.fileSources.useLocal}: ${Duration(milliseconds: current.positionMs).toString().split('.').first}\n'
          '${t.fileSources.useRemote}: ${Duration(milliseconds: remote.positionMs).toString().split('.').first}'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.fileSources.useLocal)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.fileSources.useRemote))]));
      if (useRemote == null || !mounted) return;
      owner.requireSession(epoch);
      await owner.podcastSync.resolveConflict(key, useRemote: useRemote,
        expectedRevision: current.revision, expectedRemoteHash: conflict['remoteHash'] as String);
    }
  }
  @override
  void dispose() { _endpoint.dispose(); _username.dispose(); _password.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final sync = _loading || _error != null ? null : _owner?.podcastSync;
    final blocked = _loading || _busy || sync?.phase == PodcastSyncPhase.running;
    return SettingsPage(title: Text(t.podcasts.syncConnect), children: [
      if (_loading || _busy || sync?.phase == PodcastSyncPhase.running) const LinearProgressIndicator(),
      if (_error != null || sync?.failure != null) SourceErrorMessage(message: sourceFailureText(_error ?? SourceException(sync!.failure!))),
      Padding(padding: const EdgeInsets.all(16), child: Text(t.podcasts.syncPrivacy)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
        TextField(controller: _endpoint, enabled: !blocked, decoration: InputDecoration(labelText: t.fileSources.endpoint),
          onChanged: (_) => setState(() => _consent = false)),
        TextField(controller: _username, enabled: !blocked, decoration: InputDecoration(labelText: t.fileSources.username),
          onChanged: (_) => setState(() => _consent = false)),
        TextField(controller: _password, enabled: !blocked, obscureText: true, enableSuggestions: false, autocorrect: false,
          decoration: InputDecoration(labelText: t.fileSources.password)),
      ])),
      Padding(padding: const EdgeInsets.all(16), child: SelectableText('${t.podcasts.syncDevice}: $_device\n${t.podcasts.syncDevicesHelp}')),
      SwitchListTile(title: Text(t.podcasts.syncSubscriptions), value: _subscriptions,
        onChanged: blocked ? null : (value) => setState(() => _subscriptions = value)),
      SwitchListTile(title: Text(t.fileSources.sync), value: _progress,
        onChanged: blocked ? null : (value) => setState(() => _progress = value)),
      CheckboxListTile(title: Text(t.podcasts.syncConsent), value: _consent,
        onChanged: blocked ? null : (value) => setState(() => _consent = value == true)),
      Padding(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, runSpacing: 12, children: [
        FilledButton(onPressed: blocked || !_consent ? null : _save, child: Text(t.common.connect)),
        OutlinedButton(onPressed: blocked ? null : () => _perform((owner, epoch) => owner.podcastSync.run()), child: Text(t.podcasts.syncNow)),
        TextButton(onPressed: blocked ? null : () => _perform((owner, epoch) async {
          await owner.podcastSync.configure(null);
          if (mounted && owner.current(epoch)) setState(() { _consent = false; _password.clear(); });
        }), child: Text(t.common.disconnect)),
      ])),
      if ((sync?.conflictCount ?? 0) > 0) FocusableListTile(title: Text(t.audiobook.syncConflicts),
        subtitle: Text('${sync!.conflictCount}'), onTap: blocked ? null : () => _perform((owner, epoch) => _conflicts())),
      if ((sync?.pendingCount ?? 0) > 0) Padding(padding: const EdgeInsets.all(16), child: Text(t.podcasts.syncPending)),
    ]);
  }
}
