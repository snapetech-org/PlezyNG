import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../services/file_picker_service.dart';

Map<String, dynamic> _calibration(Object? value) {
  if (value is! Map || value['schema'] != 'plezyng.microphone-array.v1' ||
      value['axes'] != 'x-right-y-forward-z-up') {
    throw const FormatException('Choose a PlezyNG array calibration with right/forward/up axes.');
  }
  final speed = value['speedOfSoundMps'], channels = value['channels'];
  bool number(Object? n, double low, double high) => n is num && n.isFinite && n >= low && n <= high;
  if (!number(speed, 300, 380) || channels is! List || channels.length < 4 || channels.length > 8) {
    throw const FormatException('Calibration requires 4–8 microphones and a sound speed of 300–380 m/s.');
  }
  final rows = <Map<String, dynamic>>[];
  for (final channel in channels) {
    if (channel is! Map) throw const FormatException('Invalid microphone calibration.');
    final position = channel['positionM'], delay = channel['delayUs'], polarity = channel['polarity'];
    if (position is! List || position.length != 3 || position.any((n) => !number(n, -2, 2)) ||
        !number(delay, -5000, 5000) || polarity is! int || (polarity != -1 && polarity != 1)) {
      throw const FormatException('Each microphone needs three meter coordinates, latency within ±5000 µs, and polarity +1 or −1.');
    }
    rows.add({'positionM': List<num>.from(position), 'delayUs': delay, 'polarity': polarity});
  }
  return {'schema': 'plezyng.microphone-array.v1', 'axes': value['axes'],
    'speedOfSoundMps': speed, 'channels': rows};
}

/// Declarations are reviewed here; the host still validates geometry and PCM.
Future<Map<String, dynamic>?> showSubtitleArrayCalibration(BuildContext context) async {
  Map<String, dynamic>? calibration;
  var declared = false, loading = false;
  String? error;
  return showDialog<Map<String, dynamic>>(context: context, builder: (context) => StatefulBuilder(
    builder: (context, update) => AlertDialog(title: const Text('Review microphone-array calibration'),
      content: SizedBox(width: 620, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Use an original synchronized 4–8 channel PCM WAV, up to two minutes. '
          'Microphones must form a noncoplanar array, with measured positions, latency and polarity. '
          'Mixed, downmixed, denoised or independently recorded audio cannot establish physical direction here.'),
        TextButton(onPressed: loading ? null : () async {
          update(() { loading = true; error = null; });
          try {
            final picked = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
            if (picked == null || picked.files.length != 1 || !context.mounted) return;
            final file = picked.files.single;
            if (file.size <= 0 || file.size > 16384) throw const FormatException('Choose a calibration file no larger than 16 KiB.');
            List<int>? bytes = file.bytes;
            if (bytes == null && file.path != null) {
              final input = File(file.path!);
              if (await input.length() != file.size) throw const FormatException('Calibration changed while opening.');
              bytes = await input.openRead(0, 16385).fold<List<int>>([], (all, chunk) => all..addAll(chunk));
            }
            if (bytes == null || bytes.isEmpty || bytes.length > 16384) throw const FormatException('Calibration bytes unavailable or too large.');
            final selected = _calibration(jsonDecode(utf8.decode(bytes)));
            if (context.mounted) update(() { calibration = selected; declared = false; });
          } on FormatException catch (e) {
            if (context.mounted) update(() => error = e.message);
          } catch (_) {
            if (context.mounted) update(() => error = 'Could not read this calibration file.');
          } finally { if (context.mounted) update(() => loading = false); }
        }, child: Text(loading ? 'Opening calibration…' : 'Import calibration file')),
        if (calibration case final Map<String, dynamic> data) ...[
          Text('Sound speed: ${data['speedOfSoundMps']} m/s. Coordinates: x right, y forward, z up.'),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columns: const [
            DataColumn(label: Text('Channel')), DataColumn(label: Text('Position (m)')),
            DataColumn(label: Text('Latency (µs)')), DataColumn(label: Text('Polarity')),
          ], rows: [for (final entry in (data['channels'] as List).indexed) DataRow(cells: [
            DataCell(Text('${entry.$1 + 1}')), DataCell(Text((entry.$2['positionM'] as List).join(', '))),
            DataCell(Text('${entry.$2['delayUs']}')), DataCell(Text('${entry.$2['polarity']}')),
          ])])),
          CheckboxListTile(value: declared, onChanged: (v) => update(() => declared = v == true),
            title: const Text('These channels are the original synchronized capture in the listed order.'),
            subtitle: const Text('I have checked this calibration and the cue times against the uploaded WAV.')),
        ],
        const Text('Results are unqualified array-relative direction candidates. They do not identify a person, '
          'a visible object or a world location. Cue text and timing remain unchanged.'),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: calibration == null || !declared || loading ? null : () => Navigator.pop(context,
          <String, dynamic>{...calibration!, 'rawSynchronizedCapture': true}), child: const Text('Use reviewed calibration'))],
    )));
}
