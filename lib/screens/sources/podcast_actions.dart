import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/file_picker_service.dart';
import '../../sources/podcast_opml.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';

Future<void> importPodcastOpml(BuildContext context) async {
  final sources = context.read<SourceController>();
  sources.requireSession();
  final epoch = sources.generation;
  final picked = await FilePickerService.instance.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['opml', 'xml'],
    withData: true,
  );
  sources.requireSession(epoch);
  final bytes = picked?.files.firstOrNull?.bytes;
  if (bytes == null || bytes.isEmpty) return;
  if (bytes.length > PodcastOpml.maxBytes) throw const SourceException(SourceFailure.invalidData);
  final count = await sources.importPodcastSubscriptions(PodcastOpml.parse(utf8.decode(bytes)));
  sources.requireSession(epoch);
  if (context.mounted) showSnackBar(context, count == 0 ? t.podcasts.alreadySubscribed : t.podcasts.imported);
}

Future<void> exportPodcastOpml(BuildContext context) async {
  final sources = context.read<SourceController>();
  sources.requireSession();
  final epoch = sources.generation;
  final subscriptions = await sources.podcastSubscriptions();
  sources.requireSession(epoch);
  if (subscriptions.isEmpty || !context.mounted) return;
  if (!await showConfirmDialog(
    context,
    title: t.podcasts.exportOpml,
    message: t.podcasts.exportHelp,
    confirmText: t.podcasts.exportOpml,
  )) {
    return;
  }
  sources.requireSession(epoch);
  await FilePickerService.instance.saveFile(
    fileName: 'plezyng-podcasts.opml',
    type: FileType.custom,
    allowedExtensions: const ['opml'],
    bytes: Uint8List.fromList(utf8.encode(PodcastOpml.write(subscriptions))),
  );
}
