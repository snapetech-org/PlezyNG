import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../games/steam_cloud_client.dart';
import '../../i18n/locale_preferences.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../services/file_picker_service.dart';
import '../../services/trackers/oauth_proxy_client.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/oauth_proxy_dialog.dart';

/// File changes are reviewed inside the existing dialog route. Profile
/// retirement cancels its authorization, requests and pending confirmations.
class SteamCloudDialog extends StatefulWidget {
  const SteamCloudDialog({
    super.key,
    required this.client,
    required this.capabilities,
    required this.catalog,
    required this.appId,
    required this.steamId,
    required this.isCurrent,
    required this.retired,
    this.proxy,
    this.clientFactory,
  });
  final SteamCloudClient client;
  final SteamCloudCapabilities capabilities;
  final String catalog, steamId;
  final int appId;
  final bool Function() isCurrent;
  final Future<void> retired;
  final OAuthProxyClient? proxy;
  final SteamCloudClient Function()? clientFactory;
  @override
  State<SteamCloudDialog> createState() => _SteamCloudDialogState();
}

enum _CloudAction { download, replace, delete }

class _CloudReview {
  const _CloudReview(this.file, this.action, [this.bytes]);
  final SteamCloudFile file;
  final _CloudAction action;
  final Uint8List? bytes;
}

class _SteamCloudDialogState extends State<SteamCloudDialog> {
  late SteamCloudClient _client;
  late final OAuthProxyClient _proxy;
  final _cancelled = Completer<void>();
  OAuthProxyStart? _start;
  List<SteamCloudFile>? _files;
  _CloudReview? _review;
  String? _message;
  bool _busy = false, _authorized = false;
  bool get current => mounted && !_cancelled.isCompleted && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _client = widget.client;
    _proxy = widget.proxy ?? OAuthProxyClient();
    unawaited(
      widget.retired.then((_) {
        if (!_cancelled.isCompleted) _cancelled.complete();
        unawaited(_client.retire());
        _proxy.dispose();
        if (mounted) {
          final route = ModalRoute.of(context);
          if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
        }
      }),
    );
  }

  @override
  void dispose() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    unawaited(_client.retire());
    _proxy.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!current || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on SteamCloudUnavailable catch (error) {
      if (current) {
        setState(() {
          _message = error.refreshRequired ? t.games.cloudRefreshRequired : t.games.unavailable;
          if (error.refreshRequired) _files = null;
          _review = null;
        });
      }
    } catch (_) {
      if (current) {
        setState(() {
          _message = t.games.unavailable;
          _review = null;
        });
      }
    } finally {
      if (current) setState(() => _busy = false);
    }
  }

  Future<void> _authorize(bool write) => _run(() async {
    if (_authorized) {
      await _client.retire();
      if (!current) return;
      _client = widget.clientFactory?.call() ?? SteamCloudClient();
      _authorized = false;
      _files = null;
    }
    final start = await _client.start(widget.catalog, widget.appId, write: write);
    if (!current) return;
    setState(() => _start = start);
    OAuthProxyResult? result;
    try {
      result = await _proxy.poll(start.session, shouldCancel: () => !current, onCancel: _cancelled.future);
    } finally {
      if (current) setState(() => _start = null);
    }
    if (!current || result == null) return;
    _client.authorize(result, appId: widget.appId, steamId: widget.steamId, write: write);
    _authorized = true;
    await _load();
  });
  Future<void> _load() async {
    final files = await _client.files();
    if (current) {
      setState(() {
        _files = files;
        _review = null;
      });
    }
  }

  Future<void> _fileAction(SteamCloudFile file, _CloudAction action) => _run(() async {
    if (action == _CloudAction.download) {
      final bytes = await _client.download(file);
      if (!current) return;
      // The remote Cloud key is never a local path. The platform picker owns
      // destination selection and overwrite confirmation on every platform.
      final name = file.name.split(RegExp(r'[/\\]')).last;
      await FilePickerService.instance.saveFile(
        dialogTitle: t.games.cloudDownload,
        fileName: name.isEmpty ? 'save.bin' : name,
        bytes: bytes,
      );
      return;
    }
    if (!_client.canWrite) return;
    if (action == _CloudAction.delete) {
      setState(() => _review = _CloudReview(file, action));
      return;
    }
    final picked = await FilePicker.pickFiles(allowMultiple: false, withReadStream: true, withData: false);
    if (!current || picked == null || picked.files.length != 1) return;
    final selected = picked.files.single;
    if (selected.size > steamCloudMaxFileBytes || selected.readStream == null) {
      setState(() => _message = t.games.cloudLimit(size: ByteFormatter.formatBytes(steamCloudMaxFileBytes)));
      return;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in selected.readStream!.timeout(const Duration(seconds: 30))) {
      if (!current) return;
      if (chunk.length > steamCloudMaxFileBytes - bytes.length) {
        setState(() => _message = t.games.cloudLimit(size: ByteFormatter.formatBytes(steamCloudMaxFileBytes)));
        return;
      }
      bytes.add(chunk);
    }
    if (current) setState(() => _review = _CloudReview(file, action, bytes.takeBytes()));
  });
  Future<void> _confirm() => _run(() async {
    final review = _review;
    if (review == null || !_client.canWrite) return;
    // Retire the reviewed action before sending; no repeated key press or
    // ambiguous response can automatically repeat a file mutation.
    setState(() => _review = null);
    if (review.action == _CloudAction.delete) {
      await _client.delete(review.file);
    } else {
      await _client.replace(review.file, review.bytes!);
    }
    if (!current) return;
    await _load();
    if (current) setState(() => _message = t.games.cloudChanged);
  });
  Widget _button(String text, VoidCallback? action) => FocusableButton(
    onPressed: action,
    child: TextButton(onPressed: action, child: Text(text)),
  );

  @override
  Widget build(BuildContext context) {
    final start = _start;
    if (start != null) {
      return OAuthProxyDialog(
        start: start,
        serviceName: 'Steam Cloud',
        onCancel: () {
          if (!_cancelled.isCompleted) _cancelled.complete();
        },
      );
    }
    final review = _review;
    final date = DateFormat.yMMMd(LocalePreferences.formattingLocaleName);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 680, maxHeight: MediaQuery.sizeOf(context).height * .85),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.games.steamCloudFiles, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Text(_client.canWrite ? t.games.cloudChangeHelp : t.games.cloudAccessHelp),
                    if (_message case final message?)
                      Semantics(
                        liveRegion: true,
                        child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(message)),
                      ),
                    if (review != null) ...[
                      const Divider(),
                      Text(
                        review.action == _CloudAction.delete
                            ? t.games.cloudReviewDelete(name: isolateDisplayText(review.file.name))
                            : t.games.cloudReviewReplace(name: isolateDisplayText(review.file.name)),
                      ),
                      if (review.bytes != null) Text(ByteFormatter.formatBytes(review.bytes!.length)),
                      Wrap(
                        children: [
                          _button(t.common.cancel, _busy ? null : () => setState(() => _review = null)),
                          _button(t.common.confirm, _busy ? null : _confirm),
                        ],
                      ),
                    ] else ...[
                      if (_files?.isEmpty ?? false) Text(t.games.cloudEmpty),
                      for (final file in _files ?? <SteamCloudFile>[])
                        FocusableListTile(
                          leading: const AppIcon(Symbols.cloud_rounded),
                          title: Text(isolateDisplayText(file.name), maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${ByteFormatter.formatBytes(file.size)} · ${date.format(file.modified.toLocal())}',
                          ),
                          onTap: _busy || file.size > steamCloudMaxFileBytes
                              ? null
                              : () => _fileAction(file, _CloudAction.download),
                          trailing: _busy || (!_client.canWrite && file.size > steamCloudMaxFileBytes)
                              ? null
                              : AppMenuButton<_CloudAction>(
                                  icon: const AppIcon(Symbols.more_vert_rounded),
                                  tooltip: '${t.common.options}: ${isolateDisplayText(file.name)}',
                                  adaptiveSheet: true,
                                  entriesBuilder: (_) => [
                                    if (file.size <= steamCloudMaxFileBytes)
                                      AppMenuItem(
                                        value: _CloudAction.download,
                                        label: t.games.cloudDownload,
                                        icon: Symbols.download_rounded,
                                      ),
                                    if (_client.canWrite) ...[
                                      AppMenuItem(
                                        value: _CloudAction.replace,
                                        label: t.games.cloudReplace,
                                        icon: Symbols.upload_file_rounded,
                                      ),
                                      AppMenuItem(
                                        value: _CloudAction.delete,
                                        label: t.common.delete,
                                        icon: Symbols.delete_rounded,
                                      ),
                                    ],
                                  ],
                                  onSelected: (action) => _fileAction(file, action),
                                ),
                        ),
                    ],
                  ],
                ),
              ),
              const Divider(),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (!_authorized) _button(t.common.connect, _busy ? null : () => _authorize(false)),
                  if (_authorized && review == null) _button(t.common.refresh, _busy ? null : () => _run(_load)),
                  if (_authorized && !_client.canWrite && widget.capabilities.write)
                    _button(t.games.cloudEnableChanges, _busy ? null : () => _authorize(true)),
                  _button(t.common.close, () => Navigator.of(context).pop()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
