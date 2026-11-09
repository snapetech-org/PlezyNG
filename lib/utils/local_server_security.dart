import 'dart:io';

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../services/file_picker_service.dart';
import 'insecure_connection_consent.dart';

class LocalServerSecurity {
  const LocalServerSecurity(this.context);
  final SecurityContext? context;
  String get scheme => context == null ? 'http' : 'https';
}

/// One foreground sharing session. Cancellation never opens a listener and a
/// certificate/key error never falls back to plaintext.
Future<LocalServerSecurity?> chooseLocalServerSecurity(BuildContext context, {String host = 'local-device'}) async {
  final secure = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(t.karaokeUi.roomConnection),
      content: Text(t.iptv.allowHttpDescription),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(t.common.cancel)),
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(t.addServer.allowHttp)),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(t.karaokeUi.configureHTTPS),
        ),
      ],
    ),
  );
  if (secure == null || !context.mounted) return null;
  if (!secure) {
    return await confirmInsecureConnection(context, Uri(scheme: 'http', host: host).toString())
        ? const LocalServerSecurity(null)
        : null;
  }
  final cert = await FilePickerService.instance.pickFiles(dialogTitle: t.karaokeUi.selectTrustedPEMCertificate);
  final certPath = cert?.files.single.path;
  if (certPath == null || !context.mounted) return null;
  final key = await FilePickerService.instance.pickFiles(dialogTitle: t.karaokeUi.selectPrivatePEMKey);
  final keyPath = key?.files.single.path;
  if (keyPath == null || !context.mounted) return null;
  final security = SecurityContext()
    ..useCertificateChain(certPath)
    ..usePrivateKey(keyPath);
  return LocalServerSecurity(security);
}
