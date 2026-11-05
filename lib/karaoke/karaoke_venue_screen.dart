import '../services/file_picker_service.dart';
import '../widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../i18n/strings.g.dart' as l10n;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';
import 'karaoke_collections.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

class KaraokeVenueScreen extends StatefulWidget {
  const KaraokeVenueScreen({super.key, required this.session});
  final KaraokeSession session;
  @override
  State<KaraokeVenueScreen> createState() => _KaraokeVenueScreenState();
}

class _KaraokeVenueScreenState extends State<KaraokeVenueScreen> {
  KaraokeSession get s => widget.session;
  late final collections = KaraokeCollections(s);
  bool busy = false;
  String? message;
  Future<void> run(Future<void> Function() action) async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      message = e.toString();
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<String?> text(String title, {String initial = '', bool obscure = false}) async {
    final input = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          autofocus: true,
          obscureText: obscure,
          maxLength: 160,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.t.auth.quickConnectCancel)),
          FilledButton(onPressed: () => Navigator.pop(context, input.text), child: Text(l10n.t.common.save)),
        ],
      ),
    );
    input.dispose();
    return value;
  }

  Future<void> editSet(String? existing) async {
    final name = existing ?? await text('Setlist name');
    if (name == null || name.trim().isEmpty || !mounted) {
      return;
    }
    final selected = (s.setlists[name] ?? []).toSet();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(name),
          content: SizedBox(
            width: 500,
            height: 400,
            child: ListView(
              children: [
                for (final t in s.search(''))
                  CheckboxListTile(
                    value: selected.contains(t.id),
                    title: Text(t.title),
                    subtitle: Text(t.artist),
                    onChanged: (v) => update(() => v! ? selected.add(t.id) : selected.remove(t.id)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t.auth.quickConnectCancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t.karaokeUi.saveSetlist)),
          ],
        ),
      ),
    );
    if (saved == true) {
      await run(() => s.host('setlist', {'name': name, 'tracks': selected.toList()}).then((_) {}));
    }
  }

  Future<void> importCollection() async {
    final files = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['plezycollection', 'json'],
    );
    final path = files?.files.single.path;
    if (path == null) {
      return;
    }
    final data = await collections.read(path);
    if (!mounted) {
      return;
    }
    final incoming = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t.karaokeUi.resolveCollectionConflicts),
        content: Text(l10n.t.karaokeUi.newSingersAndSetlistsWillBeAddedChooseWhich),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.t.karaokeUi.keepExistingPreferences),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t.karaokeUi.useImportedPreferences),
          ),
        ],
      ),
    );
    if (incoming != null) {
      await collections.merge(data, preferIncoming: incoming);
    }
  }

  Future<void> _fillers() async {
    final selected = s.fillerTrackIds.toSet(),
        choices = s.catalog.values.where((t) => t.assets.any((a) => a.kind == KaraokeAssetKind.instrumental)).toList();
    final ids = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.t.karaokeUi.instrumentalFiller),
          content: SizedBox(
            width: 500,
            height: 420,
            child: ListView(
              children: [
                for (final t in choices)
                  CheckboxListTile(
                    title: Text(t.title),
                    subtitle: Text(t.artist),
                    value: selected.contains(t.id),
                    onChanged: (v) => update(() {
                      if (v == true && selected.length < 16) {
                        selected.add(t.id);
                      } else if (v == false) {
                        selected.remove(t.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.t.auth.quickConnectCancel)),
            FilledButton(onPressed: () => Navigator.pop(context, selected.toList()), child: Text(l10n.t.common.save)),
          ],
        ),
      ),
    );
    if (ids != null) {
      await run(() => s.host('fillers', {'trackIds': ids}).then((_) {}));
    }
  }

  Future<void> kiosk() async {
    final pin = await text('Create a 4–12 digit kiosk exit PIN', obscure: true);
    if (pin == null) {
      return;
    }
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw const FormatException('Use 4–12 digits');
    }
    if (!mounted) {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _KaraokeKiosk(session: s, pin: pin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(l10n.t.karaokeUi.venueCollectionsAndReadiness)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message != null) SelectableText(message!),
          ListTile(
            title: Text(l10n.t.karaokeUi.stageBanner),
            subtitle: Text(s.banner),
            trailing: IconButton(
              icon: const AppIcon(Symbols.edit_rounded),
              onPressed: busy
                  ? null
                  : () => run(() async {
                      final value = await text('Stage banner', initial: s.banner);
                      if (value != null) {
                        await s.host('settings', {'banner': value});
                      }
                    }),
            ),
          ),
          Text(l10n.t.karaokeUi.stageTextSize),
          Slider(
            min: .75,
            max: 2,
            divisions: 25,
            value: s.stageTextScale,
            onChanged: busy ? null : (v) => run(() => s.host('settings', {'stageTextScale': v}).then((_) {})),
          ),
          Text(l10n.t.karaokeUi.displayOffsetMs(value1: (s.displayOffsetMs).toString())),
          Slider(
            min: -2000,
            max: 2000,
            divisions: 80,
            value: s.displayOffsetMs.toDouble().clamp(-2000, 2000),
            onChanged: busy ? null : (v) => run(() => s.host('settings', {'displayOffsetMs': v.round()}).then((_) {})),
          ),
          Wrap(
            spacing: 12,
            children: [
              for (final color in [0xff101018, 0xff001524, 0xff210b29, 0xff000000])
                OutlinedButton(
                  onPressed: busy ? null : () => run(() => s.host('settings', {'stageColor': color}).then((_) {})),
                  child: AppIcon(Symbols.circle_rounded, color: Color(color)),
                ),
            ],
          ),
          ListTile(
            title: Text(l10n.t.karaokeUi.perSingerPendingRequestLimit),
            trailing: DropdownButton<int>(
              value: s.perSingerLimit,
              items: [1, 2, 3, 5, 10].map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
              onChanged: busy ? null : (v) => run(() => s.host('settings', {'perSingerLimit': v}).then((_) {})),
            ),
          ),
          OutlinedButton(onPressed: busy ? null : () => run(kiosk), child: Text(l10n.t.karaokeUi.openRequestKiosk)),
          Text(l10n.t.karaokeUi.theKioskLimitsThisScreenToSongRequestsUse),
          const Divider(),
          Text(l10n.t.karaokeUi.savedSets, style: Theme.of(context).textTheme.titleLarge),
          TextButton(onPressed: busy ? null : () => editSet(null), child: Text(l10n.t.karaokeUi.createASetlist)),
          for (final e in s.setlists.entries)
            ListTile(
              title: Text(e.key),
              subtitle: Text(l10n.t.karaokeUi.songs(value1: (e.value.length).toString())),
              onTap: () => editSet(e.key),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: l10n.t.karaokeUi.queueThisSetlist,
                    onPressed: busy || s.singers.where((p) => !p.absent).isEmpty
                        ? null
                        : () => run(
                            () => s
                                .host('requestSetlist', {
                                  'name': e.key,
                                  'singers': [s.singers.firstWhere((p) => !p.absent).id],
                                })
                                .then((_) {}),
                          ),
                    icon: const AppIcon(Symbols.playlist_add_rounded),
                  ),
                  IconButton(
                    tooltip: l10n.t.karaokeUi.auditCompleteOfflineAssets,
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final errors = await collections.audit(e.value);
                            message = errors.isEmpty
                                ? 'Every rendition has local playback assets with matching checksums.'
                                : errors.join('\n');
                          }),
                    icon: const AppIcon(Symbols.offline_pin_rounded),
                  ),
                  IconButton(
                    tooltip: l10n.t.karaokeUi.removeSetlist,
                    onPressed: busy
                        ? null
                        : () => run(() => s.host('setlist', {'name': e.key, 'remove': true}).then((_) {})),
                    icon: const AppIcon(Symbols.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          const Divider(),
          Text(l10n.t.karaokeUi.instrumentalFiller, style: Theme.of(context).textTheme.titleLarge),
          Text(l10n.t.karaokeUi.playARotatingLocalInstrumentalWhileTheNextSinger),
          OutlinedButton(
            onPressed: busy ? null : () => _fillers(),
            child: Text(l10n.t.karaokeUi.fillerRenditionsSelected(value1: (s.fillerTrackIds.length).toString())),
          ),
          const Divider(),
          Text(l10n.t.karaokeUi.portability, style: Theme.of(context).textTheme.titleLarge),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final file = await FilePickerService.instance.saveFile(fileName: 'karaoke.plezycollection');
                        if (file != null) {
                          await collections.export(file);
                        }
                      }),
                child: Text(l10n.t.karaokeUi.exportSingersFavoritesAndSets),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => run(importCollection),
                child: Text(l10n.t.karaokeUi.importCollection),
              ),
              for (final format in ['csv', 'xml', 'html'])
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                          final file = await FilePickerService.instance.saveFile(fileName: 'songbook.$format');
                          if (file != null) {
                            await collections.catalog(file, format);
                          }
                        }),
                  child: Text(format == 'html' ? 'Print-ready songbook' : 'Catalog ${format.toUpperCase()}'),
                ),
            ],
          ),
          Text(l10n.t.karaokeUi.chooseAnExistingSyncedFolderInTheSystemFile),
          const Divider(),
          Text(l10n.t.fileSources.offlineStorageUsage, style: Theme.of(context).textTheme.titleLarge),
          for (final t in s.catalog.values.where((t) => t.assets.isNotEmpty))
            ListTile(
              title: Text(t.title),
              subtitle: Text(
                l10n.t.karaokeUi.mib(
                  value1: ((t.assets.fold<int>(0, (n, a) => n + a.bytes) / 1048576).toStringAsFixed(1)).toString(),
                ),
              ),
              trailing: TextButton(
                onPressed: busy || s.pinned.contains(t.id)
                    ? null
                    : () => run(() async {
                        await s.packages.evict(t.id, pinned: s.pinned);
                        s.catalog.remove(t.id);
                        await s.host('settings');
                      }),
                child: Text(l10n.t.karaokeUi.removePackage),
              ),
            ),
          const Divider(),
          Text(l10n.t.karaokeUi.thisBuild, style: Theme.of(context).textTheme.titleLarge),
          Text(l10n.t.karaokeUi.packageImportLyricStageCDGHostingQuizzesEditing),
          Text(
            PlatformDetector.isAppleTV() || PlatformDetector.isTizenBuild() || PlatformDetector.isWebOSBuild()
                ? 'Local microphone capture is unavailable in this TV build. Use external amplification. Key, tempo and stems require an MPV backend.'
                : 'Local microphone capture uses the native record plugin with explicit permission. Key, tempo and stems require an MPV backend. USB devices, Bluetooth latency and capture quality require device validation.',
          ),
          Text(l10n.t.karaokeUi.separationAlignmentAnalysisMIDIRenderingAndTakeProductionRequire),
        ],
      ),
    ),
  );
}

class _KaraokeKiosk extends StatefulWidget {
  const _KaraokeKiosk({required this.session, required this.pin});
  final KaraokeSession session;
  final String pin;
  @override
  State<_KaraokeKiosk> createState() => _KaraokeKioskState();
}

class _KaraokeKioskState extends State<_KaraokeKiosk> {
  String query = '';
  String? singer, message;
  bool unlocked = false, busy = false;
  Future<void> unlock() async {
    final input = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t.karaokeUi.hostExitPIN),
        content: TextField(controller: input, obscureText: true, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, input.text), child: Text(l10n.t.karaokeUi.unlock)),
        ],
      ),
    );
    input.dispose();
    if (value == widget.pin && mounted) {
      setState(() => unlocked = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pop(context);
        }
      });
    }
  }

  Future<void> request(KaraokeTrack track) async {
    if (singer == null || busy) {
      return;
    }
    setState(() => busy = true);
    try {
      final s = widget.session;
      await s.command('kiosk-${DateTime.now().microsecondsSinceEpoch}', s.revision, 'request', {
        'trackId': track.id,
      }, guestSinger: singer);
      message = l10n.t.karaokeUi.requestSentToTheHost;
    } catch (e) {
      message = e.toString();
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: unlocked,
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.t.karaokeUi.requestASong),
        actions: [
          IconButton(
            tooltip: l10n.t.karaokeUi.hostUnlock,
            onPressed: unlock,
            icon: const AppIcon(Symbols.lock_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (message != null) Padding(padding: const EdgeInsets.all(12), child: Text(message!)),
          DropdownButton<String>(
            value: singer,
            hint: Text(l10n.t.karaokeUi.chooseYourSingerName),
            items: widget.session.singers
                .where((p) => !p.absent)
                .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                .toList(),
            onChanged: (v) => setState(() => singer = v),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: InputDecoration(labelText: l10n.t.karaokeUi.searchSongs),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final track in widget.session.search(query))
                  ListTile(
                    title: Text(track.title),
                    subtitle: Text(track.artist),
                    trailing: FilledButton(
                      onPressed: busy || singer == null ? null : () => request(track),
                      child: Text(l10n.t.seerr.request),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
