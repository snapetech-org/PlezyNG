import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_font_store.dart';
import '../../../services/subtitle_portable_defaults.dart';
import '../../../services/subtitle_selection_rules.dart';
import 'subtitle_defaults_cloud_dialog.dart';
import 'subtitle_review_data_dialog.dart';

class SubtitleDefaultsDialog extends StatefulWidget {
  const SubtitleDefaultsDialog({super.key});
  @override
  State<SubtitleDefaultsDialog> createState() => _SubtitleDefaultsDialogState();
}

class _SubtitleDefaultsDialogState extends State<SubtitleDefaultsDialog> {
  ActiveProfileProvider? _profiles;
  String? _profile, _error, _message;
  bool _initialized = false, _busy = true;
  SubtitlePortableDefaults? _currentDefaults, _incoming;
  SubtitleDefaultsCloudReview? _cloudReview;
  bool get _current => mounted && _profile != null && _profiles?.activeId == _profile;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _profiles = context.read<ActiveProfileProvider>(); _profile = _profiles!.activeId;
    SubtitleSelectionRules.bindProfile(_profiles!);
    _run(() async {
      await SettingsService.getInstance();
      try { await SubtitleFontStore.instance.initialize(); } catch (_) { /* Missing fonts stay visible. */ }
      _capture();
    });
  }

  void _check() { if (!_current) throw StateError('The active profile changed. Reopen caption defaults.'); }
  void _capture() { _check(); _currentDefaults = SubtitlePortableDefaults.capture(_profile!, () => _current); }
  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() { _busy = true; _error = null; _message = null; });
    try { await action(); }
    catch (error) {
      final cloudCopy = mounted ? Translations.of(context).videoControls.subtitleDefaultsCloud : null;
      final copy = mounted ? Translations.of(context).videoControls.subtitleDefaultsTransfer : null;
      if (mounted) _error = error is StateError && error.message == 'New subtitle choices arrived; pull and review them before resolving'
          ? cloudCopy!.concurrentChanged
          : error is StateError && error.message == 'The active profile changed. Reopen caption defaults.'
              ? copy!.profileChanged : error is FormatException ? copy!.invalidFile : copy!.operationFailed;
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _export() => _run(() async {
    _capture();
    final bytes = _currentDefaults!.encode();
    final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.caption-defaults.json', bytes: bytes,
      type: FileType.custom, allowedExtensions: ['json']);
    if (path == null) return;
    _check();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) await File(path).writeAsBytes(bytes, flush: true);
    _message = Translations.of(context).videoControls.subtitleDefaultsTransfer.saved;
  });

  Future<void> _preview() => _run(() async {
    final copy = Translations.of(context).videoControls.subtitleDefaultsTransfer;
    _check();
    final chosen = await FilePickerService.instance.pickFiles(type: FileType.custom,
      allowedExtensions: ['json'], withReadStream: true);
    if (chosen == null) return;
    _check();
    _incoming = null;
    _cloudReview = null;
    if (chosen.files.length != 1 || chosen.files.single.size > SubtitlePortableDefaults.maximumBytes) {
      throw FormatException(copy.chooseFile);
    }
    final selected = chosen.files.single;
    final stream = selected.readStream ?? (selected.path == null ? null : File(selected.path!).openRead());
    if (stream == null) throw StateError(copy.fileUnreadable);
    final bytes = BytesBuilder(copy: false), elapsed = Stopwatch()..start();
    await for (final chunk in stream.timeout(const Duration(seconds: 10))) {
      _check();
      if (elapsed.elapsedMilliseconds > 20000 || bytes.length + chunk.length > SubtitlePortableDefaults.maximumBytes) {
        throw FormatException(copy.readLimitExceeded);
      }
      bytes.add(chunk);
    }
    _incoming = SubtitlePortableDefaults.decode(bytes.takeBytes());
    _capture();
    _message = copy.previewLoaded;
  });

  Future<void> _cloud() => _run(() async {
    final copy = Translations.of(context).videoControls.subtitleDefaultsCloud;
    _check();
    final review = await showDialog<SubtitleDefaultsCloudReview>(context: context,
      builder: (_) => SubtitleDefaultsCloudDialog(profileId: _profile!, isCurrent: () => _current));
    if (review == null) return;
    _check(); _incoming = review.defaults; _cloudReview = review; _capture();
    _message = copy.previewLoaded;
  });

  Future<void> _chooseShared() => _run(() async {
    final copy = Translations.of(context).videoControls.subtitleDefaultsCloud;
    _check(); final review = _cloudReview;
    if (review == null) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(copy.useSharedTitle),
      content: Text(copy.useSharedBody), actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(Translations.of(context).common.cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(copy.useSharedConfirm))]));
    if (confirmed != true) return;
    _check(); final choices = await review.chooseShared();
    _cloudReview = null;
    _message = choices.length > 1 ? copy.concurrentChanged : copy.sharedChoicePublished;
  });

  Future<void> _import(int? lane) => _run(() async {
    final copy = Translations.of(context).videoControls.subtitleDefaultsTransfer;
    _check();
    final incoming = _incoming, expected = _currentDefaults;
    if (incoming == null || expected == null) return;
    if (lane == null) {
      await incoming.importRoles(profile: _profile!, isCurrent: () => _current, expected: expected);
    } else {
      await incoming.importLane(lane, profile: _profile!, isCurrent: () => _current, expected: expected);
    }
    _capture();
    _message = lane == null ? copy.importedRoles : copy.importedLane(lane: lane + 1);
  });

  String _value(String key, Object value) {
    final controls = Translations.of(context).videoControls;
    final copy = controls.subtitleDefaultsTransfer;
    if (const {'color', 'outline', 'backgroundColor'}.contains(key) && value is int) {
      return '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
    }
    if (const {'position', 'backgroundOpacity', 'margin', 'overscan'}.contains(key) && value is num) {
      return '${(value * 100).toStringAsFixed(1)}%';
    }
    if (value is bool) return value ? copy.enabled : copy.disabled;
    if (key == 'fontFamily') return SubtitleFontStore.instance.label(value.toString());
    if (key == 'alignment') return switch (value.toString()) {
      'left' => controls.subtitleOverlays.alignmentStart,
      'start' => controls.subtitleOverlays.alignmentStart,
      'center' => controls.subtitleOverlays.alignmentCenter,
      'right' => controls.subtitleOverlays.alignmentEnd,
      'end' => controls.subtitleOverlays.alignmentEnd,
      _ => value.toString(),
    };
    if (key == 'writingMode') return switch (value) {
      'vertical-lr' => copy.verticalLr, 'vertical-rl' => copy.verticalRl, _ => copy.horizontal};
    return value.toString();
  }

  String _roles(SubtitleRoleRules value) {
    final copy = Translations.of(context).videoControls.subtitleRoles;
    final forced = switch (value.forced) {
      SubtitleForcedRule.any => copy.anyRole, SubtitleForcedRule.full => copy.excludeForcedOnly,
      SubtitleForcedRule.forced => copy.forcedOnly};
    final accessibility = switch (value.accessibility) {
      SubtitleAccessRule.any => copy.noPreference, SubtitleAccessRule.prefer => copy.preferSdh,
      SubtitleAccessRule.avoid => copy.avoidSdh};
    return '$forced · $accessibility';
  }

  Widget _cell(String key, Object value) => Row(mainAxisSize: MainAxisSize.min, children: [
    if (const {'color', 'outline', 'backgroundColor'}.contains(key) && value is int) ...[
      Container(width: 18, height: 18, decoration: BoxDecoration(color: Color(value), border: Border.all(color: Colors.grey))),
      const SizedBox(width: 6),
    ],
    Text(_value(key, value)),
  ]);

  @override
  Widget build(BuildContext context) {
    final incoming = _incoming, current = _currentDefaults;
    final copy = Translations.of(context).videoControls.subtitleDefaultsTransfer;
    final names = {'fontSize': copy.fontSize, 'position': copy.position, 'backgroundOpacity': copy.backgroundOpacity,
      'color': copy.textColor, 'outline': copy.outlineColor, 'outlineWidth': copy.outlineWidth,
      'margin': copy.margin, 'karaoke': copy.wordHighlighting, 'ruby': copy.rubyReadings, 'bold': copy.bold, 'italic': copy.italic,
      'videoAnchored': copy.anchorToVideo, 'overscan': copy.overscanInset, 'writingMode': copy.writingDirection,
      'backgroundColor': copy.backgroundColor, 'fontFamily': copy.font, 'alignment': copy.alignment};
    return PopScope(canPop: !_busy, child: AlertDialog(title: Text(copy.title),
      content: SizedBox(width: 660, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(copy.description),
        Text(copy.privacy),
        TextButton(onPressed: _busy || !_current ? null : () => showDialog<void>(context: context,
          builder: (_) => const SubtitleReviewDataDialog()), child: Text(t.videoSettings.subtitleReviewData)),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: _busy || !_current || current == null ? null : _export, child: Text(copy.exportAction)),
          TextButton(onPressed: _busy || !_current ? null : _preview, child: Text(copy.openPreview)),
          TextButton(onPressed: _busy || !_current ? null : _cloud,
            child: Text(Translations.of(context).videoControls.subtitleDefaultsCloud.shareAction)),
          if (incoming != null) TextButton(onPressed: _busy || !_current ? null : () => _run(() async { _capture(); }),
            child: Text(copy.refreshCurrent)),
        ]),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_message != null) Text(_message!),
        if (incoming != null && current != null) ...[
          for (var lane = 0; lane < 2; lane++) Card(child: ExpansionTile(title: Text(copy.laneAppearance(lane: lane + 1)), children: [
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columns: [
              DataColumn(label: Text(copy.settingColumn)), DataColumn(label: Text(copy.currentColumn)), DataColumn(label: Text(copy.incomingColumn))],
              rows: [for (final entry in incoming.lanes[lane].entries) DataRow(cells: [
                DataCell(Text(names[entry.key] ?? entry.key)), DataCell(_cell(entry.key, current.lanes[lane][entry.key]!)),
                DataCell(_cell(entry.key, entry.value))])])),
            FilledButton(onPressed: _busy || !_current ? null : () => _import(lane), child: Text(copy.importLaneAction(lane: lane + 1))),
          ])),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(copy.profileRolesTitle), Text(copy.currentRoles(value: _roles(current.roles))), Text(copy.incomingRoles(value: _roles(incoming.roles))),
            FilledButton(onPressed: _busy || !_current ? null : () => _import(null), child: Text(copy.importRolesAction)),
          ]))),
          if (_cloudReview != null) TextButton(onPressed: _busy || !_current ? null : _chooseShared,
            child: Text(Translations.of(context).videoControls.subtitleDefaultsCloud.useSharedAction)),
        ],
      ]))), actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(Translations.of(context).common.close))]));
  }
}
