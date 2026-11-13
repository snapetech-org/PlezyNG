import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n/strings.g.dart';
import '../services/file_picker_service.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import 'app_database.dart';

/// Offers an explicit first-run import on desktop and returns the source only
/// after the owner reviews the staged database preview and confirms import.
/// Existing app databases are never replaced and no source is found by name.
Future<File?> showLegacyDesktopDatabaseOnboarding(
  BuildContext context, {
  @visibleForTesting Future<LegacyDesktopDatabasePreview> Function(File source)? inspectDatabase,
}) async {
  if (!PlatformDetector.isDesktopOS()) return null;

  final shouldChoose = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(t.startup.legacyImportTitle),
      content: Text(t.startup.legacyImportBody),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.startup.legacyImportStartFresh)),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.startup.legacyImportChoose)),
      ],
    ),
  );
  if (shouldChoose != true || !context.mounted) return null;

  while (context.mounted) {
    try {
      final selection = await FilePickerService.instance.pickFiles(
        dialogTitle: t.startup.legacyImportPickTitle,
        allowMultiple: false,
        withData: false,
      );
      if (!context.mounted || selection == null || selection.files.isEmpty) return null;
      final path = selection.files.single.path;
      if (path == null || path.isEmpty) {
        final chooseAnother = await _showInvalidDatabase(context);
        if (!chooseAnother) return null;
        continue;
      }

      final source = File(path);
      final navigator = Navigator.of(context, rootNavigator: true);
      final inspection = (inspectDatabase ?? inspectLegacyDesktopDatabase)(source);
      final progressDialog = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            AlertDialog(title: Text(t.startup.legacyImportChecking), content: const LinearProgressIndicator()),
      );
      unawaited(progressDialog);

      late final LegacyDesktopDatabasePreview preview;
      try {
        preview = await inspection;
      } finally {
        if (context.mounted && navigator.canPop()) navigator.pop();
        await progressDialog;
      }
      if (!context.mounted) return null;

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(t.startup.legacyImportReviewTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.startup.legacyImportFile(name: p.basename(source.path))),
                Text(t.startup.legacyImportSize(size: _formatBytes(preview.fileSizeBytes))),
                Text(t.startup.legacyImportSchemaVersion(version: preview.schemaVersion)),
                if (preview.profileCount case final count?) Text(t.startup.legacyImportProfiles(count: count)),
                if (preview.connectionCount case final count?) Text(t.startup.legacyImportConnections(count: count)),
                Text(t.startup.legacyImportDownloads(count: preview.downloadedMediaCount)),
                const SizedBox(height: 12),
                Text(t.startup.legacyImportIdentityWarning),
                const SizedBox(height: 8),
                Text(t.startup.legacyImportCredentialsWarning),
                const SizedBox(height: 8),
                Text(t.startup.legacyImportPathsWarning),
                const SizedBox(height: 8),
                Text(t.startup.legacyImportBackup),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t.startup.legacyImportStartFresh),
            ),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.startup.legacyImportConfirm)),
          ],
        ),
      );
      return confirmed == true ? source : null;
    } catch (error, stackTrace) {
      appLogger.w('Legacy database preview failed', error: error, stackTrace: stackTrace);
      if (!context.mounted) return null;
      final chooseAnother = await _showInvalidDatabase(context);
      if (!chooseAnother) return null;
    }
  }
  return null;
}

Future<bool> _showInvalidDatabase(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(t.startup.legacyImportInvalidTitle),
          content: Text(t.startup.legacyImportInvalidBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t.startup.legacyImportStartFresh),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t.startup.legacyImportTryAnother),
            ),
          ],
        ),
      ) ??
      false;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kibibytes = bytes / 1024;
  if (kibibytes < 1024) return '${kibibytes.toStringAsFixed(1)} KiB';
  final mebibytes = kibibytes / 1024;
  if (mebibytes < 1024) return '${mebibytes.toStringAsFixed(1)} MiB';
  return '${(mebibytes / 1024).toStringAsFixed(1)} GiB';
}
