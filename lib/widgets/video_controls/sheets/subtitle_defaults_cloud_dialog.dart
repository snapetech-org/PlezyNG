import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_cloud_sync.dart';
import '../../../services/subtitle_defaults_auto_sync.dart';
import '../../../services/subtitle_portable_defaults.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../sources/source_controller.dart';
import '../../../sources/sync/sync_document.dart';
import '../../../sources/sync/sync_store.dart';

class SubtitleDefaultsCloudReview {
  SubtitleDefaultsCloudReview({required this.defaults, required this.choice, required List<SubtitleSyncChoice> choices,
    required this.service, required this.code, required this.pairingChangedMessage}) : choices = List.unmodifiable(choices);
  final SubtitlePortableDefaults defaults;
  final SubtitleSyncChoice choice;
  final List<SubtitleSyncChoice> choices;
  final SubtitleCloudSync service;
  final String code;
  final String pairingChangedMessage;

  Future<List<SubtitleSyncChoice>> chooseShared() async {
    service.check();
    if (await SubtitleCloudSync.pairedCode(service.repository, service.identity) != code) {
      throw StateError(pairingChangedMessage);
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
  Translations$videoControls$subtitleDefaultsCloud$en get _copy =>
      Translations.of(context).videoControls.subtitleDefaultsCloud;

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
      throw StateError(_copy.profileChanged);
    }
    _sources!.requireSession(_generation);
  }
  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() { _busy = true; _error = null; _message = null; });
    try { await action(); }
    catch (error) {
      if (mounted) _error = error is SubtitleCloudSyncException ? error.message
          : error is StateError && error.message is String ? error.message as String : _copy.syncFailed;
    } finally { if (mounted) setState(() => _busy = false); }
  }
  SubtitleCloudSync _service() {
    _check();
    final sources = _sources!, config = _sources!.syncConfig, generation = _generation;
    if (config == null) throw StateError(_copy.configRequired);
    final code = _paired;
    if (code == null || code != _code.text.trim()) throw StateError(_copy.codeRequired);
    final adapter = sources.adapter(config.sourceId), ownerCurrent = widget.isCurrent, profile = widget.profileId;
    if (!ProviderSyncStore.supports(adapter.source.kind)) throw StateError(_copy.sourceRequired);
    // The parent owns the returned review after this picker closes. Capture
    // stable values instead of retaining this disposed dialog as the owner.
    void current() {
      if (!ownerCurrent() || sources.profileId != profile || sources.syncConfig?.sourceId != config.sourceId ||
          sources.syncConfig?.folder != config.folder) throw StateError(_copy.destinationChanged);
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
    final copy = _copy;
    _check(); final code = _code.text.trim(); SyncCipher(code);
    if (!await _confirm(copy.pairTitle, copy.pairBody, copy.savePairing)) return;
    if (_paired != code) {
      await context.read<SubtitleDefaultsAutoSync>().configure(false, profile: widget.profileId); _check();
    }
    await SubtitleCloudSync.pair(_sources!.repository, _identity, code); _check();
    _paired = code; _choices = []; _message = copy.pairedStatus;
  });
  Future<void> _sync({bool publish = false}) => _run(() async {
    final copy = _copy;
    final service = _service();
    SubtitlePortableDefaults? defaults;
    if (publish) {
      defaults = SubtitlePortableDefaults.capture(widget.profileId, widget.isCurrent);
      if (!await _confirm(copy.publishTitle, copy.publishBody, copy.publishConfirm)) return;
    }
    _choices = await service.synchronize(publishDefaults: defaults); _check();
    _message = _choices.isEmpty ? copy.noShared : copy.sharedCount(count: _choices.length);
  });
  Future<void> _preview(SubtitleSyncChoice choice) => _run(() async {
    final service = _service(), code = _paired!;
    final defaults = await service.downloadDefaults(choice); _check();
    Navigator.pop(context, SubtitleDefaultsCloudReview(defaults: defaults, choice: choice,
      choices: _choices, service: service, code: code, pairingChangedMessage: _copy.pairingChanged));
  });

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    final automatic = context.watch<SubtitleDefaultsAutoSync>();
    final autoCopy = Translations.of(context).videoSettings;
    final autoStatus = switch (automatic.state) {
      SubtitleDefaultsSyncState.off => autoCopy.subtitleDefaultsAutoOff,
      SubtitleDefaultsSyncState.waiting => autoCopy.subtitleDefaultsAutoWaiting,
      SubtitleDefaultsSyncState.running => autoCopy.subtitleDefaultsAutoRunning,
      SubtitleDefaultsSyncState.synchronized => autoCopy.subtitleDefaultsAutoSynced,
      SubtitleDefaultsSyncState.conflict => autoCopy.subtitleDefaultsAutoConflict,
      SubtitleDefaultsSyncState.unavailable => autoCopy.subtitleDefaultsAutoUnavailable,
    };
    return PopScope(canPop: !_busy, child: AlertDialog(title: Text(copy.title),
    content: SizedBox(width: 580, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(copy.description),
      TextField(controller: _code, enabled: !_busy, obscureText: !_reveal, autocorrect: false, enableSuggestions: false,
        onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: copy.codeLabel,
          suffixIcon: IconButton(onPressed: () => setState(() => _reveal = !_reveal),
            icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: _busy ? null : () => setState(() => _code.text = SyncCipher.newCode()), child: Text(copy.newCode)),
        TextButton(onPressed: _busy || _code.text.isEmpty ? null : () => _run(() async {
          _check(); await Clipboard.setData(ClipboardData(text: _code.text.trim()));
          _message = copy.codeCopied;
        }), child: Text(copy.copyCode)),
        TextButton(onPressed: _busy ? null : _pair, child: Text(copy.savePairing)),
        TextButton(onPressed: _busy || _paired == null ? null : () => _run(() async {
          _check(); await context.read<SubtitleDefaultsAutoSync>().configure(false, profile: widget.profileId); _check();
          await SubtitleCloudSync.pair(_sources!.repository, _identity, null); _check();
          _paired = null; _choices = []; _code.clear(); _message = copy.disconnectedStatus;
        }), child: Text(copy.disconnect)),
      ]),
      Wrap(spacing: 8, children: [
        FilledButton(onPressed: _busy || _paired == null ? null : () => _sync(), child: Text(copy.pullShared)),
        OutlinedButton(onPressed: _busy || _paired == null ? null : () => _sync(publish: true), child: Text(copy.publishSaved)),
      ]),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(autoCopy.subtitleDefaultsAuto),
        subtitle: Text(autoCopy.subtitleDefaultsAutoHelp), value: automatic.enabled,
        onChanged: _busy || _paired == null || _code.text.trim() != _paired ? null : (value) => _run(() async {
          _check(); await automatic.configure(value, profile: widget.profileId); _check();
        })),
      Text(autoStatus),
      TextButton(onPressed: _busy || !automatic.enabled ? null : automatic.refresh,
        child: Text(autoCopy.subtitleDefaultsAutoRefresh)),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_message != null) Text(_message!),
      for (final choice in _choices) ListTile(title: Text(copy.deviceVersion(device: choice.device, size: (choice.bytes / 1024).ceil())),
        subtitle: Text(choice.digest.substring(0, 12)), trailing: TextButton(onPressed: _busy ? null : () => _preview(choice),
          child: Text(copy.openPreview))),
    ]))), actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context),
      child: Text(Translations.of(context).common.close))]));
  }
}
