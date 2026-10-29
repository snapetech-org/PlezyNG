import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../../../i18n/strings.g.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_native_handoff_service.dart';
import '../../../services/subtitle_handoff_service.dart';
import '../../../mpv/mpv.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_speech_service.dart';
import '../../../services/speech_output_service.dart';
import '../../../services/subtitle_font_store.dart';
import '../../../services/subtitle_offline_package.dart';
import '../../../services/subtitle_download_assets.dart';
import '../../../services/subtitle_frame_export.dart';
import '../../../services/subtitle_analysis_source.dart';
import 'subtitle_fonts_dialog.dart';
import 'subtitle_hdr_dialog.dart';
import 'subtitle_defaults_dialog.dart';

Future<void> showSubtitleOverlayControls(BuildContext context, Player player, {
  SubtitleDownloadBinding? download,
  bool Function()? downloadIsCurrent,
  Future<void> Function()? onDownloadChanged,
  Future<SubtitleAnalysisSource> Function()? openAnalysisSource,
  bool Function()? isSourceCurrent,
}) async {
  try { await SubtitleFontStore.instance.initialize(); } catch (_) {}
  if (!context.mounted) return;
  final session = SubtitleOverlayService.forPlayer(player);
  var exportingPackage = false;
  await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleOverlays;
    void change(VoidCallback action) { update(action); session.changed(); }
    String alignmentLabel(TextAlign alignment) => switch (alignment) {
      TextAlign.start => copy.alignmentStart,
      TextAlign.center => copy.alignmentCenter,
      TextAlign.end => copy.alignmentEnd,
      _ => copy.alignmentStart,
    };
    return AlertDialog(title: Text(copy.title), content: SizedBox(width: 620,
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(copy.description),
        TextButton(onPressed: () => showDialog<void>(context: context, builder: (_) => const SubtitleDefaultsDialog()),
          child: const Text('Transfer saved caption defaults')),
        TextButton(onPressed: () async {
          await showDialog<void>(context: context, builder: (_) => SubtitleFontsDialog(
            openSource: openAnalysisSource, isSourceCurrent: isSourceCurrent));
          if (context.mounted) { update(() {}); session.changed(); }
        }, child: Text(copy.manageFonts)),
        for (var index = 0; index < 2; index++) if (session.lanes[index] case final SubtitleOverlayTrack track) ...[
          ListTile(title: Text(copy.laneTitle(lane: index + 1, title: track.title)), trailing: IconButton(tooltip: copy.removeOverlay,
            onPressed: () => change(() => session.lanes[index] = null), icon: const Icon(Icons.close))),
          if (SpeechOutputService.supported) TextButton(onPressed: () async {
            final speech = SubtitleSpeechService.instance;
            if (speech.isSpeaking(track)) { await speech.stop(); } else { await speech.start(player, track); }
            if (context.mounted) update(() {});
          }, child: Text(SubtitleSpeechService.instance.isSpeaking(track) ? copy.stopSpeaking : copy.speakOverlay)),
          DropdownButton<String>(value: SubtitleOverlayTrack.fonts.contains(track.fontFamily) ? track.fontFamily : 'Bundled multilingual', isExpanded: true,
            items: [for (final font in SubtitleOverlayTrack.fonts) DropdownMenuItem(value: font,
              child: Text(font == 'Bundled multilingual' ? copy.bundledFont : SubtitleFontStore.instance.label(font)))],
            onChanged: (font) { if (font != null) change(() => track.fontFamily = font); }),
          Text(copy.fontHelp),
          DropdownButton<String>(value: track.writingMode, isExpanded: true, items: [
            DropdownMenuItem(value: 'horizontal', child: Text(copy.horizontalText)),
            DropdownMenuItem(value: 'vertical-rl', child: Text(copy.verticalRightToLeft)),
            DropdownMenuItem(value: 'vertical-lr', child: Text(copy.verticalLeftToRight)),
          ], onChanged: (value) { if (value != null) change(() => track.writingMode = value); }),
          if (track.writingMode != 'horizontal') Text(copy.verticalHelp),
          SwitchListTile(title: Text(copy.rubyTitle),
            subtitle: Text(copy.rubyHelp),
            value: track.ruby, onChanged: (value) => change(() => track.ruby = value)),
          Wrap(spacing: 8, children: [for (final align in [TextAlign.start, TextAlign.center, TextAlign.end])
            ChoiceChip(label: Text(alignmentLabel(align)), selected: track.alignment == align,
              onSelected: (_) => change(() => track.alignment = align))]),
          if (track.profileId != null) TextButton(onPressed: () async {
            try { await track.saveAppearance(index);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.appearanceSaved)));
            } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.appearanceSaveFailed))); }
          }, child: Text(copy.saveAppearance)),
          if (track.positionToSourceMs != null) Text(copy.liveOverlayLimits),
          if (download != null && track.positionToSourceMs == null) TextButton(
            onPressed: exportingPackage ? null : () async {
              update(() => exportingPackage = true);
              try {
                if (!session.current || !session.lanes.contains(track)) throw StateError('Playback changed');
                await SubtitleDownloadAssets.save(download, index, track);
                await onDownloadChanged?.call();
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.retainedMessage)));
              } catch (_) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.retentionFailed)));
              } finally { if (context.mounted) update(() => exportingPackage = false); }
            }, child: Text(copy.keepLane)),
          if (track.positionToSourceMs == null) TextButton(onPressed: exportingPackage ? null : () async {
            update(() => exportingPackage = true);
            try {
              final snapshot = SubtitleNativeHandoffService.export(player, track);
              if (!context.mounted || !await _confirmSnapshot(context, snapshot.clipped, attach: false)) return;
              final package = await SubtitleOfflinePackage.create(player, track);
              if (!context.mounted) return;
              final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.captions.zip', bytes: package.bytes,
                type: FileType.custom, allowedExtensions: ['zip']);
              if (path != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) await File(path).writeAsBytes(package.bytes, flush: true);
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.exportPackageFailed)));
            } finally { if (context.mounted) update(() => exportingPackage = false); }
          }, child: Text(exportingPackage ? copy.preparingPackage : copy.exportPackage)),
          if (track.positionToSourceMs == null) Wrap(spacing: 8, children: [TextButton(onPressed: () async {
            try {
              final snapshot = SubtitleNativeHandoffService.export(player, track);
              if (!context.mounted || !await _confirmSnapshot(context, snapshot.clipped, attach: false)) return;
              final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.captions.srt', bytes: snapshot.bytes,
                type: FileType.custom, allowedExtensions: const ['srt']);
              if (path != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) await File(path).writeAsBytes(snapshot.bytes, flush: true);
            } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.exportSrtFailed))); }
          }, child: Text(copy.exportSrt)),
          if (player.supportedLocalSubtitleExtensions.contains('srt')) TextButton(onPressed: () async {
            try {
              final snapshot = SubtitleNativeHandoffService.export(player, track);
              if (!context.mounted || !await _confirmSnapshot(context, snapshot.clipped, attach: true)) return;
              await SubtitleNativeHandoffService.attach(player, track, allowClipping: true);
              if (context.mounted) update(() {});
            } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.nativeAttachFailed))); }
          }, child: Text(copy.moveSnapshotNative))]),
          if (track.avoidRegions.isNotEmpty) SwitchListTile(title: Text(copy.avoidRegions),
            subtitle: Text(copy.avoidRegionsHelp),
            value: track.avoidObjects, onChanged: (value) => change(() => track.avoidObjects = value)),
          Text(copy.fontSizeValue(size: track.fontSize.round())), Slider(value: track.fontSize, min: 16, max: 64,
            onChanged: (v) => change(() => track.fontSize = v)),
          SwitchListTile(title: Text(copy.anchorDialogue),
            subtitle: Text(copy.anchorHelp),
            value: track.videoAnchored, onChanged: (v) => change(() => track.videoAnchored = v)),
          Text(copy.safeInsetValue(percent: (track.overscan * 100).round())),
          Slider(value: track.overscan, min: 0, max: .15, onChanged: (v) => change(() => track.overscan = v)),
          Text(copy.verticalPositionValue(percent: (track.position * 100).round())), Slider(value: track.position, min: .05, max: .95,
            onChanged: (v) => change(() => track.position = v)),
          Text(copy.background), Slider(value: track.backgroundOpacity, min: 0, max: 1,
            onChanged: (v) => change(() => track.backgroundOpacity = v)),
          Wrap(spacing: 8, children: [for (final background in [Colors.black, const Color(0xff182332), const Color(0xff4a321c)])
            ChoiceChip(label: Text(copy.background, style: TextStyle(color: Colors.white, backgroundColor: background)), selected: track.backgroundColor == background,
              onSelected: (_) => change(() => track.backgroundColor = background))]),
          Text(copy.outline), Slider(value: track.outlineWidth, min: 0, max: 5,
            onChanged: (v) => change(() => track.outlineWidth = v)),
          Text(copy.sideMargin), Slider(value: track.margin, min: .02, max: .2,
            onChanged: (v) => change(() => track.margin = v)),
          Wrap(spacing: 8, children: [
            for (final color in [Colors.white, Colors.grey, Colors.amber, Colors.lightBlue, Colors.lightGreen])
              ChoiceChip(label: Text('Aa', style: TextStyle(color: color)), selected: track.color == color,
                onSelected: (_) => change(() => track.color = color)),
            FilterChip(label: Text(copy.bold), selected: track.bold, onSelected: (v) => change(() => track.bold = v)),
            FilterChip(label: Text(copy.italic), selected: track.italic, onSelected: (v) => change(() => track.italic = v)),
          ]),
          TextFormField(initialValue: '${track.delayMs}', decoration: InputDecoration(labelText: copy.laneDelay),
            keyboardType: const TextInputType.numberWithOptions(signed: true), onChanged: (v) {
              final delay = int.tryParse(v); if (delay != null && delay.abs() <= 3600000) change(() => track.delayMs = delay);
            }),
          SwitchListTile(title: Text(copy.highlightWords), subtitle: Text(copy.wordTimingHelp),
            value: track.karaoke, onChanged: track.words.isEmpty ? null : (v) => change(() => track.karaoke = v)),
        ],
        if (SpeechOutputService.supported) ...[
          Text(copy.speechHelp),
          Text(copy.speechRateValue(percent: (SubtitleSpeechService.instance.rate * 100).round())),
          Slider(value: SubtitleSpeechService.instance.rate, min: .1, max: 1,
            onChanged: (v) => update(() => SubtitleSpeechService.instance.rate = v)),
          Text(copy.audioDuckValue(percent: (SubtitleSpeechService.instance.duck * 100).round())),
          Slider(value: SubtitleSpeechService.instance.duck, min: 0, max: 1,
            onChanged: (v) => update(() => SubtitleSpeechService.instance.duck = v)),
        ],
        const Divider(),
        if (player.playerType == 'mpv') ...[
          TextButton(onPressed: () => showSubtitleHdrControls(context, player,
            () => session.current && isSourceCurrent?.call() != false),
            child: Text(t.videoControls.subtitleHdr.open)),
          Text(copy.exportFrameHelp),
          TextButton(onPressed: exportingPackage ? null : () async {
            update(() => exportingPackage = true);
            try {
              final capture = await SubtitleFrameExport.capture(player);
              if (!context.mounted) return;
              final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.caption-frame.${capture.extension}',
                bytes: capture.bytes, type: FileType.custom, allowedExtensions: [capture.extension]);
              if (path != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
                await File(path).writeAsBytes(capture.bytes, flush: true);
              }
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(copy.exportFrameFailed)));
            } finally { if (context.mounted) update(() => exportingPackage = false); }
          }, child: Text(copy.exportFrame)),
        ],
        if (download != null) ...[
          Text(copy.savedDownloadHelp),
          TextButton(onPressed: exportingPackage ? null : () async {
            update(() => exportingPackage = true);
            try {
              bool current() => session.current && downloadIsCurrent?.call() != false &&
                  player.timelineOffset.inMilliseconds == download.partOffsetMs;
              final restored = <SubtitleOverlayTrack?>[];
              for (var lane = 0; lane < 2; lane++) {
                restored.add(await SubtitleDownloadAssets.restore(download, lane, isCurrent: current));
              }
              if (!context.mounted || !current()) return;
              for (var lane = 0; lane < 2; lane++) {
                final track = restored[lane];
                if (track != null) SubtitleOverlayService.attach(player, lane, track, restoreAppearance: false);
              }
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(restored.every((track) => track == null)
                  ? copy.noRetainedCaptions : copy.restoredCaptions)));
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(copy.restoreFailed)));
            } finally { if (context.mounted) update(() => exportingPackage = false); }
          }, child: Text(copy.restoreDownload)),
          TextButton(onPressed: exportingPackage ? null : () async {
            update(() => exportingPackage = true);
            try {
              await SubtitleDownloadAssets.remove(download.globalKey, profileId: download.profileId);
              await onDownloadChanged?.call();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.removedSavedCaptions)));
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.removeSavedFailed)));
            } finally { if (context.mounted) update(() => exportingPackage = false); }
          }, child: Text(copy.removeSavedCaptions)),
        ],
        Text(copy.shareHelp),
        TextButton(onPressed: () async {
          final sharing = SubtitleHandoffService.instance;
          try {
            if (sharing.running) { await sharing.stop(); }
            else { await sharing.start(player, session.lanes.whereType<SubtitleOverlayTrack>().toList()); }
          } catch (_) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.shareFailed)));
          }
          if (context.mounted) update(() {});
        }, child: Text(SubtitleHandoffService.instance.running ? copy.stopShare : copy.startShare)),
        for (final url in SubtitleHandoffService.instance.urls) ListTile(title: SelectableText(url),
          trailing: IconButton(tooltip: copy.copyPrivateLink, icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: url)))),
        for (final track in SubtitleHandoffService.instance.trackUrls) ListTile(title: Text(copy.webVttTitle(title: track.title)),
          subtitle: SelectableText(track.url), trailing: IconButton(tooltip: copy.copyReceiverUrl, icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: track.url)))),
        SwitchListTile(title: Text(copy.coverTitle),
          subtitle: Text(copy.coverHelp),
          value: session.coverRegion != null, onChanged: (v) => change(() => session.coverRegion = v ? const Rect.fromLTWH(0, .8, 1, .2) : null)),
        if (session.coverRegion != null) Slider(value: session.coverRegion!.height, min: .05, max: .4,
          label: '${(session.coverRegion!.height * 100).round()}%', onChanged: (v) => change(() => session.coverRegion = Rect.fromLTWH(0, 1 - v, 1, v))),
      ]))), actions: [TextButton(onPressed: () { change(() { session.lanes.fillRange(0, 2, null); session.coverRegion = null; }); }, child: Text(copy.clearAll)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(copy.done))]);
  }));
}

Future<bool> _confirmSnapshot(BuildContext context, int clipped, {required bool attach}) async =>
  await showDialog<bool>(context: context, builder: (context) {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleOverlays;
    return AlertDialog(
      title: Text(attach ? copy.nativeConfirmTitle : copy.exportConfirmTitle),
      content: Text('${copy.snapshotConfirmBody} '
        '${clipped > 0 ? copy.clippingWarning(count: clipped) : ""} '
        '${attach ? copy.nativeConfirmNote : copy.exportConfirmNote}'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(attach ? copy.useNative : copy.exportAction))]);
  }) ?? false;
