import 'package:flutter/material.dart';
import '../../../mpv/mpv.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_speech_service.dart';
import '../../../services/speech_output_service.dart';

Future<void> showSubtitleOverlayControls(BuildContext context, Player player) async {
  final session = SubtitleOverlayService.forPlayer(player);
  await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) {
    void change(VoidCallback action) { update(action); session.changed(); }
    return AlertDialog(title: const Text('App caption overlays'), content: SizedBox(width: 620,
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Plain-text overlays are local to this player. Native ASS/bitmap tracks retain their own rendering. '
          'Native PiP, Cast and external players require a compatible exported subtitle; app overlays are not sent. '
          'Color brightness is an SDR UI value, not calibrated HDR luminance.'),
        for (var index = 0; index < 2; index++) if (session.lanes[index] case final SubtitleOverlayTrack track) ...[
          ListTile(title: Text('${index + 1}: ${track.title}'), trailing: IconButton(tooltip: 'Remove overlay',
            onPressed: () => change(() => session.lanes[index] = null), icon: const Icon(Icons.close))),
          if (SpeechOutputService.supported) TextButton(onPressed: () async {
            final speech = SubtitleSpeechService.instance;
            if (speech.isSpeaking(track)) { await speech.stop(); } else { await speech.start(player, track); }
            if (context.mounted) update(() {});
          }, child: Text(SubtitleSpeechService.instance.isSpeaking(track) ? 'Stop spoken subtitles' : 'Speak this overlay')),
          Text('Size ${track.fontSize.round()}'), Slider(value: track.fontSize, min: 16, max: 64,
            onChanged: (v) => change(() => track.fontSize = v)),
          Text('Vertical position ${(track.position * 100).round()}%'), Slider(value: track.position, min: .05, max: .95,
            onChanged: (v) => change(() => track.position = v)),
          const Text('Background'), Slider(value: track.backgroundOpacity, min: 0, max: 1,
            onChanged: (v) => change(() => track.backgroundOpacity = v)),
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
        SwitchListTile(title: const Text('Cover burned captions in a bottom band'),
          subtitle: const Text('Opaque cover on this screen only. It hides picture detail; it does not reconstruct the background or edit the video.'),
          value: session.coverRegion != null, onChanged: (v) => change(() => session.coverRegion = v ? const Rect.fromLTWH(0, .8, 1, .2) : null)),
        if (session.coverRegion != null) Slider(value: session.coverRegion!.height, min: .05, max: .4,
          label: '${(session.coverRegion!.height * 100).round()}%', onChanged: (v) => change(() => session.coverRegion = Rect.fromLTWH(0, 1 - v, 1, v))),
      ]))), actions: [TextButton(onPressed: () { change(() { session.lanes.fillRange(0, 2, null); session.coverRegion = null; }); }, child: const Text('Clear all')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))]);
  }));
}
