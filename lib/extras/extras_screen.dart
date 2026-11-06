import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../services/file_picker_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../i18n/strings.g.dart';
import '../services/subtitle_retimer.dart';
import '../widgets/app_icon.dart';
import '../widgets/focusable_list_tile.dart';
import 'extras_ai.dart';
import 'extras_labels.dart';
import 'extras_models.dart';
import 'extras_playback.dart';
import 'extras_policy.dart';
import 'extras_repository.dart';
import 'extras_session.dart';

Future<void> openExtras(BuildContext context, ExtrasSession session) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ExtrasScreen(session: session)));

class ExtrasScreen extends StatefulWidget {
  const ExtrasScreen({super.key, required this.session});
  final ExtrasSession session;
  @override
  State<ExtrasScreen> createState() => _ExtrasScreenState();
}

class _ExtrasScreenState extends State<ExtrasScreen> {
  final _query = TextEditingController();
  final _ai = ExtrasAi();
  ExtraKind? _kind;
  ExtrasAiResult _answer = const ExtrasAiResult();
  bool _searching = false;
  int _generation = 0;
  ExtrasSession get session => widget.session;
  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _ai.close();
    super.dispose();
  }

  Future<void> _search() async {
    if (!widget.session.active) return;
    final generation = ++_generation;
    setState(() => _searching = true);
    final entries = await _withTranscripts(session.entries);
    final answer = await _ai.search(
      _query.text,
      entries,
      session.preferences,
      token: await _aiToken(),
      restricted: session.subject.restricted,
      offline: session.subject.offline,
    );
    if (mounted && generation == _generation) {
      setState(() {
        _answer = answer;
        _searching = false;
      });
    }
  }

  Future<List<ExtraEntry>> _withTranscripts(List<ExtraEntry> entries) async => [
    for (final entry in entries) await _withTranscript(entry),
  ];
  Future<ExtraEntry> _withTranscript(ExtraEntry entry) async {
    final imported = await session.store.transcript(entry.id);
    return imported == null ? entry : entry.withPassages(imported, userSupplied: true);
  }

  Future<String> _aiToken() async {
    try {
      return await session.store.secret('ai');
    } catch (_) {
      return '';
    }
  }

  Future<void> _settings() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ExtrasSettingsScreen(session: session)));
    if (mounted) {
      setState(() => _answer = const ExtrasAiResult());
      await session.refresh();
    }
  }

  Future<void> _add() async {
    final title = TextEditingController(), url = TextEditingController();
    String? error;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t.bonusExtras.addLink),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: InputDecoration(labelText: t.bonusExtras.linkTitle),
                  ),
                  TextField(
                    controller: url,
                    maxLength: 2000,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(labelText: t.bonusExtras.linkUrl),
                  ),
                  if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.bonusExtras.cancel)),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty || canonicalExtraUrl(Uri.tryParse(url.text.trim())) == null) {
                  update(() => error = t.bonusExtras.invalidLink);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(t.bonusExtras.save),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && session.active) {
      final uri = canonicalExtraUrl(Uri.parse(url.text.trim()))!;
      await session.store.add(
        ExtraEntry(
          id: 'personal:${sha256.convert(utf8.encode('${session.subject.key}|$uri'))}',
          parentIdentities: session.subject.allIdentities,
          title: title.text.trim(),
          kind: ExtraKind.other,
          origin: ExtraOrigin.user,
          url: uri,
        ),
      );
      await session.refresh();
    }
    title.dispose();
    url.dispose();
  }

  Future<void> _action(ExtraEntry entry, String action) async {
    if (!session.active) return;
    if (action == 'transcript') {
      await _transcript(entry);
      return;
    }
    if (action == 'completed') {
      await session.store.recordProgress(entry.id, completed: true);
      if (mounted) setState(() {});
      return;
    }
    if (action == 'remove') {
      await session.store.removePersonal(entry.id);
    } else {
      await session.store.exclude(session.subject, entry, action);
    }
    await session.refresh();
  }

  List<PopupMenuEntry<String>> _menu(ExtraEntry entry) => [
    PopupMenuItem(value: 'hide', child: Text(t.bonusExtras.hide)),
    PopupMenuItem(value: 'wrong', child: Text(t.bonusExtras.wrongTitle)),
    if (entry.publisherId.isNotEmpty && !entry.isLibrary)
      PopupMenuItem(value: 'publisher', child: Text(t.bonusExtras.hidePublisher)),
    if (entry.origin == ExtraOrigin.user) PopupMenuItem(value: 'remove', child: Text(t.bonusExtras.remove)),
    PopupMenuItem(value: 'transcript', child: Text(t.bonusExtras.transcript)),
    PopupMenuItem(value: 'completed', child: Text(t.bonusExtras.markCompleted)),
  ];
  Future<void> _longPress(ExtraEntry entry) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(entry.title),
        children: [
          for (final option in _menu(entry))
            if (option is PopupMenuItem<String>)
              SimpleDialogOption(onPressed: () => Navigator.pop(context, option.value), child: option.child),
        ],
      ),
    );
    if (result != null) await _action(entry, result);
  }

  Future<void> _transcript(ExtraEntry entry) async {
    final imported = await session.store.transcript(entry.id);
    final passages = imported ?? (entry.analysisAllowed ? entry.passages : <ExtraPassage>[]);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ExtraTranscriptScreen(
          session: session,
          entry: entry.withPassages(passages, userSupplied: imported != null),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final filtered = session.entries
          .where(
            (entry) =>
                (_kind == null || entry.kind == _kind) &&
                (extraMatchesQuery(entry, _query.text) ||
                    _answer.kinds.contains(entry.kind) ||
                    _answer.passages.containsKey(entry.id)),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(t.bonusExtras.title),
          actions: [
            IconButton(
              tooltip: t.bonusExtras.settings,
              onPressed: _settings,
              icon: const AppIcon(Symbols.settings_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(session.subject.title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _query,
                    onChanged: (_) => setState(() {
                      _generation++;
                      _answer = const ExtrasAiResult();
                      _searching = false;
                    }),
                    onSubmitted: (_) => unawaited(_search()),
                    decoration: InputDecoration(
                      labelText: t.bonusExtras.search,
                      suffixIcon: IconButton(
                        tooltip: t.bonusExtras.searchAction,
                        onPressed: _searching ? null : _search,
                        icon: const AppIcon(Symbols.search_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        label: Text(t.bonusExtras.all),
                        selected: _kind == null,
                        onSelected: (_) => setState(() => _kind = null),
                      ),
                      for (final kind in ExtraKind.values.where((k) => session.entries.any((e) => e.kind == k)))
                        FilterChip(
                          label: Text(extraKindLabel(kind)),
                          selected: _kind == kind,
                          onSelected: (_) => setState(() => _kind = _kind == kind ? null : kind),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (session.loading || _searching) const LinearProgressIndicator(),
                  if (session.unavailable)
                    Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t.bonusExtras.partial)),
                  if (session.subject.restricted) Text(t.bonusExtras.restricted),
                  if (filtered.isEmpty && !session.loading)
                    Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text(t.bonusExtras.empty)),
                  for (final entry in filtered)
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FocusableListTile(
                            dense: false,
                            visualDensity: VisualDensity.standard,
                            title: Text(entry.title),
                            subtitle: Text(
                              [
                                extraSourceLabel(entry),
                                extraKindLabel(entry.kind),
                                if (entry.scopeLabel.isNotEmpty) entry.scopeLabel,
                                if (entry.durationSeconds != null)
                                  '${entry.durationSeconds! ~/ 60}:${(entry.durationSeconds! % 60).toString().padLeft(2, '0')}',
                                entry.language.isEmpty ? t.bonusExtras.unknownLanguage : entry.language,
                              ].join(' · '),
                            ),
                            leading: const AppIcon(Symbols.play_circle_rounded),
                            onTap: () => unawaited(playExtra(context, session, entry)),
                            onLongPress: () => unawaited(_longPress(entry)),
                            trailing: PopupMenuButton<String>(
                              tooltip: t.common.options,
                              itemBuilder: (_) => _menu(entry),
                              onSelected: (action) => unawaited(_action(entry, action)),
                            ),
                          ),
                          for (final passage in _answer.passages[entry.id] ?? const <ExtraPassage>[])
                            FocusableListTile(
                              title: Text(passage.text),
                              subtitle: Text(
                                '${passage.startSeconds ~/ 60}:${(passage.startSeconds % 60).toString().padLeft(2, '0')}',
                              ),
                              onTap: () => unawaited(playExtra(context, session, entry, seconds: passage.startSeconds)),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (!session.subject.restricted && !session.subject.offline)
                        OutlinedButton(
                          onPressed: session.loading ? null : () => session.refresh(findMore: true, query: _query.text),
                          child: Text(t.bonusExtras.findMore),
                        ),
                      if (!session.subject.restricted) TextButton(onPressed: _add, child: Text(t.bonusExtras.addLink)),
                      TextButton(onPressed: _settings, child: Text(t.bonusExtras.settings)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class ExtrasSettingsScreen extends StatefulWidget {
  const ExtrasSettingsScreen({super.key, required this.session});
  final ExtrasSession session;
  @override
  State<ExtrasSettingsScreen> createState() => _ExtrasSettingsScreenState();
}

class _ExtrasSettingsScreenState extends State<ExtrasSettingsScreen> {
  late ExtrasPreferences _prefs;
  late final TextEditingController _service, _aiUrl, _model;
  final _discoveryToken = TextEditingController(), _aiToken = TextEditingController();
  bool _saving = false, _secretsLoaded = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _prefs = widget.session.preferences;
    _service = TextEditingController(text: _prefs.serviceUrl);
    _aiUrl = TextEditingController(text: _prefs.aiUrl);
    _model = TextEditingController(text: _prefs.aiModel);
    unawaited(_loadSecrets());
  }

  Future<void> _loadSecrets() async {
    try {
      final discovery = await widget.session.store.secret('discovery'), ai = await widget.session.store.secret('ai');
      if (!mounted) return;
      _discoveryToken.text = discovery;
      _aiToken.text = ai;
      setState(() => _secretsLoaded = true);
    } catch (_) {
      if (mounted) setState(() => _error = t.bonusExtras.failed);
    }
  }

  @override
  void dispose() {
    for (final c in [_service, _aiUrl, _model, _discoveryToken, _aiToken]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!widget.session.active) return;
    final endpoint = extrasServiceUri(_aiUrl.text, deviceOnly: _prefs.aiMode == ExtrasAiMode.device);
    if ((_service.text.trim().isNotEmpty && extrasServiceUri(_service.text) == null) ||
        (_prefs.aiMode != ExtrasAiMode.off &&
            (endpoint == null ||
                _model.text.trim().isEmpty ||
                (_prefs.aiMode == ExtrasAiMode.cloud && endpoint.scheme != 'https')))) {
      setState(() => _error = t.bonusExtras.invalidSettings);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.store.saveSecrets(discovery: _discoveryToken.text.trim(), ai: _aiToken.text.trim());
      await widget.session.store.savePreferences(
        _prefs.copyWith(serviceUrl: _service.text.trim(), aiUrl: _aiUrl.text.trim(), aiModel: _model.text.trim()),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = t.bonusExtras.failed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.bonusExtras.settings)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SwitchListTile(
                title: Text(t.bonusExtras.externalEnabled),
                value: _prefs.externalEnabled,
                onChanged: widget.session.subject.restricted
                    ? null
                    : (v) => setState(() => _prefs = _prefs.copyWith(externalEnabled: v)),
              ),
              SwitchListTile(
                title: Text(t.bonusExtras.includeAnalysis),
                value: _prefs.includeAnalysis,
                onChanged: (v) => setState(() => _prefs = _prefs.copyWith(includeAnalysis: v)),
              ),
              SwitchListTile(
                title: Text(t.bonusExtras.spoilers),
                subtitle: Text(t.bonusExtras.spoilerHint),
                value: _prefs.showSpoilers,
                onChanged: (v) => setState(() => _prefs = _prefs.copyWith(showSpoilers: v)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _service,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(labelText: t.bonusExtras.serviceUrl),
              ),
              TextField(
                controller: _discoveryToken,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: t.bonusExtras.serviceToken),
              ),
              const SizedBox(height: 24),
              DropdownButtonFormField<ExtrasAiMode>(
                initialValue: _prefs.aiMode,
                isExpanded: true,
                decoration: InputDecoration(labelText: t.bonusExtras.aiMode),
                items: [
                  for (final mode in ExtrasAiMode.values)
                    DropdownMenuItem(value: mode, child: Text(extrasAiLabel(mode))),
                ],
                onChanged: widget.session.subject.restricted
                    ? null
                    : (mode) {
                        if (mode != null) setState(() => _prefs = _prefs.copyWith(aiMode: mode));
                      },
              ),
              const SizedBox(height: 12),
              Text(t.bonusExtras.aiNotice),
              if (_prefs.aiMode == ExtrasAiMode.device)
                Padding(padding: const EdgeInsets.only(top: 12), child: Text(t.bonusExtras.deviceNotice)),
              if (_prefs.aiMode != ExtrasAiMode.off) ...[
                TextField(
                  controller: _aiUrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: t.bonusExtras.aiUrl),
                ),
                TextField(
                  controller: _model,
                  decoration: InputDecoration(labelText: t.bonusExtras.aiModel),
                ),
                TextField(
                  controller: _aiToken,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: t.bonusExtras.aiToken),
                ),
              ],
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () =>
                    setState(() => _prefs = _prefs.copyWith(hiddenIds: {}, hiddenPublishers: {}, wrongMatches: {})),
                child: Text(t.bonusExtras.showHidden),
              ),
              TextButton(onPressed: () => widget.session.store.clearCache(), child: Text(t.bonusExtras.clearCache)),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              FilledButton(onPressed: _saving || !_secretsLoaded ? null : _save, child: Text(t.bonusExtras.save)),
            ],
          ),
        ),
      ),
    ),
  );
}

class ExtraTranscriptScreen extends StatefulWidget {
  const ExtraTranscriptScreen({super.key, required this.session, required this.entry});
  final ExtrasSession session;
  final ExtraEntry entry;
  @override
  State<ExtraTranscriptScreen> createState() => _ExtraTranscriptScreenState();
}

class _ExtraTranscriptScreenState extends State<ExtraTranscriptScreen> {
  late ExtraEntry _entry;
  final _query = TextEditingController(), _ai = ExtrasAi();
  List<ExtraPassage> _matches = [];
  bool _busy = false;
  int _generation = 0;
  String? _notice;
  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    _matches = searchExtraPassages(_entry, '');
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _ai.close();
    super.dispose();
  }

  Future<void> _import() async {
    try {
      final result = await FilePickerService.instance.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt'],
        withData: true,
      );
      final file = result?.files.single;
      if (file == null) return;
      if (file.size > 512 * 1024 || file.bytes == null) throw const FormatException('Invalid transcript size');
      final cues = SubtitleRetimer.parseCues(sourceBytes: file.bytes!, extension: '.${file.extension}');
      final passages = cues
          .take(500)
          .where((c) => c.endMs > c.startMs && c.text.length <= 2000)
          .map((c) => ExtraPassage(startSeconds: c.startMs ~/ 1000, endSeconds: (c.endMs / 1000).ceil(), text: c.text))
          .toList();
      if (passages.isEmpty) throw const FormatException('No transcript cues');
      await widget.session.store.saveTranscript(_entry.id, passages);
      if (mounted) {
        setState(() {
          _entry = _entry.withPassages(passages, userSupplied: true);
          _matches = searchExtraPassages(_entry, _query.text);
          _notice = t.bonusExtras.transcriptImported;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _notice = t.bonusExtras.invalidTranscript);
    }
  }

  Future<String> _token() async {
    try {
      return await widget.session.store.secret('ai');
    } catch (_) {
      return '';
    }
  }

  Future<void> _search() async {
    if (!widget.session.active) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final result = await _ai.search(
      _query.text,
      [_entry],
      widget.session.preferences,
      token: await _token(),
      restricted: widget.session.subject.restricted,
      offline: widget.session.subject.offline,
    );
    if (mounted && generation == _generation) {
      setState(() {
        _busy = false;
        _matches = result.passages[_entry.id] ?? searchExtraPassages(_entry, _query.text);
        if (!result.usedAi && widget.session.preferences.aiMode != ExtrasAiMode.off) _notice = t.bonusExtras.aiFallback;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.bonusExtras.transcript)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(_entry.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _query,
            onSubmitted: (_) => unawaited(_search()),
            onChanged: (q) => setState(() {
              _generation++;
              _busy = false;
              _matches = searchExtraPassages(_entry, q);
            }),
            decoration: InputDecoration(
              labelText: t.bonusExtras.search,
              suffixIcon: IconButton(
                tooltip: t.bonusExtras.searchAction,
                onPressed: _busy ? null : _search,
                icon: const AppIcon(Symbols.search_rounded),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_notice != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_notice!)),
          if (_entry.passages.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text(t.bonusExtras.noTranscript)),
          for (final p in _matches)
            FocusableListTile(
              dense: false,
              visualDensity: VisualDensity.standard,
              title: Text(p.text),
              subtitle: Text('${p.startSeconds ~/ 60}:${(p.startSeconds % 60).toString().padLeft(2, '0')}'),
              onTap: () => unawaited(playExtra(context, widget.session, _entry, seconds: p.startSeconds)),
            ),
          const SizedBox(height: 24),
          Text(t.bonusExtras.transcriptHint),
          OutlinedButton(onPressed: _import, child: Text(t.bonusExtras.importTranscript)),
        ],
      ),
    ),
  );
}
