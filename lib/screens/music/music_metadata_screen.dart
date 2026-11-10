import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_metadata.dart';
import '../../services/music/music_nfc_writer.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';

class MusicMetadataScreen extends StatefulWidget {
  const MusicMetadataScreen({super.key, required this.item});
  final MediaItem item;
  @override
  State<MusicMetadataScreen> createState() => _MusicMetadataScreenState();
}

class _MusicMetadataScreenState extends State<MusicMetadataScreen> {
  late final MusicExperience _experience = context.read<MusicExperience>();
  bool get _current =>
      mounted &&
      _experience.store.active &&
      context.read<ActiveProfileProvider>().activeId == _experience.store.profileId &&
      !context.read<HiddenLibrariesProvider>().hiddenLibraryKeys.contains(
        '${widget.item.serverId}:${widget.item.libraryId}',
      );
  late Future<MediaItem> _details;
  MediaServerClient? _client;
  Object? _authentication;
  String? _scope;
  static const _nfc = MusicNfcWriter();
  late final Future<bool> _nfcAvailable = _nfc.available;
  bool _writing = false;

  Future<void> _writeNfc() async {
    if (_writing || !_sourceCurrent) return;
    setState(() => _writing = true);
    final navigator = Navigator.of(context);
    late final DialogRoute<void> route;
    route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(t.musicTools.nfcWrite),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [Text(t.musicTools.nfcPrompt), const SizedBox(height: 16), const CircularProgressIndicator()],
          ),
          actions: [TextButton(onPressed: () => _nfc.cancel(), child: Text(t.common.cancel))],
        ),
      ),
    );
    unawaited(navigator.push(route));
    try {
      final written = await _nfc.write(widget.item, prompt: t.musicTools.nfcPrompt);
      if (mounted && _sourceCurrent && written) showAppSnackBar(context, t.rateSheet.saved);
    } catch (_) {
      if (mounted && _sourceCurrent) showAppSnackBar(context, t.musicExperience.error);
    } finally {
      if (route.isActive) navigator.removeRoute(route);
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  void dispose() {
    if (_writing) unawaited(_nfc.cancel());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _details = _load();
  }

  bool get _sourceCurrent =>
      _current &&
      _client != null &&
      identical(_client, _experience.clientFor(widget.item)) &&
      identical(_authentication, _client!.authenticationSessionId) &&
      _scope == musicAccountScope(_client!);

  Future<MediaItem> _load() {
    _client = _experience.clientFor(widget.item);
    _authentication = _client?.authenticationSessionId;
    _scope = _client == null ? null : musicAccountScope(_client!);
    return loadMusicMetadata(
      item: widget.item,
      clientFor: () => _experience.clientFor(widget.item),
      isCurrent: () => _sourceCurrent,
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ActiveProfileProvider>();
    context.watch<HiddenLibrariesProvider>();
    context.watch<MultiServerProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.mediaMenu.viewDetails),
        actions: [
          FutureBuilder<bool>(
            future: _nfcAvailable,
            builder: (context, snapshot) => snapshot.data == true
                ? IconButton(
                    tooltip: t.musicTools.nfcWrite,
                    icon: const AppIcon(Symbols.nfc_rounded),
                    onPressed: _writing || !_sourceCurrent ? null : _writeNfc,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: FutureBuilder<MediaItem>(
        future: _details,
        builder: (context, snapshot) {
          if (!_sourceCurrent) return Center(child: Text(t.musicExperience.error));
          if (snapshot.hasError) {
            return Center(
              child: TextButton(onPressed: () => setState(() => _details = _load()), child: Text(t.common.retry)),
            );
          }
          final item = snapshot.data;
          if (item == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            children: [
              ListTile(title: Text(item.displayTitle), subtitle: item.summary == null ? null : Text(item.summary!)),
              if (item.editionTitle case final edition?)
                ListTile(title: Text(t.fileSources.editions), subtitle: Text(edition)),
              if (item.studio case final studio?) ListTile(title: Text(t.metadataEdit.label), subtitle: Text(studio)),
              if (item.originallyAvailableAt case final date?)
                ListTile(title: Text(t.metadataEdit.releaseDate), subtitle: Text(date)),
              for (final credit in musicCredits(item))
                ListTile(
                  title: Text(credit.name),
                  subtitle: Text(
                    credit.role?.isNotEmpty == true
                        ? credit.role!
                        : switch (credit.kind) {
                            MusicCreditKind.artist => t.common.mediaKind.artist,
                            MusicCreditKind.writer => t.explore.creditRole.writer,
                            MusicCreditKind.producer => t.explore.creditRole.producer,
                            MusicCreditKind.composer => t.explore.creditRole.composer,
                            MusicCreditKind.contributor => t.mediaMenu.viewDetails,
                          },
                  ),
                ),
              if (item.mediaVersions?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(t.fileSources.editions, style: Theme.of(context).textTheme.titleMedium),
                ),
              for (final version in item.mediaVersions ?? [])
                ListTile(
                  title: Text(version.name ?? version.id),
                  subtitle: Text(
                    [
                      version.container,
                      if (version.bitrate != null) ByteFormatter.formatBitrate(version.bitrate!),
                      ...version.parts.expand((part) => part.streams).map((stream) => stream.codec),
                    ].whereType<String>().where((text) => text.isNotEmpty).toSet().join(' · '),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
