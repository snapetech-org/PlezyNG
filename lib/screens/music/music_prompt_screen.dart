import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../widgets/app_icon.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/ids.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/credential_vault.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/music/music_prompt_playlist.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import '../../utils/snackbar_helper.dart';

class MusicPromptScreen extends StatefulWidget {
  const MusicPromptScreen({super.key});
  @override
  State<MusicPromptScreen> createState() => _MusicPromptScreenState();
}

class _MusicPromptScreenState extends State<MusicPromptScreen> {
  final _endpoint = TextEditingController(),
      _model = TextEditingController(),
      _key = TextEditingController(),
      _prompt = TextEditingController(),
      _title = TextEditingController();
  late final MusicExperience _experience = context.read<MusicExperience>();
  bool _consent = false, _busy = false, _loaded = false;
  String? _error;
  int _revision = 0;
  MusicPromptProvider? _provider;
  AbortController? _abort;
  List<MusicProposalMatch> _matches = [];
  final Map<int, MediaItem> _selected = {};
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final config = await _experience.store.document('prompt', 'provider');
    if (!mounted || config == null) return;
    if (_endpoint.text.isEmpty) _endpoint.text = config['endpoint'] as String? ?? '';
    if (_model.text.isEmpty) _model.text = config['model'] as String? ?? '';
    final secret = config['key'] as String?;
    if (secret != null && CredentialVault.isProtected(secret)) {
      final clear = await CredentialVault.reveal(secret);
      if (!mounted) return;
      if (_key.text.isEmpty) _key.text = clear ?? '';
    }
    if (mounted) setState(() {});
  }

  void _cancel() {
    _revision++;
    _provider?.close();
    _abort?.abort();
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _revision++;
    _provider?.close();
    _abort?.abort();
    for (final c in [_endpoint, _model, _key, _prompt, _title]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    final revision = ++_revision;
    _provider?.close();
    _abort?.abort();
    final abort = _abort = AbortController();
    setState(() {
      _busy = true;
      _error = null;
      _matches = [];
      _selected.clear();
    });
    try {
      final provider = _provider = MusicPromptProvider(
        endpoint: Uri.parse(_endpoint.text.trim()),
        model: _model.text.trim(),
        apiKey: _key.text.trim(),
      );
      final proposals = await provider.generate(_prompt.text, consent: _consent);
      if (!mounted || revision != _revision) return;
      final multiServer = context.read<MultiServerProvider>();
      final hidden = context.read<HiddenLibrariesProvider>();
      await hidden.ensureInitialized();
      if (!mounted || revision != _revision) return;
      final matches = await resolveMusicProposals(
        proposals,
        multiServer.serverManager.visibleOnlineClients.values,
        abort: abort,
        current: (client) =>
            multiServer.serverManager.isServerVisible(client.serverId) &&
            identical(client, multiServer.serverManager.getClient(client.serverId)),
        visible: (item) =>
            item.serverId != null &&
            multiServer.serverManager.isServerVisible(ServerId(item.serverId!)) &&
            !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}'),
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _matches = matches;
        for (var i = 0; i < matches.length; i++) {
          if (matches[i].candidates.length == 1) _selected[i] = matches[i].candidates.single;
        }
      });
      await _experience.store.saveDocument('prompt', 'provider', {
        'endpoint': _endpoint.text.trim(),
        'model': _model.text.trim(),
        'key': await CredentialVault.protect(_key.text.trim()),
      });
    } catch (_) {
      if (mounted && revision == _revision) setState(() => _error = t.musicExperience.error);
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  void _move(int from, int to) {
    setState(() {
      final match = _matches[from];
      _matches[from] = _matches[to];
      _matches[to] = match;
      final selected = _selected[from], target = _selected[to];
      _selected.remove(from);
      _selected.remove(to);
      if (selected != null) _selected[to] = selected;
      if (target != null) _selected[from] = target;
    });
  }

  List<MediaItem> get _tracks => [for (var i = 0; i < _matches.length; i++) ?_selected[i]];
  Future<void> _save() async {
    final tracks = _tracks;
    if (tracks.isEmpty || _title.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      if (tracks.any((t) => t.serverId != tracks.first.serverId)) throw StateError('Mixed servers');
      final client = _experience.clientFor(tracks.first);
      if (client == null) throw StateError('Unavailable server');
      final playlist = await client.createPlaylist(title: _title.text.trim(), items: tracks);
      if (playlist == null) throw StateError('Playlist not saved');
      if (mounted) showAppSnackBar(context, t.musicExperience.ready);
    } catch (_) {
      if (mounted) setState(() => _error = t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.musicTools.prompt)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _endpoint,
          enabled: !_busy,
          decoration: InputDecoration(labelText: t.musicTools.provider),
        ),
        TextField(
          controller: _model,
          enabled: !_busy,
          decoration: InputDecoration(labelText: t.musicTools.model),
        ),
        TextField(
          controller: _key,
          enabled: !_busy,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(labelText: t.musicTools.apiKey),
        ),
        SwitchListTile(
          value: _consent,
          title: Text(t.musicTools.consent),
          onChanged: _busy ? null : (v) => setState(() => _consent = v),
        ),
        TextField(
          controller: _prompt,
          enabled: !_busy,
          maxLength: 4000,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(labelText: t.musicTools.promptHint),
        ),
        TextField(
          controller: _title,
          enabled: !_busy,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: t.musicExperience.savePlaylist),
        ),
        FilledButton(
          onPressed: _busy
              ? _cancel
              : _consent
              ? _generate
              : null,
          child: Text(_busy ? t.common.cancel : t.common.preview),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        for (var i = 0; i < _matches.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_matches[i].proposal.title, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${_matches[i].proposal.artist}${_matches[i].candidates.isEmpty ? ' · ${t.musicTools.missing}' : ''}',
                ),
                if (_matches[i].candidates.isNotEmpty)
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _selected[i]?.globalKey ?? '',
                    items: [
                      DropdownMenuItem(value: '', child: Text(t.musicExperience.remove)),
                      for (final item in _matches[i].candidates)
                        DropdownMenuItem(
                          value: item.globalKey,
                          child: Text(
                            '${item.albumTitle ?? item.displayTitle} · ${item.serverName ?? item.serverId}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) => setState(() {
                            _selected.remove(i);
                            for (final item in _matches[i].candidates) {
                              if (item.globalKey == id) _selected[i] = item;
                            }
                          }),
                  ),
                Row(
                  children: [
                    IconButton(
                      tooltip: t.fileSources.moveUp,
                      icon: const AppIcon(Symbols.arrow_upward_rounded),
                      onPressed: _busy || i == 0 ? null : () => _move(i, i - 1),
                    ),
                    IconButton(
                      tooltip: t.fileSources.moveDown,
                      icon: const AppIcon(Symbols.arrow_downward_rounded),
                      onPressed: _busy || i == _matches.length - 1 ? null : () => _move(i, i + 1),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: _tracks.isEmpty
                  ? null
                  : () => _experience.music.playFromList(
                      tracks: _tracks,
                      playContext: MusicPlayContext(
                        title: _title.text.trim().isEmpty ? t.musicTools.prompt : _title.text.trim(),
                        kind: MusicPlayContextKind.playlist,
                      ),
                    ),
              child: Text(t.common.play),
            ),
            FilledButton.tonal(
              onPressed: _busy || _tracks.isEmpty || _title.text.trim().isEmpty ? null : _save,
              child: Text(t.musicExperience.savePlaylist),
            ),
          ],
        ),
      ],
    ),
  );
}
