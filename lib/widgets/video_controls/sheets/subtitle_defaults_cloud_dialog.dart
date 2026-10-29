import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_cloud_sync.dart';
import '../../../services/subtitle_portable_defaults.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../sources/source_controller.dart';
import '../../../sources/sync/sync_document.dart';
import '../../../sources/sync/sync_store.dart';

class SubtitleDefaultsCloudReview {
  SubtitleDefaultsCloudReview({required this.defaults, required this.choice, required List<SubtitleSyncChoice> choices,
    required this.service, required this.code}) : choices = List.unmodifiable(choices);
  final SubtitlePortableDefaults defaults;
  final SubtitleSyncChoice choice;
  final List<SubtitleSyncChoice> choices;
  final SubtitleCloudSync service;
  final String code;

  Future<List<SubtitleSyncChoice>> chooseShared() async {
    service.check();
    if (await SubtitleCloudSync.pairedCode(service.repository, service.identity) != code) {
      throw StateError('The defaults pairing changed. Pull and preview again.');
    }
    service.check();
    return service.resolve(choice, observedChoices: choices);
  }
}

/// The caller owns preview/import. Pulling a shared preset only returns an
/// immutable value; neither local settings nor a shared winner changes here.
class SubtitleDefaultsCloudDialog extends StatefulWidget {
  const SubtitleDefaultsCloudDialog({super.key, required this.profileId, required this.isCurrent});
  final String profileId;
  final bool Function() isCurrent;
  @override
  State<SubtitleDefaultsCloudDialog> createState() => _SubtitleDefaultsCloudDialogState();
}

class _SubtitleDefaultsCloudDialogState extends State<SubtitleDefaultsCloudDialog> {
  final _code = TextEditingController();
  SourceController? _sources;
  int? _generation;
  String? _paired, _message, _error;
  bool _loaded = false, _busy = true, _reveal = false;
  List<SubtitleSyncChoice> _choices = [];
  SubtitleRevisionIdentity get _identity => SubtitleCloudSync.defaultsIdentity(widget.profileId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true; _sources = context.read<SourceController>(); _generation = _sources!.generation;
    _run(() async {
      await _sources!.ready; _check();
      _paired = await SubtitleCloudSync.pairedCode(_sources!.repository, _identity); _check();
      _code.text = _paired ?? '';
    });
  }
  @override
  void dispose() { _code.dispose(); super.dispose(); }
  void _check() {
    if (!mounted || !widget.isCurrent() || _sources?.profileId != widget.profileId) {
      throw StateError('The defaults profile changed. Reopen this dialog.');
    }
    _sources!.requireSession(_generation);
  }
  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() { _busy = true; _error = null; _message = null; });
    try { await action(); }
    catch (error) {
      if (mounted) _error = error is StateError ? error.message : error is FormatException ? error.message
          : 'Defaults synchronization failed. Check the pairing code, cloud account, folder and network.';
    } finally { if (mounted) setState(() => _busy = false); }
  }
  SubtitleCloudSync _service() {
    _check();
    final sources = _sources!, config = _sources!.syncConfig, generation = _generation;
    if (config == null) throw StateError('Configure a cloud sync account and folder in Sources → Sync first.');
    final code = _paired;
    if (code == null || code != _code.text.trim()) throw StateError('Save this profile’s defaults pairing first.');
    final adapter = sources.adapter(config.sourceId), ownerCurrent = widget.isCurrent, profile = widget.profileId;
    if (!ProviderSyncStore.supports(adapter.source.kind)) throw StateError('Choose a supported cloud sync source.');
    // The parent owns the returned review after this picker closes. Capture
    // stable values instead of retaining this disposed dialog as the owner.
    void current() {
      if (!ownerCurrent() || sources.profileId != profile || sources.syncConfig?.sourceId != config.sourceId ||
          sources.syncConfig?.folder != config.folder) throw StateError('The defaults sync destination changed.');
      sources.requireSession(generation);
    }
    return SubtitleCloudSync(repository: sources.repository, identity: _identity, defaults: true,
      store: ProviderSyncStore(adapter, folder: config.folder, check: current), code: code, check: current);
  }
  Future<bool> _confirm(String title, String message, String action) async {
    final result = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: Text(title),
      content: Text(message), actions: [TextButton(onPressed: () => Navigator.pop(context, false),
        child: Text(Translations.of(context).common.cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action))]));
    _check(); return result == true;
  }
  Future<void> _pair() => _run(() async {
    _check(); final code = _code.text.trim(); SyncCipher(code);
    if (!await _confirm('Pair caption defaults?', 'Use the same defaults code and cloud folder on your other device. '
        'Anyone with this code and folder access can read and publish these preferences. Keep a private recovery copy. '
        'Saving a code does not upload or apply settings.', 'Save pairing')) return;
    await SubtitleCloudSync.pair(_sources!.repository, _identity, code); _check();
    _paired = code; _choices = []; _message = 'Defaults paired. No settings were uploaded or applied.';
  });
  Future<void> _sync({bool publish = false}) => _run(() async {
    final service = _service();
    SubtitlePortableDefaults? defaults;
    if (publish) {
      defaults = SubtitlePortableDefaults.capture(widget.profileId, widget.isCurrent);
      if (!await _confirm('Publish saved caption defaults?', 'Write encrypted appearance and role defaults to your configured cloud folder? '
          'This includes both saved lanes and the profile’s default forced/SDH preferences. Captions, fonts, accounts, title overrides and '
          'timing corrections are excluded. Concurrent versions remain available for explicit choice; older encrypted blobs remain for recovery.', 'Publish')) return;
    }
    _choices = await service.synchronize(publishDefaults: defaults); _check();
    _message = _choices.isEmpty ? 'No defaults are shared yet.' : '${_choices.length} shared version(s). Open one for field-by-field review.';
  });
  Future<void> _preview(SubtitleSyncChoice choice) => _run(() async {
    final service = _service(), code = _paired!;
    final defaults = await service.downloadDefaults(choice); _check();
    Navigator.pop(context, SubtitleDefaultsCloudReview(defaults: defaults, choice: choice,
      choices: _choices, service: service, code: code));
  });

  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: AlertDialog(title: const Text('Share caption defaults'),
    content: SizedBox(width: 580, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Uses the configured Sources cloud account and folder. Defaults have a separate encrypted namespace from subtitle tracks. '
        'Pull, publish and import are explicit; local settings never change just because another device publishes.'),
      TextField(controller: _code, enabled: !_busy, obscureText: !_reveal, autocorrect: false, enableSuggestions: false,
        onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: 'Defaults pairing code',
          suffixIcon: IconButton(onPressed: () => setState(() => _reveal = !_reveal),
            icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: _busy ? null : () => setState(() => _code.text = SyncCipher.newCode()), child: const Text('New defaults code')),
        TextButton(onPressed: _busy || _code.text.isEmpty ? null : () => _run(() async {
          _check(); await Clipboard.setData(ClipboardData(text: _code.text.trim()));
          _message = 'Pairing code copied. Other apps may have clipboard access.';
        }), child: const Text('Copy code')),
        TextButton(onPressed: _busy ? null : _pair, child: const Text('Save pairing')),
        TextButton(onPressed: _busy || _paired == null ? null : () => _run(() async {
          _check(); await SubtitleCloudSync.pair(_sources!.repository, _identity, null); _check();
          _paired = null; _choices = []; _code.clear(); _message = 'Disconnected locally. Cloud versions and local settings were retained.';
        }), child: const Text('Disconnect defaults')),
      ]),
      Wrap(spacing: 8, children: [
        FilledButton(onPressed: _busy || _paired == null ? null : () => _sync(), child: const Text('Pull shared defaults')),
        OutlinedButton(onPressed: _busy || _paired == null ? null : () => _sync(publish: true), child: const Text('Publish saved defaults')),
      ]),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_message != null) Text(_message!),
      for (final choice in _choices) ListTile(title: Text('Device ${choice.device} · ${(choice.bytes / 1024).ceil()} KiB'),
        subtitle: Text(choice.digest.substring(0, 12)), trailing: TextButton(onPressed: _busy ? null : () => _preview(choice),
          child: const Text('Open for preview'))),
    ]))), actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context),
      child: Text(Translations.of(context).common.close))]));
}
