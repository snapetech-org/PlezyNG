import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/file_picker_service.dart';

Map<String, dynamic> _calibration(Object? value) {
  if (value is! Map || value['schema'] != 'plezyng.microphone-array.v1' ||
      value['axes'] != 'x-right-y-forward-z-up') {
    throw const FormatException('arraySchema');
  }
  final speed = value['speedOfSoundMps'], channels = value['channels'];
  bool number(Object? n, double low, double high) => n is num && n.isFinite && n >= low && n <= high;
  if (!number(speed, 300, 380) || channels is! List || channels.length < 4 || channels.length > 8) {
    throw const FormatException('arrayGeometry');
  }
  final rows = <Map<String, dynamic>>[];
  for (final channel in channels) {
    if (channel is! Map) throw const FormatException('arrayChannel');
    final position = channel['positionM'], delay = channel['delayUs'], polarity = channel['polarity'];
    if (position is! List || position.length != 3 || position.any((n) => !number(n, -2, 2)) ||
        !number(delay, -5000, 5000) || polarity is! int || (polarity != -1 && polarity != 1)) {
      throw const FormatException('arrayPosition');
    }
    rows.add({'positionM': List<num>.from(position), 'delayUs': delay, 'polarity': polarity});
  }
  return {'schema': 'plezyng.microphone-array.v1', 'axes': value['axes'],
    'speedOfSoundMps': speed, 'channels': rows};
}

/// Declarations are reviewed here; the host still validates geometry and PCM.
Future<Map<String, dynamic>?> showSubtitleArrayCalibration(BuildContext context) async {
  final copy = Translations.of(context).videoControls.subtitleAiControls;
  Map<String, dynamic>? calibration;
  var declared = false, loading = false;
  String? error;
  return showDialog<Map<String, dynamic>>(context: context, builder: (context) => StatefulBuilder(
    builder: (context, update) => AlertDialog(title: Text(copy.arrayCalibrationTitle),
      content: SizedBox(width: 620, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(copy.arrayCalibrationInstructions),
        TextButton(onPressed: loading ? null : () async {
          update(() { loading = true; error = null; });
          try {
            final picked = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
            if (picked == null || picked.files.length != 1 || !context.mounted) return;
            final file = picked.files.single;
            if (file.size <= 0 || file.size > 16384) throw const FormatException('arrayFileSize');
            List<int>? bytes = file.bytes;
            if (bytes == null && file.path != null) {
              final input = File(file.path!);
              if (await input.length() != file.size) throw const FormatException('arrayFileChanged');
              bytes = await input.openRead(0, 16385).fold<List<int>>([], (all, chunk) => all..addAll(chunk));
            }
            if (bytes == null || bytes.isEmpty || bytes.length > 16384) throw const FormatException('arrayFileBytes');
            final selected = _calibration(jsonDecode(utf8.decode(bytes)));
            if (context.mounted) update(() { calibration = selected; declared = false; });
          } on FormatException catch (e) {
            final message = switch (e.message) {
              'arraySchema' => copy.arrayCalibrationSchemaError,
              'arrayGeometry' => copy.arrayCalibrationGeometryError,
              'arrayChannel' => copy.arrayCalibrationChannelError,
              'arrayPosition' => copy.arrayCalibrationPositionError,
              'arrayFileSize' => copy.arrayCalibrationFileSizeError,
              'arrayFileChanged' => copy.arrayCalibrationFileChangedError,
              'arrayFileBytes' => copy.arrayCalibrationFileBytesError,
              _ => copy.arrayCalibrationInvalidJsonError,
            };
            if (context.mounted) update(() => error = message);
          } catch (_) {
            if (context.mounted) update(() => error = copy.arrayCalibrationReadError);
          } finally { if (context.mounted) update(() => loading = false); }
        }, child: Text(loading ? copy.arrayCalibrationOpening : copy.arrayCalibrationImport)),
        if (calibration case final Map<String, dynamic> data) ...[
          Text(copy.arraySoundSpeed(speed: data['speedOfSoundMps'])),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columns: [
            DataColumn(label: Text(copy.arrayChannel)), DataColumn(label: Text(copy.arrayPosition)),
            DataColumn(label: Text(copy.arrayLatency)), DataColumn(label: Text(copy.arrayPolarity)),
          ], rows: [for (final entry in (data['channels'] as List).indexed) DataRow(cells: [
            DataCell(Text('${entry.$1 + 1}')), DataCell(Text((entry.$2['positionM'] as List).join(', '))),
            DataCell(Text('${entry.$2['delayUs']}')), DataCell(Text('${entry.$2['polarity']}')),
          ])])),
          CheckboxListTile(value: declared, onChanged: (v) => update(() => declared = v == true),
            title: Text(copy.arrayRawOrderDeclaration),
            subtitle: Text(copy.arrayReviewDeclaration)),
        ],
        Text(copy.arrayResultCaveat),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Translations.of(context).common.cancel)),
        FilledButton(onPressed: calibration == null || !declared || loading ? null : () => Navigator.pop(context,
          <String, dynamic>{...calibration!, 'rawSynchronizedCapture': true}), child: Text(copy.arrayUseCalibration))],
    )));
}
