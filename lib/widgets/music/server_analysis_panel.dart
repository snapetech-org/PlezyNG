import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/plex_client.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/snackbar_helper.dart';

/// Verified owner controls for the server's named music tasks. Activity
/// percentages belong to their individual server jobs, never the track/library
/// whose details opened this panel.
class MusicServerAnalysisPanel extends StatefulWidget {
  const MusicServerAnalysisPanel({super.key, required this.client, required this.current});

  final PlexClient client;
  final bool Function() current;

  @override
  State<MusicServerAnalysisPanel> createState() => _MusicServerAnalysisPanelState();
}

class _MusicServerAnalysisPanelState extends State<MusicServerAnalysisPanel> with WidgetsBindingObserver {
  late final _authentication = widget.client.authenticationSessionId;
  late final _scope = musicAccountScope(widget.client);
  Timer? _poll;
  AbortController? _abort;
  int _epoch = 0;
  bool _open = false, _busy = false, _failed = false;
  PlexMusicServerAnalysisSnapshot? _snapshot;

  bool get _available =>
      mounted &&
      widget.current() &&
      identical(_authentication, widget.client.authenticationSessionId) &&
      _scope == musicAccountScope(widget.client) &&
      widget.client.hasVerifiedMusicServerOwner &&
      !widget.client.isOfflineMode;
  bool get _visible =>
      _available &&
      _open &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent != false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _retireRead() {
    _epoch++;
    _abort?.abort();
    _abort = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _retireRead();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    } else {
      _retireRead();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _expand(bool open) {
    _retireRead();
    _poll?.cancel();
    setState(() {
      _open = open;
      _busy = false;
    });
    if (open) {
      unawaited(_refresh());
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_refresh()));
    }
  }

  Future<void> _refresh() async {
    if (!_visible || _busy) return;
    final epoch = ++_epoch;
    final abort = _abort = AbortController();
    bool current() => _visible && epoch == _epoch;
    setState(() => _busy = true);
    try {
      final snapshot = await widget.client.readMusicServerAnalysis(current: current, abort: abort);
      if (current()) {
        setState(() {
          _snapshot = snapshot;
          _failed = false;
        });
      }
    } catch (_) {
      if (current()) {
        setState(() {
          _failed = true;
          _snapshot = null;
        });
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
      if (identical(_abort, abort)) _abort = null;
    }
  }

  String _title(PlexMusicServerTask task) => switch (task) {
    PlexMusicServerTask.sonic => t.musicTools.sonicAnalysis,
    PlexMusicServerTask.loudness => t.music.visualizerPlexLoudness,
  };

  Future<void> _change(PlexMusicServerTask task, {required bool start}) async {
    if (!_visible || _busy) return;
    final epoch = ++_epoch;
    bool current() => _visible && epoch == _epoch;
    setState(() => _busy = true);
    try {
      final dialog = DialogRoute<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_title(task)),
          content: Text(t.musicTools.serverAnalysisScope),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(start ? t.libraries.analyze : t.common.confirm),
            ),
          ],
        ),
      );
      final confirmed = await Navigator.of(context, rootNavigator: true).push(dialog);
      // pop's result precedes route retirement; wait until our panel can be
      // current again before applying its visibility and ownership guards.
      await dialog.completed;
      if (confirmed != true || !current()) return;
      await widget.client.changeMusicServerAnalysis(task, start: start, current: current);
      if (mounted && current()) showAppSnackBar(context, t.musicTools.loudnessRequested);
    } catch (_) {
      if (current()) {
        setState(() {
          _failed = true;
          _snapshot = null;
        });
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
    if (current()) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    final snapshot = _snapshot;
    return ExpansionTile(
      title: Text(t.musicTools.serverAnalysis),
      subtitle: Text(widget.client.serverName ?? t.common.unknown),
      onExpansionChanged: _expand,
      children: [
        if (_open)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.musicTools.serverAnalysisScope),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(onPressed: _busy ? null : _refresh, child: Text(t.common.refresh)),
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_failed) Text(t.musicExperience.error),
                if (snapshot != null) ...[
                  if (snapshot.tasks.isEmpty) Text(t.musicExperience.unsupported),
                  for (final task in PlexMusicServerTask.values)
                    if (snapshot.tasks.contains(task)) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_title(task), style: Theme.of(context).textTheme.titleMedium),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: _busy ? null : () => _change(task, start: true),
                            child: Text(t.libraries.analyze),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _change(task, start: false),
                            child: Text(t.common.cancel),
                          ),
                        ],
                      ),
                    ],
                  const SizedBox(height: 16),
                  Text(t.musicTools.serverActivities, style: Theme.of(context).textTheme.titleMedium),
                  if (snapshot.activities.isEmpty) Text(t.messages.noItemsAvailable),
                  for (final activity in snapshot.activities)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(activity.title),
                          if (activity.subtitle case final subtitle?) Text(subtitle),
                          LinearProgressIndicator(
                            semanticsLabel: activity.title,
                            value: activity.progress < 0 || activity.progress > 100 ? null : activity.progress / 100,
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
