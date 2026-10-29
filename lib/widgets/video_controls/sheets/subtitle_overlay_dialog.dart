import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_native_handoff_service.dart';
import '../../../services/subtitle_handoff_service.dart';
import '../../../mpv/mpv.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_speech_service.dart';
import '../../../services/speech_output_service.dart';
import '../../../services/subtitle_font_store.dart';
import '../../../services/subtitle_offline_package.dart';
import 'subtitle_fonts_dialog.dart';

Future<void> showSubtitleOverlayControls(BuildContext context, Player player) async {
  try { await SubtitleFontStore.instance.initialize(); } catch (_) {}
  if (!context.mounted) return;
  final session = SubtitleOverlayService.forPlayer(player);
  var exportingPackage = false;
  await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) {
    void change(VoidCallback action) { update(action); session.changed(); }
    return AlertDialog(title: const Text('App caption overlays'), content: SizedBox(width: 620,
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Plain-text overlays are local to this player. Native ASS/bitmap tracks retain their own rendering. '
          'Native PiP, Cast and external players require a compatible exported subtitle; app overlays are not sent. '
          'Color brightness is an SDR UI value, not calibrated HDR luminance.'),
        TextButton(onPressed: () async {
          await showDialog<void>(context: context, builder: (_) => const SubtitleFontsDialog());
          if (context.mounted) { update(() {}); session.changed(); }
        }, child: const Text('Manage offline fonts')),
        for (var index = 0; index < 2; index++) if (session.lanes[index] case final SubtitleOverlayTrack track) ...[
          ListTile(title: Text('${index + 1}: ${track.title}'), trailing: IconButton(tooltip: 'Remove overlay',
            onPressed: () => change(() => session.lanes[index] = null), icon: const Icon(Icons.close))),
          if (SpeechOutputService.supported) TextButton(onPressed: () async {
            final speech = SubtitleSpeechService.instance;
            if (speech.isSpeaking(track)) { await speech.stop(); } else { await speech.start(player, track); }
            if (context.mounted) update(() {});
          }, child: Text(SubtitleSpeechService.instance.isSpeaking(track) ? 'Stop spoken subtitles' : 'Speak this overlay')),
          DropdownButton<String>(value: SubtitleOverlayTrack.fonts.contains(track.fontFamily) ? track.fontFamily : 'Bundled multilingual', isExpanded: true,
            items: [for (final font in SubtitleOverlayTrack.fonts) DropdownMenuItem(value: font, child: Text(SubtitleFontStore.instance.label(font)))],
            onChanged: (font) { if (font != null) change(() => track.fontFamily = font); }),
          const Text('Bundled and imported fonts work offline, including Hangul fallback. System-family choices may be unavailable on this device. Removed imports fall back to the bundled font.'),
          SwitchListTile(title: const Text('Show ruby reading aids'),
            subtitle: const Text('Display supplied ruby readings above their base text. Ruby groups wrap together and use base text for speech and plain export. Word highlighting pauses for annotated cues.'),
            value: track.ruby, onChanged: (value) => change(() => track.ruby = value)),
          Wrap(spacing: 8, children: [for (final align in [TextAlign.start, TextAlign.center, TextAlign.end])
            ChoiceChip(label: Text(align.name), selected: track.alignment == align,
              onSelected: (_) => change(() => track.alignment = align))]),
          if (track.profileId != null) TextButton(onPressed: () async {
            try { await track.saveAppearance(index);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Appearance saved for this profile and lane. Timing and scene placement stay with this track.')));
            } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save caption appearance.'))); }
          }, child: const Text('Use this appearance for future tracks')),
          if (track.positionToSourceMs != null) const Text('This live overlay follows the moving program clock. Fixed-file export, Cast and native snapshot attachment are unavailable.'),
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
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not export the subtitle and font package.')));
            } finally { if (context.mounted) update(() => exportingPackage = false); }
          }, child: Text(exportingPackage ? 'Preparing offline package…' : 'Export SRT + selected imported font')),
          if (track.positionToSourceMs == null) Wrap(spacing: 8, children: [TextButton(onPressed: () async {
            try {
              final snapshot = SubtitleNativeHandoffService.export(player, track);
              if (!context.mounted || !await _confirmSnapshot(context, snapshot.clipped, attach: false)) return;
              final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.captions.srt', bytes: snapshot.bytes,
                type: FileType.custom, allowedExtensions: const ['srt']);
              if (path != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) await File(path).writeAsBytes(snapshot.bytes, flush: true);
            } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not export this caption snapshot.'))); }
          }, child: const Text('Export corrected SRT')),
          if (player.supportedLocalSubtitleExtensions.contains('srt')) TextButton(onPressed: () async {
            try {
              final snapshot = SubtitleNativeHandoffService.export(player, track);
              if (!context.mounted || !await _confirmSnapshot(context, snapshot.clipped, attach: true)) return;
              await SubtitleNativeHandoffService.attach(player, track, allowClipping: true);
              if (context.mounted) update(() {});
            } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The native renderer could not attach this caption snapshot.'))); }
          }, child: const Text('Move snapshot to native subtitles'))]),
          if (track.avoidRegions.isNotEmpty) SwitchListTile(title: const Text('Avoid reviewed scene regions'),
            subtitle: const Text('Uses reviewed single-frame or sampled temporal proposals at cue boundaries. Placement can be wrong; authored signs keep their positions.'),
            value: track.avoidObjects, onChanged: (value) => change(() => track.avoidObjects = value)),
          Text('Size ${track.fontSize.round()}'), Slider(value: track.fontSize, min: 16, max: 64,
            onChanged: (v) => change(() => track.fontSize = v)),
          SwitchListTile(title: const Text('Anchor dialogue inside the video'),
            subtitle: const Text('Otherwise dialogue uses the screen and letterbox. Signs and the burned-caption cover follow the video. Unknown video size falls back to screen placement.'),
            value: track.videoAnchored, onChanged: (v) => change(() => track.videoAnchored = v)),
          Text('Safe inset / TV overscan ${(track.overscan * 100).round()}%'),
          Slider(value: track.overscan, min: 0, max: .15, onChanged: (v) => change(() => track.overscan = v)),
          Text('Vertical position ${(track.position * 100).round()}%'), Slider(value: track.position, min: .05, max: .95,
            onChanged: (v) => change(() => track.position = v)),
          const Text('Background'), Slider(value: track.backgroundOpacity, min: 0, max: 1,
            onChanged: (v) => change(() => track.backgroundOpacity = v)),
          Wrap(spacing: 8, children: [for (final background in [Colors.black, const Color(0xff182332), const Color(0xff4a321c)])
            ChoiceChip(label: Text('Background', style: TextStyle(color: Colors.white, backgroundColor: background)), selected: track.backgroundColor == background,
              onSelected: (_) => change(() => track.backgroundColor = background))]),
          const Text('Outline'), Slider(value: track.outlineWidth, min: 0, max: 5,
            onChanged: (v) => change(() => track.outlineWidth = v)),
          const Text('Side margin'), Slider(value: track.margin, min: .02, max: .2,
            onChanged: (v) => change(() => track.margin = v)),
          Wrap(spacing: 8, children: [
            for (final color in [Colors.white, Colors.grey, Colors.amber, Colors.lightBlue, Colors.lightGreen])
              ChoiceChip(label: Text('Aa', style: TextStyle(color: color)), selected: track.color == color,
                onSelected: (_) => change(() => track.color = color)),
            FilterChip(label: const Text('Bold'), selected: track.bold, onSelected: (v) => change(() => track.bold = v)),
            FilterChip(label: const Text('Italic'), selected: track.italic, onSelected: (v) => change(() => track.italic = v)),
          ]),
          TextFormField(initialValue: '${track.delayMs}', decoration: const InputDecoration(labelText: 'Lane delay (signed ms)'),
            keyboardType: const TextInputType.numberWithOptions(signed: true), onChanged: (v) {
              final delay = int.tryParse(v); if (delay != null && delay.abs() <= 3600000) change(() => track.delayMs = delay);
            }),
          SwitchListTile(title: const Text('Highlight timed words'), subtitle: const Text('Requires original word/token timings; singing accuracy is not assumed.'),
            value: track.karaoke, onChanged: track.words.isEmpty ? null : (v) => change(() => track.karaoke = v)),
        ],
        if (SpeechOutputService.supported) ...[
          const Text('Speech uses the device engine (or installed espeak-ng on Linux). Its network policy is controlled by that engine. '
            'Speech stops at cue boundaries and may truncate lines that cannot fit; it does not change playback speed.'),
          Text('Speech rate ${(SubtitleSpeechService.instance.rate * 100).round()}%'),
          Slider(value: SubtitleSpeechService.instance.rate, min: .1, max: 1,
            onChanged: (v) => update(() => SubtitleSpeechService.instance.rate = v)),
          Text('Keep ${(SubtitleSpeechService.instance.duck * 100).round()}% of original audio while speaking'),
          Slider(value: SubtitleSpeechService.instance.duck, min: 0, max: 1,
            onChanged: (v) => update(() => SubtitleSpeechService.instance.duck = v)),
        ],
        const Divider(),
        const Text('Share the reviewed app overlays as a read-only second screen and receiver-compatible WebVTT links. '
          'Only private-network peers with the secret link can read them. HTTP is unencrypted; use a trusted local network. '
          'Playback URLs and credentials are never shared. App styling and authored layouts are flattened.'),
        TextButton(onPressed: () async {
          final sharing = SubtitleHandoffService.instance;
          try {
            if (sharing.running) { await sharing.stop(); }
            else { await sharing.start(player, session.lanes.whereType<SubtitleOverlayTrack>().toList()); }
          } catch (_) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subtitle sharing could not start on this network.')));
          }
          if (context.mounted) update(() {});
        }, child: Text(SubtitleHandoffService.instance.running ? 'Stop sharing and revoke links' : 'Share both reviewed overlays on this network')),
        for (final url in SubtitleHandoffService.instance.urls) ListTile(title: SelectableText(url),
          trailing: IconButton(tooltip: 'Copy private subtitle link', icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: url)))),
        for (final track in SubtitleHandoffService.instance.trackUrls) ListTile(title: Text('WebVTT: ${track.title}'),
          subtitle: SelectableText(track.url), trailing: IconButton(tooltip: 'Copy receiver subtitle URL', icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: track.url)))),
        SwitchListTile(title: const Text('Cover burned captions in a bottom band'),
          subtitle: const Text('Opaque cover on this screen only. It hides picture detail; it does not reconstruct the background or edit the video.'),
          value: session.coverRegion != null, onChanged: (v) => change(() => session.coverRegion = v ? const Rect.fromLTWH(0, .8, 1, .2) : null)),
        if (session.coverRegion != null) Slider(value: session.coverRegion!.height, min: .05, max: .4,
          label: '${(session.coverRegion!.height * 100).round()}%', onChanged: (v) => change(() => session.coverRegion = Rect.fromLTWH(0, 1 - v, 1, v))),
      ]))), actions: [TextButton(onPressed: () { change(() { session.lanes.fillRange(0, 2, null); session.coverRegion = null; }); }, child: const Text('Clear all')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))]);
  }));
}

Future<bool> _confirmSnapshot(BuildContext context, int clipped, {required bool attach}) async =>
  await showDialog<bool>(context: context, builder: (context) => AlertDialog(
    title: Text(attach ? 'Use native caption rendering?' : 'Export corrected captions?'),
    content: Text('This is a plain-text snapshot with the lane delay applied on the opened media part’s clock. '
      'Fonts, positions, karaoke and future generated cues are not included. '
      '${clipped > 0 ? "$clipped cues cross or precede this part and will be clipped or omitted. " : ""}'
      '${attach ? "The native primary track is selected and this app overlay is removed. PiP visibility still depends on the native output path." : "The export contains future dialogue from this track."}'),
    actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(attach ? 'Use native subtitles' : 'Export'))])) ?? false;
