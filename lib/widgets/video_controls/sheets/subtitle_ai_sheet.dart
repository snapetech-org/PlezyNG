import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../../../mpv/mpv.dart';
import '../../../media/ids.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../mpv/player/player_media_session_identity.dart';
import '../../../mpv/player/subtitle_pcm_capture_source.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_ai_service.dart';
import '../../../services/subtitle_placement_evidence.dart';
import '../../../services/subtitle_retimer.dart';
import '../../../services/subtitle_word_timing.dart';
import '../../../services/subtitle_sync_service.dart';
import '../../../services/subtitle_interval_service.dart';
import '../../../services/subtitle_job_service.dart';
import '../../../services/subtitle_editing_service.dart';
import '../../../services/subtitle_waveform_service.dart';
import '../../../services/subtitle_companion_service.dart';
import '../../../services/subtitle_translation_service.dart';
import '../../../services/subtitle_translation_memory.dart';
import '../../../services/subtitle_text_importer.dart';
import '../../../services/subtitle_discovery_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_playback_transcription_service.dart';
import '../../../services/subtitle_online_recognizer.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../utils/provider_extensions.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import 'base_video_control_sheet.dart';
import 'subtitle_jobs_dialog.dart';
import 'subtitle_waveform_editor.dart';
import 'subtitle_companion_jobs_dialog.dart';
import 'subtitle_study_dialog.dart';
import 'subtitle_overlay_dialog.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_download_assets.dart';
import '../../../providers/download_provider.dart';
import '../../../database/download_operations.dart';
import '../../../utils/global_key_utils.dart';
import '../../../services/subtitle_analysis_source.dart';
import '../../../services/subtitle_source_upload.dart';
import '../../../services/subtitle_read_ahead_service.dart';
import 'subtitle_import_dialog.dart';
import 'subtitle_bitmap_review_dialog.dart';
import 'subtitle_discovery_dialog.dart';
import 'subtitle_cloud_sync_dialog.dart';
import 'subtitle_resource_dialog.dart';
import 'subtitle_research_review_dialog.dart';
import 'subtitle_lyric_units_dialog.dart';
import 'subtitle_dictionary_dialog.dart';

/// Reviewable local subtitle operations. The source file is never modified;
/// every generated, translated, or synchronized result is written to a new
/// SRT that viewers may export or attach as a separate external track.
enum _SubtitleReviewChoice { discard, exportSrt, exportJson, overlayPrimary, overlaySecondary, player, serverAndPlayer, sourceAndPlayer }

typedef SubtitleSourceSubtitleSaver = Future<void> Function(String name, Uint8List bytes, String languageCode);

class _SubtitleOperationSnapshot {
  const _SubtitleOperationSnapshot({
    required this.player,
    required this.mediaSessionGeneration,
    required this.revisionIdentity,
  });

  final Player player;
  final int? mediaSessionGeneration;
  final SubtitleRevisionIdentity? revisionIdentity;

  bool isCurrent({
    required Player currentPlayer,
    required SubtitleRevisionIdentity? currentRevisionIdentity,
    required bool Function()? isRevisionIdentityCurrent,
  }) {
    if (!identical(player, currentPlayer)) return false;
    if (mediaSessionGeneration != null) {
      if (currentPlayer is! PlayerMediaSessionIdentity ||
          currentPlayer.mediaSessionGeneration != mediaSessionGeneration) {
        return false;
      }
    }
    if (currentRevisionIdentity?.storageKey != revisionIdentity?.storageKey) return false;
    return isRevisionIdentityCurrent?.call() != false;
  }
}

const _subtitleUndoCheckpointPrefix = 'Undo checkpoint: ';

Map<String, SubtitleCue> _subtitleCuesByStableId(List<SubtitleCue> cues) {
  final result = <String, SubtitleCue>{};
  for (final cue in cues) {
    if (result.containsKey(cue.stableId)) {
      throw const FormatException('Subtitle operation returned duplicate cue identities.');
    }
    result[cue.stableId] = cue;
  }
  return result;
}

void _requireSubtitleCueIdentityPreserved(List<SubtitleCue> source, List<SubtitleCue> translated) {
  if (source.length != translated.length) {
    throw StateError('Translation changed the cue count; no output was attached.');
  }
  final sourceById = _subtitleCuesByStableId(source);
  final translatedById = _subtitleCuesByStableId(translated);
  if (sourceById.length != translatedById.length) {
    throw StateError('Translation changed cue identities; no output was attached.');
  }
  for (final entry in sourceById.entries) {
    final translatedCue = translatedById[entry.key];
    if (translatedCue == null ||
        translatedCue.startMs != entry.value.startMs ||
        translatedCue.endMs != entry.value.endMs) {
      throw StateError('Translation changed cue identity or timing; no output was attached.');
    }
  }
}

List<SubtitleCue> _restoreOriginalCueTextWithAlignedTimes(
  List<SubtitleCue> original,
  List<SubtitleCue> aligned,
) {
  final alignedById = _subtitleCuesByStableId(aligned);
  if (alignedById.length != original.length) {
    throw const FormatException('Alignment changed cue identities, so the original text was left unchanged.');
  }
  final output = <SubtitleCue>[];
  for (final source in original) {
    final timing = alignedById.remove(source.stableId);
    if (timing == null) {
      throw const FormatException('Alignment lost a cue identity, so the original text was left unchanged.');
    }
    output.add(
      SubtitleCue(
        index: source.index,
        startMs: timing.startMs,
        endMs: timing.endMs,
        text: source.text,
        cueId: source.stableId,
      ),
    );
  }
  if (alignedById.isNotEmpty) {
    throw const FormatException('Alignment added cues, so the original text was left unchanged.');
  }
  return List<SubtitleCue>.unmodifiable(output);
}

class SubtitleAiSheet extends StatefulWidget {
  const SubtitleAiSheet({
    super.key,
    required this.player,
    this.serverId,
    this.ratingKey,
    this.mediaIndex = 0,
    this.mediaTitle,
    this.sourceLabel,
    this.revisionIdentity,
    this.isRevisionIdentityCurrent,
    this.onSaveToSource,
    this.openAnalysisSource,
    this.seriesKey,
    this.selectedSubtitleBurnedIn = false,
  });

  final Player player;
  final String? serverId;
  final String? ratingKey;
  final int mediaIndex;
  final String? mediaTitle;
  final String? sourceLabel;

  /// Optional device-local identity for standalone source media. Server
  /// attachment still requires [serverId] and [ratingKey].
  final SubtitleRevisionIdentity? revisionIdentity;
  /// Rejects playback results when a standalone source item changed mid-operation.
  final bool Function()? isRevisionIdentityCurrent;
  /// Persists and attaches a reviewed SRT to the active standalone source item.
  final SubtitleSourceSubtitleSaver? onSaveToSource;
  final Future<SubtitleAnalysisSource> Function()? openAnalysisSource;
  final String? seriesKey;
  final bool selectedSubtitleBurnedIn;

  @override
  State<SubtitleAiSheet> createState() => _SubtitleAiSheetState();
}

class _SubtitleAiSheetState extends State<SubtitleAiSheet> {
  _SubtitleOperationSnapshot? _operationSnapshot;
  SubtitleCompanionService? _activeCompanion;
  String? _activeCompanionJob;
  bool _busy = false;
  bool _translateSpeechToEnglish = false;
  bool _translationSupported = false;
  bool _allowMobileData = false;
  bool _requestTranslationCuda = false;
  bool _bilingualTranslation = false;
  bool _useTranslationMemory = false;
  bool _useSeriesGlossary = false;
  final TextEditingController _glossaryController = TextEditingController();
  final Map<String, String> _glossaryDrafts = <String, String>{};
  final Set<String> _temporaryWavPaths = <String>{};
  bool _playbackCaptureSupported = false;
  bool _lastResultUploadedToServer = false;
  bool _lastResultSavedToSource = false;
  String? _status;
  String? _error;
  String? _revisionStatus;
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  SubtitleInferenceProvider _liveProvider = SubtitleInferenceProvider.cpu;
  String? _streamingModelManifest;
  String _speechLanguageCode = 'auto';
  TranslateLanguage _sourceLanguage = TranslateLanguage.english;
  TranslateLanguage _targetLanguage = TranslateLanguage.spanish;

  @override
  void dispose() {
    _activeCompanion?.close();
    _glossaryController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCapabilityState());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadGlossaryForCurrentPair());
      if (mounted) unawaited(_loadSpeechLanguageForProfile());
    });
  }

  Future<void> _refreshCapabilityState() async {
    var translationSupported = false;
    var playbackCaptureSupported = false;
    final captureSource = widget.player;
    if (captureSource is SubtitlePcmCaptureSource) {
      try {
        playbackCaptureSupported = await (captureSource as SubtitlePcmCaptureSource).subtitlePcmCaptureAvailable();
      } catch (_) {
        playbackCaptureSupported = false;
      }
    }
    try {
      translationSupported =
          SubtitleTranslationService.desktopPlatformSupported ||
          await SubtitleTranslationService.isSupportedOnCurrentDevice();
    } catch (_) {
      translationSupported = false;
    }
    if (!mounted) return;
    setState(() {
      _translationSupported = translationSupported;
      _playbackCaptureSupported = playbackCaptureSupported;
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    final player = widget.player;
    final snapshot = _SubtitleOperationSnapshot(
      player: player,
      mediaSessionGeneration: player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null,
      revisionIdentity: _revisionIdentity,
    );
    _operationSnapshot = snapshot;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
      _revisionStatus = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = _readableError(error));
    } finally {
      await _deleteTemporaryWavCopies();
      if (identical(_operationSnapshot, snapshot)) _operationSnapshot = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _operationIdentityIsCurrent {
    final snapshot = _operationSnapshot;
    if (snapshot == null) return true;
    return snapshot.isCurrent(
      currentPlayer: widget.player,
      currentRevisionIdentity: _revisionIdentity,
      isRevisionIdentityCurrent: widget.isRevisionIdentityCurrent,
    );
  }

  void _requireCurrentOperationIdentity() {
    if (!_operationIdentityIsCurrent) {
      throw StateError(
        'Playback or profile changed while subtitle work was running. Reopen subtitle tools for the current item.',
      );
    }
  }

  SubtitleRevisionIdentity? get _operationRevisionIdentity {
    final snapshot = _operationSnapshot;
    return snapshot == null ? _revisionIdentity : snapshot.revisionIdentity;
  }

  Future<void> _deleteTemporaryWavCopies() async {
    final paths = _temporaryWavPaths.toList(growable: false);
    _temporaryWavPaths.clear();
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // The platform temporary directory remains subject to OS cleanup.
      }
    }
  }

  Future<void> _ensureSpeechModel() async {
    if (_provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu) return;
    if (await SubtitleAiService.instance.isModelInstalled()) return;
    if (mounted) setState(() => _status = 'Downloading the English speech model and speech detector…');
    await SubtitleAiService.instance.downloadModel(
      onProgress: (phase, received, total) {
        if (!mounted) return;
        final percent = total == 0 ? '' : ' (${(received * 100 / total).round()}%)';
        setState(() => _status = '$phase$percent');
      },
    );
  }

  Future<String?> _pickWav() async {
    final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: const ['wav']);
    if (!mounted || result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (p.extension(file.name).toLowerCase() != '.wav') {
      throw const FormatException('Choose a WAV file exported from the same title and audio track.');
    }
    if (file.path != null) return file.path!;
    final bytes = file.bytes;
    if (bytes == null || bytes.lengthInBytes < 44 || bytes.lengthInBytes > 256 * 1024 * 1024) {
      throw const FormatException('This platform did not provide a bounded local WAV file.');
    }
    final directory = await getTemporaryDirectory();
    final path = p.join(directory.path, 'subtitle_audio_${DateTime.now().microsecondsSinceEpoch}.wav');
    await File(path).writeAsBytes(bytes, flush: true);
    _temporaryWavPaths.add(path);
    return path;
  }

  Future<(List<SubtitleCue>, String, List<String>)?> _pickSubtitleCues({bool preview = false}) async {
    final result = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: SubtitleTextImporter.extensions,
      withData: true,
    );
    if (!mounted || result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final extension = p.extension(file.name).toLowerCase();
    if (!SubtitleTextImporter.extensions.contains(extension.replaceFirst('.', ''))) {
      throw const FormatException('Choose a supported text subtitle format.');
    }
    if (file.size <= 0 || file.size > SubtitleRetimer.maximumInputBytes) {
      throw const FormatException('Subtitle input must be between 1 byte and 5 MiB.');
    }
    Uint8List bytes;
    if (file.bytes != null) {
      bytes = Uint8List.fromList(file.bytes!);
    } else if (file.path != null) {
      final source = File(file.path!);
      if (await source.length() != file.size) {
        throw const FormatException('Subtitle file changed while it was being selected.');
      }
      bytes = await source.readAsBytes();
    } else {
      throw const FormatException('This platform did not provide subtitle file bytes.');
    }
    if (bytes.isEmpty || bytes.lengthInBytes > SubtitleRetimer.maximumInputBytes) {
      throw const FormatException('Subtitle input must be between 1 byte and 5 MiB.');
    }
    SubtitleTextImport? imported;
    if (!preview && SubtitleTextImporter.nativeTextExtensions.contains(extension)) {
      try { imported = await SubtitleTextImporter.parseAsync(bytes, extension); }
      on FormatException { /* Let the viewer explicitly select and preview an encoding. */ }
    }
    if (!mounted) return null;
    imported ??= await showDialog<SubtitleTextImport>(context: context,
      builder: (_) => SubtitleImportDialog(bytes: bytes, extension: extension, name: file.name));
    if (imported == null) return null;
    return (imported.cues, file.name, imported.warnings);
  }

  Future<void> _importTextSubtitle() => _run(() async {
    final selected = await _pickSubtitleCues(preview: true);
    if (selected == null || !mounted) return;
    await _writeAndApply(selected.$1, operationLabel: 'Imported text subtitle', reviewWarnings: selected.$3);
  });

  Future<void> _discoverSubtitles() => _run(() async {
    final profile = _activeProfileId;
    if (profile == null) throw StateError('Choose a profile before managing subtitle folders.');
    final path = await showDialog<String>(context: context,
      builder: (_) => SubtitleDiscoveryDialog(player: widget.player, profileId: profile,
        title: _operationRevisionIdentity?.mediaTitle,
        isCurrent: () => mounted && _activeProfileId == profile && _operationIdentityIsCurrent));
    if (path == null || !mounted) return;
    _requireCurrentOperationIdentity();
    if (_activeProfileId != profile) throw StateError('Profile changed before subtitle attachment.');
    final extension = p.extension(path).toLowerCase();
    if (widget.player.supportedLocalSubtitleExtensions.contains(extension.substring(1))) {
      await SubtitleDiscoveryService.validateBitmapPair(path);
      _requireCurrentOperationIdentity();
      await widget.player.command(['sub-add', path, 'select']);
      if (mounted) setState(() => _status = 'Attached ${p.basename(path)} from its original folder.');
    } else {
      final file = File(path);
      final size = await file.length();
      if (size <= 0 || size > SubtitleRetimer.maximumInputBytes) throw const FormatException('Text conversion is limited to 5 MiB.');
      final bytes = await file.readAsBytes();
      if (bytes.length != size) throw const FormatException('Subtitle changed during selection.');
      if (!mounted) return;
      final imported = await showDialog<SubtitleTextImport>(context: context,
        builder: (_) => SubtitleImportDialog(bytes: bytes, extension: extension, name: p.basename(path)));
      if (imported == null || !mounted) return;
      await _writeAndApply(imported.cues, operationLabel: 'Imported folder subtitle', reviewWarnings: imported.warnings);
    }
  });

  Future<void> _transcribe() => _run(() async {
    final wavPath = await _pickWav();
    if (wavPath == null || !mounted) return;
    await _ensureSpeechModel();
    final translateToEnglish =
        _translateSpeechToEnglish &&
        (_provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu);
    setState(
      () => _status = translateToEnglish
          ? 'Transcribing and translating speech to English locally…'
          : 'Transcribing speech locally on this device…',
    );
    final result = await SubtitleAiService.instance.transcribeWav(
      wavPath,
      provider: _provider,
      translateToEnglish: translateToEnglish,
      languageCode: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      onProgress: (phase, received, total) {
        if (!mounted) return;
        final percent = total == 0 ? '' : ' (${(received * 100 / total).round()}%)';
        setState(() => _status = '$phase$percent');
      },
    );
    if (!await _writeAndApply(
      result.cues,
      operationLabel: result.translatedToEnglish ? 'Speech translated to English' : 'Generated subtitles',
      operationLanguageCode: result.translatedToEnglish ? 'en' : result.detectedLanguage,
      wordTimings: result.wordTimings,
    )) {
      return;
    }
    if (!mounted) return;
    final providerLabel = result.fellBackToCpu
        ? '${result.requestedProvider.displayName} request unavailable; CPU fallback'
        : result.runtimeProvider.toUpperCase();
    setState(() {
      _status =
          'Generated ${result.cues.length} cues from ${(result.durationMs / 60000).ceil()} minutes of audio. '
          '${result.translatedToEnglish ? 'Speech translated to English' : 'Detected language: ${result.detectedLanguage}'}. '
          'Requested/initialized backend: $providerLabel. Placement evidence: ${result.placementEvidence.displayLabel}. '
          'Original audio remains unchanged.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _queueTranscription() => _run(() async {
    final identity = _operationRevisionIdentity;
    if (identity == null) throw StateError('Open a stable library item or local file to create a resumable job.');
    final profiles = context.read<ActiveProfileProvider>();
    final service = SubtitleJobService.instance..bindProfile(profiles);
    await service.ready;
    final wavPath = await _pickWav();
    if (wavPath == null || !mounted) return;
    var chargingOnly = false;
    var idleOnly = false;
    var followPlayhead = true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, update) => AlertDialog(
        title: const Text('Queue transcription'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('An owned copy of the WAV is retained until you delete the job. '
              'The queue saves each completed window and never attaches results automatically.'),
          SwitchListTile(title: const Text('Prioritize near the playhead'), value: followPlayhead,
              onChanged: (value) => update(() => followPlayhead = value)),
          SwitchListTile(title: const Text('Only on external power'), value: chargingOnly,
              onChanged: (value) => update(() => chargingOnly = value)),
          SwitchListTile(title: const Text('Only while playback is idle'), value: idleOnly,
              onChanged: (value) => update(() => idleOnly = value)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Queue')),
        ],
      )),
    );
    if (accepted != true || !mounted) return;
    _requireCurrentOperationIdentity();
    final player = widget.player;
    final session = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final profileId = profiles.activeId;
    await service.enqueue(
      wavPath: wavPath, identityKey: identity.storageKey, title: widget.mediaTitle ?? 'Subtitle transcription',
      provider: _provider, language: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      translateToEnglish: _translateSpeechToEnglish, chargingOnly: chargingOnly, idleOnly: idleOnly,
      playheadMs: !followPlayhead ? null : () => !player.disposed && profiles.activeId == profileId &&
          (session == null || (player as PlayerMediaSessionIdentity).mediaSessionGeneration == session)
          ? player.currentPosition.inMilliseconds : 0,
      playbackBusy: () => !player.disposed && player.state.playing,
    );
    if (mounted) setState(() => _status = 'Queued. Open Transcription jobs to pause, resume, cancel, or review saved windows.');
  });

  Future<void> _manageTranscriptionJobs() => _run(() async {
    final service = SubtitleJobService.instance..bindProfile(context.read<ActiveProfileProvider>());
    await service.ready;
    if (!mounted) return;
    final player = widget.player;
    final session = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final job = await showDialog<SubtitleJob>(context: context, builder: (_) => SubtitleJobsDialog(
      identityKey: _operationRevisionIdentity?.storageKey,
      playheadMs: () => !player.disposed &&
          (session == null || (player as PlayerMediaSessionIdentity).mediaSessionGeneration == session)
          ? player.currentPosition.inMilliseconds : 0,
      playbackBusy: () => !player.disposed && player.state.playing,
    ));
    if (job == null || !mounted) return;
    _requireCurrentOperationIdentity();
    if (job.identityKey != _operationRevisionIdentity?.storageKey) throw StateError('This job belongs to another item.');
    // Pause while reading a partial result so its coverage and words form one checkpoint.
    if (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued) await service.pause(job);
    final result = await service.readResult(job);
    final complete = job.state == SubtitleJobState.completed;
    await _writeAndApply(result.cues,
      operationLabel: complete ? 'Queued transcription' : 'Partial queued transcription',
      operationLanguageCode: result.detectedLanguage,
      wordTimings: result.wordTimings,
      reviewWarnings: [
        if (!complete) 'Only ${job.completedChunks} of ${job.chunkCount} audio windows are included. Unprocessed ranges have no captions.',
        'Backend: ${result.runtimeProvider}. ${result.placementEvidence.displayLabel}.',
      ],
    );
  });

  Future<SubtitleAudioInterval?> _chooseAudioInterval(int durationMs) async {
    if (durationMs <= 0) throw const FormatException('The WAV duration is unavailable.');
    final playbackPositionMs = widget.player.currentPosition.inMilliseconds;
    final latestStartMs = (durationMs - 60000).clamp(0, durationMs - 1).toInt();
    final startMs = playbackPositionMs.clamp(0, latestStartMs).toInt();
    final endMs = (startMs + 60000).clamp(startMs + 1, durationMs).toInt();
    final startController = TextEditingController(text: SubtitleAudioInterval.formatTimecode(startMs));
    final endController = TextEditingController(text: SubtitleAudioInterval.formatTimecode(endMs));
    String? error;
    try {
      return await showDialog<SubtitleAudioInterval>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Choose audio interval'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Only this audio range is analyzed. Existing subtitle cues outside it are preserved.'),
                const SizedBox(height: 12),
                TextField(
                  controller: startController,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'Start', hintText: 'HH:MM:SS'),
                ),
                TextField(
                  controller: endController,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'End', hintText: 'HH:MM:SS'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final interval = SubtitleAudioInterval.parse(
                    startController.text,
                    endController.text,
                    durationMs: durationMs,
                  );
                  if (interval == null) {
                    setDialogState(() => error = 'Enter a valid range inside the WAV duration.');
                    return;
                  }
                  Navigator.of(dialogContext).pop(interval);
                },
                child: const Text('Use interval'),
              ),
            ],
          ),
        ),
      );
    } finally {
      startController.dispose();
      endController.dispose();
    }
  }

  Future<void> _transformSubtitles() => _run(() async {
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    var reflow = false, spacing = false, descriptions = false, songs = false, credits = false;
    var width = 42.0, speed = 20.0;
    var fps = 'none';
    String? validation;
    final corrections = TextEditingController(text: '{}');
    SubtitleEditOptions? options;
    try {
      options = await showDialog<SubtitleEditOptions>(context: context, builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const Text('Preview caption transformations'),
          content: SizedBox(width: 600, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('All transformations are off by default. The original is retained; review and edit the derived result before saving.'),
            SwitchListTile(title: const Text('Reflow plain text into up to two lines'), value: reflow, onChanged: (v) => update(() => reflow = v)),
            Text('Line limit: ${width.round()} characters'),
            Slider(value: width, min: 24, max: 64, divisions: 40, label: '${width.round()}', onChanged: (v) => update(() => width = v)),
            Text('Reading-speed warning: ${speed.round()} characters/second'),
            Slider(value: speed, min: 8, max: 40, divisions: 32, label: '${speed.round()}', onChanged: (v) => update(() => speed = v)),
            SwitchListTile(title: const Text('Normalize spacing'), value: spacing, onChanged: (v) => update(() => spacing = v)),
            SwitchListTile(title: const Text('Remove bracketed descriptions'), subtitle: const Text('Can remove dialogue in parentheses; review required'), value: descriptions, onChanged: (v) => update(() => descriptions = v)),
            SwitchListTile(title: const Text('Remove lines marked with musical notes'), value: songs, onChanged: (v) => update(() => songs = v)),
            SwitchListTile(title: const Text('Remove explicit subtitle-credit/URL lines'), subtitle: const Text('English credit labels and standalone URLs only'), value: credits, onChanged: (v) => update(() => credits = v)),
            DropdownButtonFormField<String>(
              initialValue: fps, decoration: const InputDecoration(labelText: 'Explicit FPS conversion'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('No frame-rate conversion')),
                DropdownMenuItem(value: '23.976:25', child: Text('23.976 → 25')),
                DropdownMenuItem(value: '25:23.976', child: Text('25 → 23.976')),
                DropdownMenuItem(value: '24:25', child: Text('24 → 25')),
                DropdownMenuItem(value: '25:24', child: Text('25 → 24')),
                DropdownMenuItem(value: '23.976:24', child: Text('23.976 → 24')),
                DropdownMenuItem(value: '24:23.976', child: Text('24 → 23.976')),
              ], onChanged: (v) => update(() => fps = v ?? 'none'),
            ),
            const SizedBox(height: 12),
            TextField(controller: corrections, maxLines: 4, maxLength: 16384,
                decoration: const InputDecoration(labelText: 'Explicit spelling/term corrections (JSON)', hintText: '{"teh": "the"}')),
            if (validation != null) Text(validation!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () {
              try {
                final decoded = jsonDecode(corrections.text);
                if (decoded is! Map<String, dynamic> || decoded.length > 256 || decoded.values.any((v) => v is! String)) {
                  throw const FormatException('Use up to 256 text-to-text corrections.');
                }
                double rate(String value) => value == '23.976' ? 24000 / 1001 : double.parse(value);
                final rates = fps == 'none' ? null : fps.split(':');
                Navigator.pop(dialogContext, SubtitleEditOptions(
                  reflow: reflow, charactersPerLine: width.round(), charactersPerSecond: speed.round(),
                  normalizeSpacing: spacing, removeDescriptions: descriptions, removeSongs: songs, removeCredits: credits,
                  replacements: decoded.cast<String, String>(),
                  fpsFrom: rates == null ? null : rate(rates[0]), fpsTo: rates == null ? null : rate(rates[1]),
                ));
              } catch (_) { update(() => validation = 'Enter a JSON object with text keys and text values.'); }
            }, child: const Text('Preview')),
          ],
        ),
      ));
    } finally { corrections.dispose(); }
    if (options == null || !mounted) return;
    final result = SubtitleEditingService.transform(selected.$1, options);
    final retainedIds = result.cues.map((cue) => cue.stableId).toSet();
    await _writeAndApply(result.cues,
      operationLabel: 'Caption transformations',
      sourceCues: result.removed == 0 ? selected.$1 : null,
      reviewWarnings: [
        '${result.changed} cues changed; ${result.removed} cues removed. Original: ${selected.$2}.',
        ...selected.$1.where((cue) => !retainedIds.contains(cue.stableId)).take(20)
            .map((cue) => 'Removed cue ${cue.index}: ${cue.text}'),
        ...result.warnings,
      ],
    );
  });

  Future<void> _reviewDictionarySpelling() => _run(() async {
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    _requireCurrentOperationIdentity();
    final review = await showDialog<SubtitleDictionaryReview>(context: context, builder: (_) => SubtitleDictionaryDialog(
      cues: selected.$1, isCurrent: () => mounted && _operationIdentityIsCurrent));
    if (review == null || !mounted) return;
    _requireCurrentOperationIdentity();
    await _writeAndApply(review.cues, operationLabel: 'Reviewed offline dictionary corrections', sourceCues: selected.$1,
      reviewWarnings: ['${review.changed} explicitly selected word occurrences changed. Source: ${selected.$2}.',
        'Dictionary: ${review.pack.title} (${review.pack.language}); SHA-256 ${review.pack.digest}.',
        'Vocabulary misses and one-edit suggestions are not proof of misspelling. Styled cues were left unchanged.']);
  });

  Future<void> _editWaveform() => _run(() async {
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    final path = await _pickWav();
    if (path == null || !mounted) return;
    final duration = await SubtitleAiService.instance.readWavDurationMs(path);
    final interval = await _chooseAudioInterval(duration);
    if (interval == null || !mounted) return;
    setState(() => _status = 'Computing the waveform and spectrogram locally…');
    final waveform = await SubtitleWaveformService.analyze(path, startMs: interval.startMs, endMs: interval.endMs);
    if (!mounted) return;
    final cues = await showDialog<List<SubtitleCue>>(context: context,
      builder: (_) => SubtitleWaveformEditor(waveform: waveform, cues: selected.$1));
    if (cues == null || !mounted) return;
    await _writeAndApply(cues, operationLabel: 'Waveform timing edit', sourceCues: selected.$1,
      reviewWarnings: const ['Cue boundaries were edited against audio energy; no automatic word alignment was inferred.']);
  });

  Future<void> _configureCompanion() => _run(() async {
    final profile = _activeProfileId;
    if (profile == null) throw StateError('Choose an active profile before pairing a companion.');
    final existing = await SubtitleCompanionService.load(profile);
    final address = TextEditingController(text: existing?.endpoint.toString() ?? 'https://');
    final token = TextEditingController();
    existing?.close();
    if (!mounted) { address.dispose(); token.dispose(); return; }
    String? error;
    var saving = false;
    var remember = true;
    try {
      await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const Text('Pair subtitle companion'),
          content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Use a host you control. Media is sent only after you choose a file and submit a job. '
                'The host retains that file until you delete the job. Its token is stored in the OS credential store.'),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'Host URL'), keyboardType: TextInputType.url),
            TextField(controller: token, obscureText: true, enableSuggestions: false, autocorrect: false,
                decoration: const InputDecoration(labelText: 'Pairing token')),
            SwitchListTile(title: const Text('Remember pairing in the OS credential store'),
              subtitle: const Text('Turn off for a session-only pairing on devices without a credential plugin'),
              value: remember, onChanged: saving ? null : (value) => update(() => remember = value)),
            if (saving) const LinearProgressIndicator(),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ])),
          actions: [
            TextButton(onPressed: saving ? null : () async {
              update(() => saving = true);
              try { await SubtitleCompanionService.forget(profile); if (dialogContext.mounted) Navigator.pop(dialogContext); }
              catch (_) { if (dialogContext.mounted) update(() { saving = false; error = 'The saved pairing could not be removed.'; }); }
            }, child: const Text('Forget')),
            TextButton(onPressed: saving ? null : () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: saving ? null : () async {
              update(() { saving = true; error = null; });
              try {
                if (_activeProfileId != profile) throw StateError('Active profile changed.');
                await SubtitleCompanionService.configure(profile, address.text, token.text.trim(), remember: remember);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (failure) {
                if (dialogContext.mounted) update(() { saving = false; error = _readableError(failure); });
              }
            }, child: const Text('Save pairing')),
          ],
        ),
      ));
    } finally { address.dispose(); token.dispose(); }
  });

  Future<SubtitleCompanionService> _pairedCompanion() async {
    final profile = _activeProfileId;
    if (profile == null) throw StateError('An active profile is required.');
    final service = await SubtitleCompanionService.load(profile);
    if (service == null) throw StateError('Pair a subtitle companion before submitting a job.');
    return service;
  }

  Future<void> _submitCompanion(String task) => _run(() async {
    final identity = _operationRevisionIdentity;
    if (identity == null) throw StateError('Open a stable library item or local file before submitting a job.');
    final service = await _pairedCompanion();
    _activeCompanion = service;
    _activeCompanionJob = null;
    try {
      final capabilities = await service.capabilities();
      if (!(capabilities['tasks'] as List).contains(task)) throw UnsupportedError('Install the $task backend on the companion first.');
      final textTask = SubtitleCompanionService.textTasks.contains(task);
      final modelProvider = capabilities['translationProvider'];
      if (task == 'translate_model' && (modelProvider is! Map || modelProvider['fingerprint'] is! String || modelProvider['destination'] is! String)) {
        throw const FormatException('The companion did not declare its translation destination.');
      }
      List<SubtitleCue> cues = const [];
      if (task == 'align' || task == 'singing_align' || task == 'completeness' || task == 'dub_mix' || task == 'scene_review' || textTask) {
        final selected = await _pickSubtitleCues();
        if (selected == null || !mounted) return;
        cues = selected.$1;
      }
      String? path;
      var timelineOffsetMs = 0;
      var useCurrentSource = false;
      if (!textTask && cues.isEmpty && widget.openAnalysisSource != null && capabilities['sourceTimelineOffsets'] == true && task != 'bitmap_ocr' && mounted) {
        final choice = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('Choose companion input'),
          content: const Text('Use the current VOD file through its owning source transport, or choose a matching file. '
            'The current-file option copies at most 1 GiB / one hour to temporary storage, then uploads after review. '
            'It may use additional bandwidth and cannot copy a playlist, live stream or protected source.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Choose a matching file')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use current source file'))]));
        if (choice == null || !mounted) return;
        useCurrentSource = choice;
      }
      if (useCurrentSource) {
        _requireCurrentOperationIdentity();
        bool current() { try { _requireCurrentOperationIdentity(); return mounted && !service.isClosed; } catch (_) { return false; } }
        final source = await widget.openAnalysisSource!();
        final copy = await SubtitleSourceUpload.stage(source, isCurrent: current, onProgress: (bytes, total) {
          if (mounted) setState(() => _status = 'Preparing source upload: ${total == null ? "${bytes ~/ (1024 * 1024)} MiB" : "${(bytes * 100 / total).round()}%"}');
        });
        path = copy.file.path; timelineOffsetMs = copy.timelineOffsetMs;
        _temporaryWavPaths.add(path);
      }
      if (!textTask && !useCurrentSource) {
        if (task == 'bitmap_ocr' && mounted) setState(() => _status = 'Choose PGS SUP, a video container, or a ZIP containing one matching VobSub IDX/SUB pair.');
        final selected = await FilePickerService.instance.pickFiles(type: FileType.any);
        if (selected == null || selected.files.isEmpty || !mounted) return;
        final file = selected.files.first;
        if (file.size <= 0 || file.size > SubtitleCompanionService.maximumInputBytes) throw const FormatException('Choose media up to 1 GiB and one hour.');
        path = file.path;
        if (path == null) {
          final bytes = file.bytes;
          if (bytes == null || bytes.length > 256 * 1024 * 1024) throw const FormatException('The picker did not expose a bounded local media file.');
          final temp = await getTemporaryDirectory();
          path = p.join(temp.path, 'subtitle_companion_${DateTime.now().microsecondsSinceEpoch}.media');
          await File(path).writeAsBytes(bytes, flush: true);
          _temporaryWavPaths.add(path);
        }
      }
      if (!mounted) return;
      var preprocess = false;
      var soundStereoEvidence = false;
      var sceneTemporalRegions = false;
      var sceneAudioEvidence = false;
      var sceneMotionTracking = false;
      var sceneObjectTracking = false;
      var lyricSyllables = <String, List<String>>{};
      var lyricPitchEvidence = false;
      var duckRatio = .25;
      var track = 0;
      var subtitleTrack = 0, bitmapTail = 2000;
      var translationMode = 'faithful', scriptConversion = 's2t', readingMode = 'hiragana';
      var cropTop = 0.65;
      final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: Text('Send $task job to companion'),
          content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Destination: ${service.endpoint}\n${path == null ? 'Subtitle text' : 'The selected media file'} will be uploaded and retained on this host until you delete the job. '
                'No playback URL or media-server credentials are shared.${useCurrentSource ? " The opened part offset ($timelineOffsetMs ms) will be retained in generated cue times." : ""}'),
            if ({'ensemble', 'separate', 'sound_events', 'completeness', 'signs'}.contains(task))
              const Text('Experimental evidence: model suggestions need review. Separation is limited to five minutes and speaker numbering is local to each window. '
                'Sound labels do not identify direction or a verified source. Recognition glossary keys are hints, not spelling guarantees.'),
            if (task == 'align') Text('Only use text matching the spoken ${SubtitleTranslationService.languageLabel(_sourceLanguage)} audio, '
                'with approximate cue intervals no longer than 60 seconds. Unsupported/uncertain cues keep their original timing.'),
            if (task == 'singing_align') Text('Use lyrics matching the sung ${SubtitleTranslationService.languageLabel(_sourceLanguage)} audio. '
                'Maximum five minutes, 120 cues, 30 seconds per cue. A configured local CTC model compares original and percussive-suppressed audio. '
                'Only agreeing word boundaries are proposed; lyric text and cue bounds stay unchanged. This is experimental, not verified singing alignment.'),
            if (task == 'singing_align' && capabilities['lyricSyllables'] == true) ...[
              TextButton(onPressed: () async {
                try {
                  final selected = await showSubtitleLyricUnits(dialogContext, cues, lyricSyllables);
                  if (selected != null && dialogContext.mounted) update(() => lyricSyllables = selected);
                } catch (error) {
                  if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text(_readableError(error))));
                }
              }, child: Text('Supply syllable groups (${lyricSyllables.length} cues)')),
              if (lyricSyllables.isNotEmpty) TextButton(onPressed: () => update(() => lyricSyllables = {}), child: const Text('Keep word proposals only')),
            ],
            if (task == 'singing_align' && capabilities['lyricPitchEvidence'] == true) SwitchListTile(
              title: const Text('Include mix pitch candidates'),
              subtitle: const Text('At most 12 seconds per cue and two minutes total. Compares monophonic pitch estimates in both audio views. '
                'Instruments and octave errors can dominate; candidates are evidence only and do not change lyrics or cue timing.'),
              value: lyricPitchEvidence, onChanged: (value) => update(() => lyricPitchEvidence = value)),
            if (task == 'translate') Text('Translate ${SubtitleTranslationService.languageLabel(_sourceLanguage)} to ${SubtitleTranslationService.languageLabel(_targetLanguage)} using an installed host language pair.'),
            if (task == 'translate_model') ...[
              Text('The companion will forward subtitle text, neighboring dialogue and protected glossary markers to:\n'
                  '${(modelProvider as Map)['destination']}\nModel: ${modelProvider['model']}\n'
                  'Revision declared by the host: ${modelProvider['declaredRevision']}. Provider retention and charges apply if configured. No media audio or playback credentials are forwarded.'),
              Text('Translate ${SubtitleTranslationService.languageLabel(_sourceLanguage)} to ${SubtitleTranslationService.languageLabel(_targetLanguage)}. '
                  'The model’s actual language quality is not qualified by this app.'),
              DropdownButtonFormField<String>(initialValue: translationMode, decoration: const InputDecoration(labelText: 'Translation mode'),
                items: const [DropdownMenuItem(value: 'faithful', child: Text('Faithful · retain meaning and tone')),
                  DropdownMenuItem(value: 'natural', child: Text('Natural · idiomatic subtitle wording')),
                  DropdownMenuItem(value: 'literal', child: Text('Literal · language-learning correspondence'))],
                onChanged: (value) => update(() => translationMode = value ?? 'faithful')),
              TextField(controller: _glossaryController, maxLines: 4, maxLength: 65536,
                decoration: const InputDecoration(labelText: 'Protected glossary (JSON source → target pairs)',
                  helperText: 'Up to 200 plain-text terms, 128 characters each. This job records its glossary digest.')),
            ],
            if (task == 'script_convert') ...[
              const Text('Convert Chinese script/region conventions as a separate track. This is not semantic translation. Native layout remains in the original.'),
              DropdownButtonFormField<String>(initialValue: scriptConversion, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Explicit script/region conversion'),
                items: (const <String, String>{'s2t': 'Simplified → Traditional', 't2s': 'Traditional → Simplified',
                  's2tw': 'Simplified → Taiwan characters', 'tw2s': 'Taiwan → Simplified',
                  's2hk': 'Simplified → Hong Kong', 'hk2s': 'Hong Kong → Simplified',
                  't2tw': 'Traditional → Taiwan characters', 't2hk': 'Traditional → Hong Kong',
                  's2twp': 'Simplified → Taiwan characters and phrases', 'tw2sp': 'Taiwan phrases → Simplified'}).entries
                    .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (value) => update(() => scriptConversion = value ?? 's2t')),
            ],
            if (task == 'reading') ...[
              const Text('Add dictionary-derived Japanese reading aids to a separate SRT. Names and ambiguous readings need review; the original is unchanged.'),
              DropdownButtonFormField<String>(initialValue: readingMode, decoration: const InputDecoration(labelText: 'Reading display'),
                items: [const DropdownMenuItem(value: 'hiragana', child: Text('Inline kana after kanji')),
                  const DropdownMenuItem(value: 'hepburn', child: Text('Original + Hepburn romanization line')),
                  if (capabilities['readingModes'] is List && (capabilities['readingModes'] as List).contains('ruby'))
                    const DropdownMenuItem(value: 'ruby', child: Text('Ruby readings above base text in app overlays'))],
                onChanged: (value) => update(() => readingMode = value ?? 'hiragana')),
            ],
            if (task == 'scene_review') Text('The host will forward up to 30 chosen captions and ${sceneTemporalRegions ? 3 : 1} resized video frame(s) per cue to:\n'
              '${capabilities['visionProvider']}. ${sceneAudioEvidence ? "Selected-track audio clips will also be forwarded (12 seconds per cue, two minutes total). Joint model interpretation remains unverified." : "This is unverified image context; images cannot verify spoken words."} '
              'Original wording remains unless you select an alternative during image review.'),
            if (task == 'scene_review' && capabilities['sceneAudioEvidence'] == true)
              SwitchListTile(title: const Text('Include synchronized audio with scene images'),
                subtitle: const Text('Explicitly forwards each selected cue’s audio to the declared destination. Provider modality support is host-declared, not verified. Listen to the source before accepting alternatives.'),
                value: sceneAudioEvidence, onChanged: (v) => update(() => sceneAudioEvidence = v)),
            if (task == 'scene_review' && capabilities['sceneTemporalRegions'] == true)
              SwitchListTile(title: const Text('Sample scene movement during each cue'),
                subtitle: const Text('Sends three frames at 10%, 50% and 90% of each cue (the first is 0% when motion tracking is enabled). Evidence shows chronological panels; sampled region associations remain unverified.'),
                value: sceneTemporalRegions, onChanged: (v) => update(() => sceneTemporalRegions = v)),
            if (task == 'scene_review' && capabilities['sceneMotionTracking'] == true)
              SwitchListTile(title: const Text('Track region motion locally on the companion'),
                subtitle: const Text('Uses the first cue frame as a seed, then tracks texture at 12 Hz for up to 12 seconds per cue / two minutes total. '
                  'Extra tracking frames stay on the companion. Paths stop when matching fails; placement uses fixed envelopes. This can drift and needs review.'),
                value: sceneMotionTracking, onChanged: (v) => update(() => sceneMotionTracking = v)),
            if (task == 'scene_review' && capabilities['sceneObjectTracking'] == true) SwitchListTile(
              title: const Text('Track anonymous object classes locally'),
              subtitle: const Text('Uses the companion’s local CPU detector at 2 Hz, up to 12 seconds per cue / two minutes total. '
                'Class, appearance and overlap may recover short gaps up to 1.5 seconds. Similar objects, cuts and occlusion can break matching. '
                'Extra frames stay on the companion; labels and paths require review.'),
              value: sceneObjectTracking, onChanged: (value) => update(() => sceneObjectTracking = value)),
            if (task == 'ocr_auto') const Text('Find a repeatedly occupied text band using samples from the first two minutes. '
              'This can select credits or signs; inspect the returned cue images before accepting.'),
            if (task == 'dubbing' || task == 'dub_mix') ...[
              Text('Synthesize a separate audio product from already-reviewed spoken-language subtitles. Maximum ten minutes / 500 cues. '
                'This is a generic synthetic voice, not the original speaker or lip synchronization. '
                'Voice: ${capabilities['synthesisVoice']}. The host voice fingerprint is bound to this request.'),
              if (task == 'dub_mix') ...[
                Text('Keep ${(duckRatio * 100).round()}% of original audio under synthesized speech'),
                Slider(value: duckRatio, min: 0, max: 1, onChanged: (v) => update(() => duckRatio = v)),
              ],
            ],
            if (task == 'sound_events' && capabilities['soundStereoEvidence'] == true) SwitchListTile(
              title: const Text('Include stereo mix evidence'),
              subtitle: const Text('Measures repeated left/right energy dominance in a stereo rendering. It cannot identify a sound’s physical direction or isolate it from the rest of the mix.'),
              value: soundStereoEvidence, onChanged: (v) => update(() => soundStereoEvidence = v)),
            if (task == 'diarize') const Text('Speaker numbers are anonymous clusters and can be wrong. The host may require separately licensed model access.'),
            if (path != null && task != 'ocr' && task != 'bitmap_ocr') ...[
              DropdownButtonFormField<int>(initialValue: track, decoration: const InputDecoration(labelText: 'Audio stream (zero based)'),
                items: List.generate(16, (i) => DropdownMenuItem(value: i, child: Text('Audio stream $i'))),
                onChanged: (value) => update(() => track = value ?? 0)),
              SwitchListTile(title: const Text('High-pass and FFT denoise'), subtitle: const Text('Optional preprocessing can alter speech; original media stays intact'),
                value: preprocess, onChanged: (value) => update(() => preprocess = value)),
            ],
            if (task == 'ocr' || task == 'signs') ...[
              const Text('Burned-caption OCR samples the selected full-width crop at two frames per second. It does not decode PGS/VobSub tracks.'),
              Text('Crop starts at ${(cropTop * 100).round()}% of image height and extends to the bottom'),
              Slider(value: cropTop, min: 0, max: 0.9, divisions: 18, label: '${(cropTop * 100).round()}%',
                onChanged: (value) => update(() => cropTop = value)),
            ],
            if (task == 'bitmap_ocr' || task == 'extract_text') ...[
              if (task == 'bitmap_ocr') const Text('Decode PGS SUP or a PGS/VobSub stream in the selected container. For VobSub sidecars, upload a ZIP containing exactly one matching IDX/SUB pair. Original caption images are retained for OCR correction and export.'),
              DropdownButtonFormField<int>(initialValue: subtitleTrack, decoration: const InputDecoration(labelText: 'Subtitle stream (zero based)'),
                items: List.generate(16, (i) => DropdownMenuItem(value: i, child: Text('Subtitle stream $i'))),
                onChanged: (value) => update(() => subtitleTrack = value ?? 0)),
              if (task == 'bitmap_ocr') DropdownButtonFormField<int>(initialValue: bitmapTail, decoration: const InputDecoration(labelText: 'Last cue duration only if its end is missing'),
                items: [1000, 2000, 3000, 5000, 10000, 30000].map((ms) => DropdownMenuItem(value: ms, child: Text('$ms ms'))).toList(),
                onChanged: (value) => update(() => bitmapTail = value ?? 2000)),
              if (task == 'bitmap_ocr') Text('Caption language: ${SubtitleTranslationService.languageLabel(_sourceLanguage)}. Install matching Tesseract language data and select it on the host.'),
              if (task == 'extract_text') const Text('Convert an embedded text stream, such as mov_text, into a separate SRT. Layout and caption-service behavior may be flattened; bitmap streams require OCR.'),
            ],
            Text('Host backends: ${(capabilities['tasks'] as List).join(', ')}. Hardware placement is unverified.'),
          ]))),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(task == 'translate_model' ? 'Forward text and translate' : 'Send and process'))],
        ),
      ));
      if (accepted != true || !mounted) return;
      _requireCurrentOperationIdentity();
      final id = await service.submit(task: task, identityKey: identity.storageKey, mediaPath: path, cues: cues,
        language: task == 'script_convert' ? 'zh' : task == 'reading' ? 'ja'
            : task == 'align' || task == 'singing_align' || task == 'dub_mix' || textTask || task == 'bitmap_ocr' ? _sourceLanguage.bcpCode.split('-').first
            : (_speechLanguageCode == 'auto' ? null : _speechLanguageCode),
        targetLanguage: task == 'translate' || task == 'translate_model' ? _targetLanguage.bcpCode.split('-').first : null,
        translateToEnglish: task == 'transcribe' && _translateSpeechToEnglish,
        preprocess: preprocess, audioTrack: track, timelineOffsetMs: timelineOffsetMs, itemTimeline: useCurrentSource, soundStereoEvidence: soundStereoEvidence, sceneTemporalRegions: sceneTemporalRegions, sceneAudioEvidence: sceneAudioEvidence, sceneMotionTracking: sceneMotionTracking, crop: [0, cropTop, 1, 1 - cropTop],
        subtitleTrack: subtitleTrack, finalBitmapDurationMs: bitmapTail, duckRatio: duckRatio,
        lyricSyllables: lyricSyllables, lyricPitchEvidence: lyricPitchEvidence,
        sceneObjectTracking: sceneObjectTracking,
        sceneDetectorFingerprint: sceneObjectTracking ? (capabilities['sceneObjectDetector'] as Map?)?['fingerprint'] as String? : null,
        voiceFingerprint: (task == 'dubbing' || task == 'dub_mix') ? (capabilities['synthesisVoice'] as Map?)?['fingerprint'] as String? : null,
        translationMode: translationMode, scriptConversion: scriptConversion, readingMode: readingMode,
        visionProviderFingerprint: task == 'scene_review' ? (capabilities['visionProvider'] as Map?)?['fingerprint'] as String? : null,
        translationProviderFingerprint: task == 'translate_model' ? (modelProvider as Map)['fingerprint'] as String : null,
        glossary: {'translate_model', 'transcribe', 'ensemble', 'separate'}.contains(task) ? _parseGlossary() : const {},
        onCreated: (id) { if (mounted) setState(() => _activeCompanionJob = id); },
        onUpload: (sent, total) { if (mounted) setState(() => _status = 'Uploading chosen media: ${(sent * 100 / total).round()}%'); },
      );
      if (mounted) setState(() => _status = 'Companion job $id submitted. Open Companion jobs to cancel, resume, or review its result.');
    } finally { service.close(); _activeCompanion = null; _activeCompanionJob = null; }
  });

  Future<void> _cancelCompanionUpload() async {
    final active = _activeCompanion;
    final id = _activeCompanionJob;
    try {
      await active?.cancelAndClose(id);
      if (mounted) setState(() => _status = 'Companion job cancelled. Delete it in Companion jobs to remove retained media.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Upload stopped. Check Companion jobs to confirm the host cancelled processing.');
    }
  }

  Future<void> _showCompanionJobs() => _run(() async {
    final service = await _pairedCompanion();
    try {
      if (!mounted) return;
      final job = await showDialog<Map<String, dynamic>>(context: context,
        builder: (_) => SubtitleCompanionJobsDialog(service: service, identityKey: _operationRevisionIdentity?.storageKey));
      if (job == null || !mounted) return;
      _requireCurrentOperationIdentity();
      final identity = _operationRevisionIdentity;
      if (identity == null || job['identity'] != identity.storageKey) throw StateError('The job belongs to another item.');
      final result = await service.result(job['id'] as String, identityKey: identity.storageKey, audioDigest: job['audioDigest'] as String);
      if (!mounted) return;
      _requireCurrentOperationIdentity();
      if (result.researchEvidence.isNotEmpty) {
        final reviewed = await showDialog<bool>(context: context, builder: (_) => SubtitleResearchReviewDialog(
          result: result, jobId: job['id'] as String, inputDigest: job['audioDigest'] as String,
          isCurrent: () => mounted && _operationIdentityIsCurrent));
        if (reviewed != true || !mounted) return;
        _requireCurrentOperationIdentity();
      }
      if (result.artifacts.isNotEmpty) {
        final artifact = result.artifacts.single;
        final export = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('Review synthesized audio result'),
          content: SizedBox(width: 640, height: 350, child: ListView(children: [
            const Text('Export a separate WAV to listen and review. No player audio is replaced automatically.'),
            for (final warning in result.warnings) Text(warning),
          ])), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download and export WAV'))]));
        if (export != true || !mounted) return;
        _requireCurrentOperationIdentity();
        final bytes = await service.audioArtifact(job['id'] as String, artifact);
        _requireCurrentOperationIdentity();
        await FilePickerService.instance.saveFile(dialogTitle: 'Export synthesized audio', fileName: artifact.name,
          bytes: bytes, type: FileType.custom, allowedExtensions: const ['wav']);
        return;
      }
      var cues = result.cues;
      if (result.alternatives.isNotEmpty) {
        final selected = <String>{};
        final accepted = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) =>
          AlertDialog(title: const Text('Review recognition disagreements'), content: SizedBox(width: 720, height: 500,
            child: ListView(children: [const Text('Baseline wording is retained unless you explicitly select an alternative. Model agreement does not prove accuracy.'),
              for (final cue in cues) if (result.alternatives[cue.stableId] case final String other)
                CheckboxListTile(value: selected.contains(cue.stableId), title: Text('Baseline: ${cue.text}'),
                  subtitle: Text('Alternative: $other'), onChanged: (v) => update(() {
                    if (v == true) { selected.add(cue.stableId); } else { selected.remove(cue.stableId); }
                  })),
            ])), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue with selected wording'))])));
        if (accepted != true || !mounted) return;
        cues = [for (final cue in cues) selected.contains(cue.stableId)
          ? SubtitleCue(index: cue.index, startMs: cue.startMs, endMs: cue.endMs,
              text: result.alternatives[cue.stableId]!, cueId: cue.stableId) : cue];
      }
      if (result.images.isNotEmpty) {
        if (!mounted) return;
        _requireCurrentOperationIdentity();
        final reviewed = await showDialog<List<SubtitleCue>>(context: context,
          builder: (_) => SubtitleBitmapReviewDialog(service: service, result: result, initialCues: cues, jobId: job['id'] as String,
            mediaDigest: job['audioDigest'] as String, isCurrent: () => mounted && _operationIdentityIsCurrent));
        if (reviewed == null || !mounted) return;
        cues = reviewed;
      }
      final sourceById = {for (final cue in result.sourceCues) cue.stableId: cue};
      await _writeAndApply(cues, operationLabel: 'Companion ${job['task']}', operationLanguageCode: result.language,
        sourceCues: result.sourceCues.isEmpty ? null : [for (final cue in cues) sourceById[cue.stableId]!],
        wordTimings: result.alternatives.isEmpty ? result.wordTimings : const [],
        onItemTimeline: result.itemTimeline, regions: result.regions, avoidRegions: result.avoidRegions, reviewWarnings: result.warnings);
    } finally { service.close(); }
  });

  Future<void> _generateInterval({required bool fillSpeechGaps}) => _run(() async {
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    final wavPath = await _pickWav();
    if (wavPath == null || !mounted) return;
    final durationMs = await SubtitleAiService.instance.readWavDurationMs(wavPath);
    final interval = await _chooseAudioInterval(durationMs);
    if (interval == null || !mounted) return;
    await _ensureSpeechModel();
    final translateToEnglish =
        _translateSpeechToEnglish &&
        (_provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu);
    setState(() => _status = 'Transcribing only the selected audio interval…');
    final result = await SubtitleAiService.instance.transcribeWav(
      wavPath,
      provider: _provider,
      startMs: interval.startMs,
      endMs: interval.endMs,
      translateToEnglish: translateToEnglish,
      languageCode: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      onProgress: (phase, received, total) {
        if (!mounted) return;
        final percent = total == 0 ? '' : ' (${(received * 100 / total).round()}%)';
        setState(() => _status = '$phase$percent');
      },
    );
    final merged = fillSpeechGaps
        ? SubtitleIntervalService.fillSpeechDetectedGaps(
            existing: selected.$1,
            generated: result.cues,
            interval: interval,
          )
        : SubtitleIntervalService.replaceRange(
            existing: selected.$1,
            generated: result.cues,
            interval: interval,
          );
    final retainedCount = fillSpeechGaps
        ? selected.$1.length
        : selected.$1.where((cue) => cue.endMs <= interval.startMs || cue.startMs >= interval.endMs).length;
    final operationLabel = fillSpeechGaps
        ? 'Speech-detected subtitle gap fill'
        : translateToEnglish
        ? 'Interval speech translated to English'
        : 'Interval subtitle generation';
    if (!await _writeAndApply(
      merged,
      operationLabel: operationLabel,
      operationLanguageCode: translateToEnglish ? 'en' : result.detectedLanguage,
      wordTimings: result.wordTimings,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _status =
          '${fillSpeechGaps ? 'Added speech-detected gap cues' : 'Generated interval cues'} from '
          '${SubtitleAudioInterval.formatTimecode(interval.startMs)} to '
          '${SubtitleAudioInterval.formatTimecode(interval.endMs)}; '
          'preserved $retainedCount existing cues${fillSpeechGaps ? '' : ' outside the interval'}. '
          'Detected language: ${result.detectedLanguage}. Original subtitle and audio remain unchanged.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _synchronize({required bool repairCuts}) => _run(() async {
    final wavPath = await _pickWav();
    if (wavPath == null || !mounted) return;
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    await _ensureSpeechModel();
    setState(() => _status = 'Transcribing audio and aligning subtitle text…');
    final transcription = await SubtitleAiService.instance.transcribeWav(
      wavPath,
      provider: _provider,
      languageCode: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      onProgress: (phase, received, total) {
        if (!mounted) return;
        final percent = total == 0 ? '' : ' (${(received * 100 / total).round()}%)';
        setState(() => _status = '$phase$percent');
      },
    );
    final aligned = SubtitleSyncService.synchronize(
      subtitleCues: selected.$1,
      speechCues: transcription.cues,
      mediaDurationMs: transcription.durationMs,
      repairCuts: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      reviewWarnings: aligned.reviewWarnings,
      operationLabel: repairCuts ? 'Cut repair' : 'Automatic sync',
      operationLanguageCode: transcription.detectedLanguage,
      wordTimings: transcription.wordTimings,
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status =
          '${repairCuts ? 'Cut repair' : 'Automatic sync'} applied to ${aligned.matchedCueCount} '
          'of ${aligned.totalCueCount} cues ($percent% match confidence). '
          '${aligned.discontinuityCount} timing discontinuities detected; '
          'rate ${aligned.appliedRate.toStringAsFixed(4)}×, base offset ${aligned.globalOffsetMs} ms. '
          'Original: ${selected.$2}.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _showCapturedTranscript(SubtitlePlaybackTranscriptionService service) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _CapturedTranscriptDialog(player: widget.player, service: service),
    );
  }

  Future<void> _studySubtitle({bool saved = false}) => _run(() async {
    final identity = _operationRevisionIdentity;
    late final List<SubtitleCue> cues;
    late final String title;
    if (saved) {
      final transcript = await _chooseSavedTranscript();
      if (transcript == null || !mounted) return;
      if (transcript.storageKey != identity?.storageKey) {
        throw StateError('Open the transcript’s original media item to replay its source times.');
      }
      cues = transcript.loadedRevision.cues;
      title = transcript.mediaTitle;
    } else {
      final selected = await _pickSubtitleCues();
      if (selected == null || !mounted) return;
      cues = selected.$1;
      title = identity?.mediaTitle ?? selected.$2;
    }
    _requireCurrentOperationIdentity();
    await showDialog<void>(context: context, builder: (_) => SubtitleStudyDialog(
      player: widget.player, cues: cues, title: title,
      identityKey: identity?.storageKey,
      isCurrent: () => mounted && _operationIdentityIsCurrent,
    ));
  });

  Future<void> _saveCapturedTranscript(SubtitlePlaybackTranscriptionService service) => _run(() async {
    if (widget.isRevisionIdentityCurrent?.call() == false) {
      throw StateError('Playback changed before the transcript could be saved. Reopen subtitle tools for the current item.');
    }
    final transcript = service.recentTranscript;
    if (transcript == null || transcript.cues.isEmpty) {
      throw const FormatException('There is no captured transcript to save.');
    }
    final identity = _revisionIdentity;
    if (identity == null) {
      throw StateError('Transcript history needs a stable profile and media identity.');
    }
    final detectedLanguage = transcript.detectedLanguage.trim();
    final saved = await SubtitleRevisionService.saveRevision(
      identity: identity,
      operation: 'Captured playback transcript',
      onItemTimeline: true,
      languageCode: detectedLanguage.isEmpty || detectedLanguage.toLowerCase() == 'auto'
          ? null
          : detectedLanguage,
      cues: transcript.cues,
      wordTimings: transcript.wordTimings,
    );
    if (mounted) {
      setState(() => _revisionStatus =
          'Saved captured transcript ${saved.id} to this device for ${identity.mediaTitle?.trim().isNotEmpty == true ? identity.mediaTitle : 'this media item'}.');
    }
  });

  Future<SavedSubtitleTranscript?> _chooseSavedTranscript() async {
    if (widget.isRevisionIdentityCurrent?.call() == false) {
      throw StateError('Playback changed before the saved transcript could be loaded. Reopen subtitle tools for the current item.');
    }
    final identity = _revisionIdentity;
    if (identity == null) throw StateError('Saved transcript lookup needs a stable profile and media identity.');
    final transcripts = await SubtitleRevisionService.loadSavedTranscripts(
      profileId: identity.profileId,
      currentIdentity: identity,
    );
    if (transcripts.isEmpty) {
      throw const FormatException('Save a watched-portion transcript before reusing one from this profile.');
    }
    if (!mounted) return null;
    final searchController = TextEditingController();
    try {
      final selected = await showDialog<SavedSubtitleTranscript>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final query = searchController.text.trim().toLowerCase();
            final visible = transcripts.where((transcript) {
              if (query.isEmpty) return true;
              return transcript.mediaTitle.toLowerCase().contains(query) ||
                  transcript.sourceLabel.toLowerCase().contains(query) ||
                  (transcript.languageCode?.toLowerCase().contains(query) ?? false);
            }).toList(growable: false);
            return AlertDialog(
              title: const Text('Choose a saved transcript'),
              content: SizedBox(
                width: 560,
                height: 420,
                child: Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Search the 100 most recently saved transcripts in this profile.'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        labelText: 'Search media, source, or language',
                        prefixIcon: AppIcon(Symbols.search_rounded),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(child: Text('No saved transcripts match this search.'))
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final transcript = visible[index];
                                final language = transcript.languageCode == null ? '' : ' · ${transcript.languageCode}';
                                final sameItem = transcript.storageKey == identity.storageKey;
                                return ListTile(
                                  title: Text(transcript.mediaTitle),
                                  subtitle: Text(
                                    '${transcript.sourceLabel} · ${_formatRevisionDate(transcript.createdAt)} · '
                                    '${transcript.cueCount} cues$language${sameItem ? ' · this item' : ''}',
                                  ),
                                  onTap: () => Navigator.of(dialogContext).pop(transcript),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.cancel)),
              ],
            );
          },
        ),
      );
      if (selected == null || !mounted) return null;
      final loaded = await SubtitleRevisionService.loadSavedTranscript(selected);
      if (loaded == null) {
        throw const FormatException('That saved transcript is no longer available or its revision is damaged.');
      }
      return loaded;
    } finally {
      searchController.dispose();
    }
  }

  Future<void> _preparePlaybackCaptions() => _run(() async {
    final service = SubtitleReadAheadService.instance;
    if (service.running) { await service.stop(); return; }
    final input = TextEditingController(text: '0');
    final rendition = TextEditingController(text: '0');
    final live = widget.player is SubtitlePcmCaptureSource && (widget.player as SubtitlePcmCaptureSource).isLivePlayback;
    var selectedRendition = 0;
    final ordinal = await showDialog<int>(context: context, builder: (context) => AlertDialog(
      title: const Text('Prepare captions ahead of playback'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(live ? 'Live analysis uses native Android/Apple readers for local segment snapshots, or the packaged TV/desktop FFmpeg decoder, to read completed HLS or eligible DASH audio segments. '
          'It requires program timestamps and an active live-clock mapping, which remains an estimate. '
          'It can prepare captions ahead when you watch behind the live edge; it does not predict future speech. '
          'DASH requires clear audio/mp4, explicit SegmentTimeline, UTC availability/publication clocks and audio stream ordinal 0. Protected, partial and unsupported manifests are refused. Mobile snapshots accept TS, relative fMP4 and packed AAC only when the OS decoder supports them. '
          'This uses additional bandwidth and replaces app overlay 1.'
          : 'A separate native decoder on Android/Apple, packaged audio decoder on TVs, or installed FFmpeg on desktop reads the current source through its owning transport. '
          'This may use additional bandwidth. It prepares about two minutes ahead and replaces app overlay 1. '
          'Choose the audio stream in file order (0 is the first); native player track IDs may use a different numbering scheme.'),
        TextField(controller: input, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Audio stream ordinal (0–63)')),
        if (live) TextField(controller: rendition, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Live audio rendition / representation ordinal (0–63)',
            helperText: 'Playlist order, independent of player IDs. Verify the spoken language.')),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () {
          final value = int.tryParse(input.text), variant = int.tryParse(rendition.text);
          if (value != null && value >= 0 && value <= 63 && variant != null && variant >= 0 && variant <= 63) {
            selectedRendition = variant; Navigator.pop(context, value);
          }
        },
          child: const Text('Start local analysis'))]));
    input.dispose(); rendition.dispose();
    if (ordinal == null || !mounted) return;
    _requireCurrentOperationIdentity();
    final profiles = context.read<ActiveProfileProvider>();
    final profile = profiles.activeId, player = widget.player;
    final generation = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final audio = player.state.track.audio?.id;
    final sourceCurrent = widget.isRevisionIdentityCurrent;
    bool current() => profiles.activeId == profile && !player.disposed && sourceCurrent?.call() != false &&
        (generation == null || (player as PlayerMediaSessionIdentity).mediaSessionGeneration == generation) &&
        player.state.track.audio?.id == audio;
    await service.start(player, open: widget.openAnalysisSource ?? () => SubtitleAnalysisSource.localPlayer(player, current),
      isCurrent: current, audioOrdinal: ordinal, profileId: profile, language: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      provider: _liveProvider, hlsRendition: selectedRendition);
  });

  Future<void> _captureLivePlayback() => _run(() async {
    final player = widget.player;
    if (player is! SubtitlePcmCaptureSource) {
      throw UnsupportedError('This player does not expose decoded PCM to live subtitles.');
    }
    final captureSource = player as SubtitlePcmCaptureSource;
    final service = SubtitlePlaybackTranscriptionService.instance;
    if (service.isRunning || service.hasActiveSession) {
      await service.stop();
      if (!mounted) return;
      setState(() => _status = service.status);
      return;
    }
    final profiles = context.read<ActiveProfileProvider>();
    final profileId = profiles.activeId;
    await service.start(
      captureSource,
      languageCode: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      provider: _streamingModelManifest == null ? _liveProvider : SubtitleInferenceProvider.cpu,
      streamingManifest: _streamingModelManifest,
      isProfileIdentityCurrent: () => profiles.activeId == profileId,
      onProgress: (phase, received, total) {
        if (!mounted) return;
        final percent = total == 0 ? '' : ' (${(received * 100 / total).round()}%)';
        setState(() => _status = phase + percent);
      },
    );
    if (!mounted) return;
    setState(() => _status = service.status);
  });

  Future<(TranslateLanguage, TranslateLanguage)?> _chooseCrossLanguagePair({
    TranslateLanguage? fixedReference,
  }) async {
    var reference = fixedReference ?? _targetLanguage;
    var source = fixedReference != null && _sourceLanguage == fixedReference
        ? SubtitleTranslationService.languages.firstWhere((language) => language != fixedReference)
        : _sourceLanguage;
    return showDialog<(TranslateLanguage, TranslateLanguage)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Subtitle languages for matching'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<TranslateLanguage>(
                initialValue: source,
                decoration: const InputDecoration(
                  labelText: fixedReference == null ? 'Subtitle to synchronize' : 'Target subtitle language',
                  border: OutlineInputBorder(),
                ),
                items: SubtitleTranslationService.languages
                    .map(
                      (language) => DropdownMenuItem(
                        value: language,
                        child: Text(
                          SubtitleTranslationService.languageLabel(language),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) => setDialogState(() => source = value ?? source),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TranslateLanguage>(
                initialValue: reference,
                decoration: const InputDecoration(
                  labelText: fixedReference == null ? 'Reference subtitle' : 'Transcript language',
                  border: OutlineInputBorder(),
                ),
                items: SubtitleTranslationService.languages
                    .map(
                      (language) => DropdownMenuItem(
                        value: language,
                        child: Text(
                          SubtitleTranslationService.languageLabel(language),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: fixedReference == null ? (value) => setDialogState(() => reference = value ?? reference) : null,
              ),
              if (source == reference)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Choose different languages to use translated text for matching.'),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: source == reference ? null : () => Navigator.of(dialogContext).pop((source, reference)),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Future<TranslateLanguage?> _chooseTranscriptTranslationTarget(TranslateLanguage sourceLanguage) async {
    var targetLanguage = _targetLanguage == sourceLanguage
        ? SubtitleTranslationService.languages.firstWhere((language) => language != sourceLanguage)
        : _targetLanguage;
    return showDialog<TranslateLanguage>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Translate transcript subtitles'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Speech was identified as ${SubtitleTranslationService.languageLabel(sourceLanguage)}.'),
              const SizedBox(height: 10),
              DropdownButtonFormField<TranslateLanguage>(
                initialValue: targetLanguage,
                decoration: const InputDecoration(labelText: 'Subtitle language', border: OutlineInputBorder()),
                items: SubtitleTranslationService.languages
                    .where((language) => language != sourceLanguage)
                    .map((language) => DropdownMenuItem(
                          value: language,
                          child: Text(SubtitleTranslationService.languageLabel(language), overflow: TextOverflow.ellipsis),
                        ))
                    .toList(growable: false),
                onChanged: (value) => setDialogState(() => targetLanguage = value ?? targetLanguage),
              ),
              const SizedBox(height: 8),
              const Text('This translates the captured portion locally and keeps its speech timings.'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(targetLanguage), child: const Text('Continue')),
          ],
        ),
      ),
    );
  }

  Future<void> _translateTranscriptToSubtitles({
    required List<SubtitleCue> transcriptCues,
    required String? transcriptLanguageCode,
    required String transcriptDescription,
    required bool onItemTimeline,
  }) async {
    if (!_translationSupported) {
      throw UnsupportedError('Transcript translation needs a supported local subtitle translator.');
    }
    final languageCode = transcriptLanguageCode?.trim();
    final sourceLanguage = languageCode == null || languageCode.isEmpty
        ? null
        : SubtitleTranslationService.languageForCode(languageCode);
    if (sourceLanguage == null) {
      throw const FormatException('The transcript language is unknown or unsupported. Set the speech language and capture it again.');
    }
    final targetLanguage = await _chooseTranscriptTranslationTarget(sourceLanguage);
    if (targetLanguage == null || !mounted) return;
    setState(() => _status = 'Translating $transcriptDescription locally…');
    final translated = await SubtitleTranslationService.translateCues(
      cues: transcriptCues,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      allowMobileData: _allowMobileData,
      requestDesktopCuda: _requestTranslationCuda,
      bilingual: _bilingualTranslation,
      glossary: _glossaryForPair(sourceLanguage, targetLanguage),
      onProgress: (completed, total) {
        if (mounted) setState(() => _status = 'Translating transcript cue $completed of $total…');
      },
    );
    if (!mounted) return;
    if (translated.cues.length != transcriptCues.length) {
      throw StateError('Translation changed the transcript cue count; no subtitle was attached.');
    }
    for (var index = 0; index < translated.cues.length; index++) {
      if (translated.cues[index].startMs != transcriptCues[index].startMs ||
          translated.cues[index].endMs != transcriptCues[index].endMs) {
        throw StateError('Translation changed transcript timing; no subtitle was attached.');
      }
    }
    if (!await _writeAndApply(
      translated.cues,
      operationLabel: 'Translated speech transcript',
      onItemTimeline: onItemTimeline,
      operationLanguageCode: targetLanguage.bcpCode,
      sourceCues: transcriptCues,
      reviewWarnings: translated.qualityWarnings,
    )) return;
    if (!mounted) return;
    setState(() {
      _status = 'Translated $transcriptDescription from '
          '${SubtitleTranslationService.languageLabel(sourceLanguage)} to '
          '${SubtitleTranslationService.languageLabel(targetLanguage)} with the captured speech timings. '
          '${translated.backendLabel}.$_resultPersistenceSuffix';
    });
    await _showApplied();
  }

  Future<void> _translateSavedTranscript() => _run(() async {
    final transcript = await _chooseSavedTranscript();
    if (transcript == null || !mounted) return;
    await _translateTranscriptToSubtitles(
      transcriptCues: transcript.loadedRevision.cues,
      transcriptLanguageCode: transcript.loadedRevision.languageCode,
      transcriptDescription: 'the saved transcript from ${transcript.mediaTitle} (${transcript.sourceLabel})',
      onItemTimeline: transcript.loadedRevision.onItemTimeline,
    );
  });

  Future<void> _translateCapturedTranscript() => _run(() async {
    final transcript = SubtitlePlaybackTranscriptionService.instance.recentTranscript;
    if (transcript == null || transcript.cues.isEmpty) {
      throw const FormatException('Capture speech before translating its transcript.');
    }
    await _translateTranscriptToSubtitles(
      transcriptCues: transcript.cues,
      transcriptLanguageCode: transcript.detectedLanguage,
      transcriptDescription: 'captured speech',
      onItemTimeline: true,
    );
  });

  Map<String, String> _glossaryForPair(TranslateLanguage source, TranslateLanguage target) {
    final sameAsCurrent = source == _sourceLanguage && target == _targetLanguage;
    if (sameAsCurrent) return _parseGlossary();
    final profileId = _activeProfileId;
    if (profileId == null) return const <String, String>{};
    try {
      return SubtitleTranslationService.loadGlossaryForProfile(
        profileId: profileId,
        sourceLanguage: source,
        targetLanguage: target,
        seriesId: _useSeriesGlossary ? widget.seriesKey : null,
      );
    } catch (_) {
      return const <String, String>{};
    }
  }

  Future<void> _synchronizeAcrossLanguages({required bool repairCuts}) => _run(() async {
    setState(() => _status = 'Choose the subtitle that needs synchronization…');
    final target = await _pickSubtitleCues();
    if (target == null || !mounted) return;
    setState(() => _status = 'Choose a synchronized subtitle in another language…');
    final reference = await _pickSubtitleCues();
    if (reference == null || !mounted) return;
    final pair = await _chooseCrossLanguagePair();
    if (pair == null || !mounted) return;
    final sourceLanguage = pair.$1;
    final referenceLanguage = pair.$2;
    final durationMs = widget.player.state.duration.inMilliseconds;
    if (durationMs <= 0) {
      throw StateError('The player must expose media duration for subtitle-to-subtitle synchronization.');
    }

    setState(() => _status = 'Translating target cues locally for text matching…');
    final translated = await SubtitleTranslationService.translateCues(
      cues: target.$1,
      sourceLanguage: sourceLanguage,
      targetLanguage: referenceLanguage,
      allowMobileData: _allowMobileData,
      requestDesktopCuda: _requestTranslationCuda,
      glossary: _glossaryForPair(sourceLanguage, referenceLanguage),
      onProgress: (completed, total) {
        if (!mounted) return;
        setState(() => _status = 'Translating cues for alignment ($completed/$total)…');
      },
    );
    if (!mounted) return;
    _requireSubtitleCueIdentityPreserved(target.$1, translated.cues);

    setState(() => _status = 'Aligning translated target text against the reference…');
    final aligned = SubtitleSyncService.synchronizeAgainstReference(
      subtitleCues: translated.cues,
      referenceCues: reference.$1,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
    );
    final retimedOriginal = _restoreOriginalCueTextWithAlignedTimes(target.$1, aligned.cues);
    if (!await _writeAndApply(
      retimedOriginal,
      reviewWarnings: aligned.reviewWarnings,
      operationLabel: repairCuts ? 'Cross-language reference cut repair' : 'Cross-language subtitle sync',
      operationLanguageCode: sourceLanguage.bcpCode,
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    final warningCount = translated.qualityWarnings.length;
    setState(() {
      _status =
          'Cross-language ${repairCuts ? 'cut repair' : 'sync'} applied to '
          '${aligned.matchedCueCount} of ${aligned.totalCueCount} cues ($percent% match confidence). '
          'The original target text was preserved. Translated from '
          '${SubtitleTranslationService.languageLabel(sourceLanguage)} to '
          '${SubtitleTranslationService.languageLabel(referenceLanguage)}'
          '${warningCount == 0 ? '.' : '; $warningCount translation quality warnings.'}'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _synchronizeToReference({required bool repairCuts}) => _run(() async {
    setState(() => _status = 'Choose the subtitle that needs synchronization…');
    final target = await _pickSubtitleCues();
    if (target == null || !mounted) return;
    setState(() => _status = 'Choose an already synchronized subtitle in the same language…');
    final reference = await _pickSubtitleCues();
    if (reference == null || !mounted) return;
    if (target.$1.length == reference.$1.length &&
        List.generate(target.$1.length, (index) => index).every((index) {
          final left = target.$1[index];
          final right = reference.$1[index];
          return left.startMs == right.startMs && left.endMs == right.endMs && left.text == right.text;
        })) {
      throw const FormatException('Choose a different reference subtitle; the two files contain identical cues.');
    }
    final durationMs = widget.player.state.duration.inMilliseconds;
    if (durationMs <= 0) {
      throw StateError('The player must expose media duration for subtitle-to-subtitle synchronization.');
    }
    setState(() => _status = 'Matching both subtitles and aligning timing…');
    final aligned = SubtitleSyncService.synchronizeAgainstReference(
      subtitleCues: target.$1,
      referenceCues: reference.$1,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      reviewWarnings: aligned.reviewWarnings,
      operationLabel: repairCuts ? 'Reference cut repair' : 'Subtitle-reference sync',
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status =
          '${repairCuts ? 'Cut repair' : 'Subtitle-reference sync'} applied to '
          '${aligned.matchedCueCount} of ${aligned.totalCueCount} cues ($percent% match confidence). '
          '${aligned.discontinuityCount} timing discontinuities detected. '
          'Reference: ${reference.$2}. Original: ${target.$2}.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _synchronizeCapturedPlayback({required bool repairCuts}) => _run(() async {
    final transcript = SubtitlePlaybackTranscriptionService.instance.recentTranscript;
    if (transcript == null || transcript.cues.length < 3) {
      throw const FormatException('Capture at least three speech cues before synchronizing.');
    }
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    final playerDuration = widget.player.state.duration.inMilliseconds;
    final durationMs = playerDuration > 0 ? playerDuration : transcript.durationMs;
    setState(() => _status = 'Matching the captured speech against subtitle text…');
    final aligned = SubtitleSyncService.synchronize(
      subtitleCues: _fileCuesOnItemTimeline(selected.$1),
      speechCues: transcript.cues,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
      preserveUnmatchedOutsideEvidence: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      reviewWarnings: aligned.reviewWarnings,
      operationLabel: repairCuts ? 'Captured-playback cut repair' : 'Captured-playback sync',
      operationLanguageCode: transcript.detectedLanguage,
      wordTimings: transcript.wordTimings,
      onItemTimeline: true,
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status =
          'Captured-playback ${repairCuts ? 'cut repair' : 'sync'} applied to ${aligned.matchedCueCount} of ${aligned.totalCueCount} cues ($percent% match confidence). ${aligned.discontinuityCount} timing discontinuities detected. ${repairCuts ? 'Cues outside captured evidence kept their original timing. ' : ''}Original: ${selected.$2}.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _synchronizeSavedTranscript({required bool repairCuts}) => _run(() async {
    final transcript = await _chooseSavedTranscript();
    if (transcript == null || !mounted) return;
    final revision = transcript.loadedRevision;
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    final playerDuration = widget.player.state.duration.inMilliseconds;
    final transcriptDuration = revision.cues
        .map((cue) => cue.endMs)
        .fold<int>(1, (maximum, endMs) => endMs > maximum ? endMs : maximum);
    final durationMs = playerDuration > 0 ? playerDuration : transcriptDuration;
    setState(() => _status = 'Matching the saved transcript against subtitle text…');
    final aligned = SubtitleSyncService.synchronize(
      subtitleCues: revision.onItemTimeline ? _fileCuesOnItemTimeline(selected.$1) : selected.$1,
      speechCues: revision.cues,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
      preserveUnmatchedOutsideEvidence: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      reviewWarnings: aligned.reviewWarnings,
      operationLabel: repairCuts ? 'Saved-transcript cut repair' : 'Saved-transcript sync',
      operationLanguageCode: revision.languageCode,
      wordTimings: revision.wordTimings,
      onItemTimeline: revision.onItemTimeline,
    )) return;
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status = 'Saved-transcript ${repairCuts ? 'cut repair' : 'sync'} applied to '
          '${aligned.matchedCueCount} of ${aligned.totalCueCount} cues ($percent% match confidence). '
          '${aligned.discontinuityCount} timing discontinuities detected. '
          '${repairCuts ? 'Cues outside transcript evidence kept their original timing. ' : ''}'
          'Transcript: ${transcript.mediaTitle} (${transcript.sourceLabel}), ${_formatRevisionDate(revision.createdAt)}. Original: ${selected.$2}.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<void> _synchronizeTranscriptAcrossLanguages({
    required List<SubtitleCue> transcriptCues,
    required String? transcriptLanguageCode,
    required String transcriptDescription,
    required bool repairCuts,
    required bool onItemTimeline,
  }) async {
    if (!_translationSupported) {
      throw UnsupportedError('Cross-language transcript matching needs a supported local subtitle translator.');
    }
    final normalizedTranscriptLanguage = transcriptLanguageCode?.trim();
    final referenceLanguage = normalizedTranscriptLanguage == null || normalizedTranscriptLanguage.isEmpty
        ? null
        : SubtitleTranslationService.languageForCode(normalizedTranscriptLanguage);
    if (referenceLanguage == null) {
      throw const FormatException('The transcript language is unknown or unsupported. Set the speech language and capture it again.');
    }
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    final pair = await _chooseCrossLanguagePair(fixedReference: referenceLanguage);
    if (pair == null || !mounted) return;
    final sourceLanguage = pair.$1;
    final playerDuration = widget.player.state.duration.inMilliseconds;
    final transcriptEndMs = transcriptCues
        .map((cue) => cue.endMs)
        .fold<int>(1, (maximum, endMs) => endMs > maximum ? endMs : maximum);
    final durationMs = playerDuration > 0 ? playerDuration : transcriptEndMs;

    setState(() => _status = 'Translating subtitle text to the transcript language for matching…');
    final translated = await SubtitleTranslationService.translateCues(
      cues: selected.$1,
      sourceLanguage: sourceLanguage,
      targetLanguage: referenceLanguage,
      allowMobileData: _allowMobileData,
      requestDesktopCuda: _requestTranslationCuda,
      glossary: _glossaryForPair(sourceLanguage, referenceLanguage),
      onProgress: (completed, total) {
        if (mounted) setState(() => _status = 'Translating cues for alignment ($completed/$total)…');
      },
    );
    if (!mounted) return;
    _requireSubtitleCueIdentityPreserved(selected.$1, translated.cues);

    setState(() => _status = 'Matching translated subtitle text against $transcriptDescription…');
    final aligned = SubtitleSyncService.synchronize(
      subtitleCues: onItemTimeline ? _fileCuesOnItemTimeline(translated.cues) : translated.cues,
      speechCues: transcriptCues,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
      preserveUnmatchedOutsideEvidence: repairCuts,
    );
    final retimedOriginal = _restoreOriginalCueTextWithAlignedTimes(selected.$1, aligned.cues);
    if (!await _writeAndApply(
      retimedOriginal,
      reviewWarnings: aligned.reviewWarnings,
      operationLabel: repairCuts ? 'Cross-language transcript cut repair' : 'Cross-language transcript sync',
      operationLanguageCode: sourceLanguage.bcpCode,
      onItemTimeline: onItemTimeline,
    )) return;
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status = 'Cross-language ${repairCuts ? 'cut repair' : 'sync'} applied to '
          '${aligned.matchedCueCount} of ${aligned.totalCueCount} cues ($percent% match confidence). '
          'The original target text was preserved. Translated from '
          '${SubtitleTranslationService.languageLabel(sourceLanguage)} to '
          '${SubtitleTranslationService.languageLabel(referenceLanguage)}. '
          '${aligned.discontinuityCount} timing discontinuities detected. '
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  }

  Future<void> _synchronizeSavedTranscriptAcrossLanguages({required bool repairCuts}) => _run(() async {
    final transcript = await _chooseSavedTranscript();
    if (transcript == null || !mounted) return;
    final revision = transcript.loadedRevision;
    await _synchronizeTranscriptAcrossLanguages(
      transcriptCues: revision.cues,
      transcriptLanguageCode: revision.languageCode,
      transcriptDescription: 'the saved transcript from ${transcript.mediaTitle} (${transcript.sourceLabel})',
      onItemTimeline: transcript.loadedRevision.onItemTimeline,
      repairCuts: repairCuts,
    );
  });

  Future<void> _synchronizeCapturedPlaybackAcrossLanguages({required bool repairCuts}) => _run(() async {
    final transcript = SubtitlePlaybackTranscriptionService.instance.recentTranscript;
    if (transcript == null || transcript.cues.length < 3) {
      throw const FormatException('Capture at least three speech cues before cross-language synchronization.');
    }
    await _synchronizeTranscriptAcrossLanguages(
      transcriptCues: transcript.cues,
      transcriptLanguageCode: transcript.detectedLanguage,
      transcriptDescription: 'captured playback speech',
      onItemTimeline: true,
      repairCuts: repairCuts,
    );
  });

  Map<String, String> _parseGlossary() {
    final source = _glossaryController.text.trim();
    if (source.isEmpty) return const {};
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Glossary must be a JSON object mapping source terms to translated terms.');
    }
    final glossary = <String, String>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Every glossary key and value must be a string.');
      }
      glossary[entry.key as String] = entry.value as String;
    }
    return glossary;
  }

  String? get _activeProfileId {
    try {
      return context.read<ActiveProfileProvider>().activeId;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openOverlayControls() async {
    SubtitleDownloadBinding? binding;
    DownloadProvider? downloads;
    final profile = context.read<ActiveProfileProvider>();
    final profileId = profile.activeId;
    final player = widget.player;
    final session = SubtitleOverlayService.forPlayer(player);
    final sourceCurrent = widget.isRevisionIdentityCurrent;
    final partOffset = player.timelineOffset.inMilliseconds;
    bool current() => profile.activeId == profileId && session.current &&
        player.timelineOffset.inMilliseconds == partOffset && sourceCurrent?.call() != false;
    // Standalone source identities do not name library download rows.
    if (widget.revisionIdentity == null && widget.serverId != null && widget.ratingKey != null && profileId != null) {
      downloads = context.read<DownloadProvider>();
      final owner = downloads;
      final key = buildGlobalKey(ServerId(widget.serverId!), widget.ratingKey!);
      final row = await owner.getCompletedDownload(key);
      if (row != null && row.mediaIndex == widget.mediaIndex && current()) {
        final version = SubtitleDownloadAssets.digest(jsonEncode([row.mediaIndex, row.mediaSourceId, row.storedPartPaths]));
        binding = SubtitleDownloadBinding(globalKey: key, profileId: profileId, version: version,
          partOffsetMs: partOffset, isCurrent: () async {
            if (!current()) return false;
            final now = await owner.getCompletedDownload(key);
            return current() && now != null && version == SubtitleDownloadAssets.digest(
                jsonEncode([now.mediaIndex, now.mediaSourceId, now.storedPartPaths]));
          });
      }
    }
    if (!mounted || !current()) return;
    final saved = binding;
    await showSubtitleOverlayControls(context, player, download: saved, downloadIsCurrent: current,
      openAnalysisSource: widget.openAnalysisSource ?? () => SubtitleAnalysisSource.localPlayer(player, current),
      isSourceCurrent: current,
      onDownloadChanged: saved == null ? null : () => downloads!.refreshDownloadSize(saved.globalKey));
  }

  SubtitleRevisionIdentity? get _revisionIdentity {
    final standaloneIdentity = widget.revisionIdentity;
    if (standaloneIdentity != null) return standaloneIdentity;
    final profileId = _activeProfileId?.trim();
    final serverId = widget.serverId?.trim();
    final ratingKey = widget.ratingKey?.trim();
    if (profileId == null ||
        profileId.isEmpty ||
        serverId == null ||
        serverId.isEmpty ||
        ratingKey == null ||
        ratingKey.isEmpty ||
        widget.mediaIndex < 0) {
      return null;
    }
    return SubtitleRevisionIdentity(
      profileId: profileId,
      serverId: serverId,
      ratingKey: ratingKey,
      mediaIndex: widget.mediaIndex,
      mediaTitle: widget.mediaTitle,
      sourceLabel: widget.sourceLabel ?? 'Media library',
    );
  }

  Future<bool> _storeReviewedRevision({
    required List<SubtitleCue> cues,
    required String operation,
    String? languageCode,
    required List<SubtitleWordTiming> wordTimings,
    required SubtitleRevisionIdentity? identity,
    bool onItemTimeline = false,
  }) async {
    if (identity == null) {
      if (mounted) setState(() => _revisionStatus = 'Revision history needs an active profile and media item.');
      return false;
    }
    try {
      final revision = await SubtitleRevisionService.saveRevision(
        identity: identity,
        onItemTimeline: onItemTimeline,
        operation: operation,
        languageCode: languageCode,
        cues: cues,
        wordTimings: wordTimings,
      );
      if (mounted) {
        setState(
          () => _revisionStatus = 'Saved revision ${revision.id} to this device for this profile and media item.',
        );
      }
      return true;
    } catch (error) {
      if (mounted) setState(() => _revisionStatus = 'Could not save this revision locally: $error');
      return false;
    }
  }

  Future<bool?> _askToRecoverSubtitleDraft(SubtitleRevisionDraft draft) => showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Resume subtitle review?'),
      content: Text(
        'An in-progress ${draft.operation.toLowerCase()} review from ${_formatRevisionDate(draft.savedAt)} '
        'matches this exact subtitle result. Resume ${draft.undoHistory.length} undo step${draft.undoHistory.length == 1 ? '' : 's'}?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Discard draft')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Resume review')),
      ],
    ),
  );

  Future<bool?> _askToReplaceSubtitleDraft(SubtitleRevisionDraft draft) => showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Keep the saved review?'),
      content: Text(
        'This item already has an unfinished ${draft.operation.toLowerCase()} review from '
        '${_formatRevisionDate(draft.savedAt)}. Resume or delete it from subtitle history before starting a different review.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep saved draft')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete and continue')),
      ],
    ),
  );

  Future<void> _deleteSubtitleDraft(SubtitleRevisionIdentity? identity) async {
    if (identity == null) return;
    try {
      await SubtitleRevisionService.deleteDraft(identity);
    } catch (error) {
      if (mounted) setState(() => _revisionStatus = 'Could not clear the saved subtitle review draft: $error');
    }
  }

  Future<bool> _storeUndoCheckpoint({
    required List<SubtitleCue> cues,
    required String operation,
    String? languageCode,
    required List<SubtitleWordTiming> wordTimings,
    required SubtitleRevisionIdentity? identity,
    bool onItemTimeline = false,
  }) async {
    if (identity == null) {
      if (mounted) {
        setState(
          () => _revisionStatus =
              'Persistent undo checkpoints need a stable profile and media identity; session undo is still available.',
        );
      }
      return true;
    }
    try {
      final checkpointOperation = '$_subtitleUndoCheckpointPrefix${operation.trim()}';
      await SubtitleRevisionService.saveRevision(
        identity: identity,
        onItemTimeline: onItemTimeline,
        operation: checkpointOperation.length <= 120 ? checkpointOperation : checkpointOperation.substring(0, 120),
        languageCode: languageCode,
        cues: cues,
        wordTimings: wordTimings,
      );
      if (mounted) setState(() => _revisionStatus = 'Saved an undo checkpoint to this device for this item.');
      return true;
    } catch (error) {
      if (mounted) {
        setState(
          () => _revisionStatus = 'Could not save an undo checkpoint; the accepted revision remains available: $error',
        );
      }
      return false;
    }
  }

  Future<void> _storeUndoHistory({
    required List<SubtitleCue> cues,
    required List<(int, SubtitleCue)> undoHistory,
    required String operation,
    String? languageCode,
    required List<SubtitleWordTiming> wordTimings,
    required SubtitleRevisionIdentity? identity,
    bool onItemTimeline = false,
  }) async {
    if (identity == null || undoHistory.isEmpty) return;

    // The most recent pre-edit states are the most useful recovery points.
    // Leave one item-history slot for the accepted final revision.
    final snapshot = List<SubtitleCue>.from(cues);
    var saved = 0;
    for (
      var index = undoHistory.length - 1;
      index >= 0 && saved < SubtitleRevisionService.maximumRevisionsPerItem - 1;
      index--
    ) {
      final (cueIndex, previousCue) = undoHistory[index];
      if (cueIndex < 0 || cueIndex >= snapshot.length) continue;
      final currentCue = snapshot[cueIndex];
      if (currentCue.startMs == previousCue.startMs &&
          currentCue.endMs == previousCue.endMs &&
          currentCue.text == previousCue.text) {
        continue;
      }
      snapshot[cueIndex] = previousCue;
      final persisted = await _storeUndoCheckpoint(
        cues: List<SubtitleCue>.unmodifiable(snapshot),
        operation: operation,
        languageCode: languageCode,
        wordTimings: wordTimings,
        identity: identity,
        onItemTimeline: onItemTimeline,
      );
      if (!persisted) return;
      saved++;
    }
  }

  List<SubtitleCue> _fileCuesOnItemTimeline(List<SubtitleCue> cues) {
    final offset = widget.player.timelineOffset.inMilliseconds;
    if (offset == 0) return cues;
    return cues.map((cue) {
      if (cue.endMs + offset > SubtitleRetimer.maximumTimeMs) {
        throw const FormatException('The item subtitle clock exceeds the supported range');
      }
      return SubtitleCue(index: cue.index, startMs: cue.startMs + offset,
        endMs: cue.endMs + offset, text: cue.text, cueId: cue.stableId);
    }).toList(growable: false);
  }

  Future<Uint8List> _bytesForNativeTimeline(List<SubtitleCue> cues, bool onItemTimeline) async {
    if (!onItemTimeline) return SubtitleSyncService.writeSrt(cues);
    final offset = widget.player.timelineOffset.inMilliseconds;
    final output = SubtitleSyncService.writeSrtForPart(cues, offset);
    if (output.clipped > 0) {
      if (!mounted) throw StateError('Playback closed');
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Clip captions at this media part?'),
        content: Text('${output.clipped} cues begin before the opened part. They will be clipped or omitted in the native sidecar; saved history and exports keep item times.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Attach this part'))]));
      if (accepted != true) throw StateError('Native caption attachment cancelled');
    }
    _requireCurrentOperationIdentity();
    if (widget.player.timelineOffset.inMilliseconds != offset) throw StateError('The opened media part changed');
    return output.bytes;
  }

  Future<void> _restoreSubtitleRevision(SubtitleRevision revision, SubtitleRevisionIdentity expectedIdentity) async {
    if (_operationRevisionIdentity?.storageKey != expectedIdentity.storageKey) {
      throw StateError('The selected subtitle revision belongs to a different media item or profile.');
    }
    final bytes = await _bytesForNativeTimeline(revision.cues, revision.onItemTimeline);
    final directory = await getTemporaryDirectory();
    final path = p.join(directory.path, 'plezyng_revision_${revision.id}.srt');
    await File(path).writeAsBytes(bytes, flush: true);
    _requireCurrentOperationIdentity();
    await widget.player.command(['sub-add', path, 'select']);
    if (mounted) {
      setState(() => _status = 'Attached reviewed revision from ${_formatRevisionDate(revision.createdAt)}.');
      OverlaySheetController.of(context).refocus();
    }
  }

  Future<void> _exportSubtitleRevision(SubtitleRevision revision) async {
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: 'Export reviewed subtitle revision',
      fileName: 'PlezyNG_revision_${revision.id}.srt',
      bytes: SubtitleSyncService.writeSrt(revision.cues),
      type: FileType.custom,
      allowedExtensions: const ['srt'],
    );
    if (mounted && result != null) {
      setState(() => _status = 'Reviewed subtitle revision exported as SRT.');
    }
  }

  Future<void> _exportSubtitleRevisionJson(SubtitleRevision revision) async {
    final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(revision.toJson())));
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: 'Export subtitle revision with word timings',
      fileName: 'PlezyNG_revision_${revision.id}.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (mounted && result != null) {
      setState(() => _status = 'Revision JSON exported with stable cue IDs and retained word timings.');
    }
  }

  Future<List<SubtitleRevision>?> _importSubtitleRevisionJson(SubtitleRevisionIdentity identity) async {
    final picked = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withReadStream: true,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.first;
    if (p.extension(file.name).toLowerCase() != '.json' ||
        file.size <= 0 ||
        file.size > SubtitleRevisionService.maximumHistoryBundleBytes) {
      throw const FormatException('Choose a subtitle history JSON file no larger than 32 MiB.');
    }
    Stream<List<int>>? source = file.readStream;
    if (source == null && file.path != null) {
      final input = File(file.path!);
      final actualSize = await input.length();
      if (actualSize != file.size) {
        throw const FormatException('Subtitle revision JSON changed while it was being selected.');
      }
      source = input.openRead();
    }
    final pickedBytes = file.bytes;
    if (source == null && pickedBytes != null) source = Stream<List<int>>.value(pickedBytes);
    if (source == null) {
      throw const FormatException('This platform did not provide a readable revision JSON stream.');
    }
    final output = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in source) {
      received += chunk.length;
      if (received > SubtitleRevisionService.maximumHistoryBundleBytes) {
        throw const FormatException('Subtitle history JSON exceeds the 32 MiB import limit.');
      }
      output.add(chunk);
    }
    if (received != file.size) {
      throw const FormatException('Subtitle revision JSON changed or was truncated while it was read.');
    }
    if (received <= 0 || received > SubtitleRevisionService.maximumHistoryBundleBytes) {
      throw const FormatException('Subtitle history JSON exceeds the 32 MiB import limit.');
    }
    final bytes = output.takeBytes();
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    final rawRevisions = switch (decoded) {
      Map<String, dynamic> value when value['schema'] == 'plezyng.subtitle-history.v1' => value['revisions'],
      _ => <Object?>[_normalizeSubtitleRevisionImport(decoded)],
    };
    if (rawRevisions is! List ||
        rawRevisions.isEmpty ||
        rawRevisions.length > SubtitleRevisionService.maximumRevisionsPerItem) {
      throw const FormatException('Subtitle history JSON must contain between 1 and 12 valid revisions.');
    }
    final importedRevisions = rawRevisions
        .map((record) => SubtitleRevision.fromJson(_normalizeSubtitleRevisionImport(record)))
        .toList(growable: false);
    if (importedRevisions.map((revision) => revision.id).toSet().length != importedRevisions.length) {
      throw const FormatException('Subtitle history JSON contains duplicate revision records.');
    }
    final saved = <SubtitleRevision>[];
    for (final imported in importedRevisions.reversed) {
      saved.add(
        await SubtitleRevisionService.saveRevision(
          identity: identity,
          operation: _importedSubtitleOperation(imported.operation),
          languageCode: imported.languageCode,
          cues: imported.cues,
          wordTimings: imported.wordTimings,
          onItemTimeline: imported.onItemTimeline,
        ),
      );
    }
    return saved.reversed.toList(growable: false);
  }

  Future<void> _exportSubtitleHistoryJson(SubtitleRevisionIdentity identity) async {
    final revisions = await SubtitleRevisionService.loadRevisions(identity);
    if (revisions.isEmpty) {
      if (mounted) setState(() => _revisionStatus = 'There is no saved subtitle history to export for this item.');
      return;
    }
    final bytes = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'schema': 'plezyng.subtitle-history.v1',
          'generatedBy': 'PlezyNG',
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'revisions': revisions.map((revision) => revision.toJson()).toList(growable: false),
        }),
      ),
    );
    if (bytes.length > SubtitleRevisionService.maximumHistoryBundleBytes) {
      throw const FormatException('This subtitle history bundle exceeds the 32 MiB export limit.');
    }
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: 'Export subtitle revision history for another device',
      fileName: 'PlezyNG_subtitle_history_${DateTime.now().microsecondsSinceEpoch}.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (mounted && result != null) {
      setState(() => _revisionStatus = 'Exported ${revisions.length} subtitle revisions for transfer to another device.');
    }
  }

  Future<bool> _confirmSubtitleHistoryImport() async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Import subtitle history?'),
          content: const Text(
            'Imported revisions are added to this item on this device. The item keeps at most 12 revisions and 24 MiB, so its oldest entries may be removed.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Continue')),
          ],
        ),
      ) ??
      false;

  Object? _normalizeSubtitleRevisionImport(Object? value) {
    if (value is! Map<String, dynamic> || value['schema'] != 'plezyng.subtitle-cues.v3') return value;
    if (value['timebase'] != 'milliseconds' ||
        value['operation'] is! String ||
        value['createdAt'] is! String ||
        (value['language'] != null && value['language'] is! String) ||
        value['cues'] is! List ||
        value['wordTimings'] is! List) {
      throw const FormatException('Reviewed subtitle cue JSON metadata is invalid.');
    }
    final wordTimings = (value['wordTimings'] as List).map((rawTiming) {
      if (rawTiming is! Map) return rawTiming;
      final timing = Map<String, dynamic>.from(rawTiming);
      timing['confidence'] = timing['confidence'] ?? timing['probability'];
      return timing;
    }).toList(growable: false);
    return <String, Object?>{
      'schema': 'plezyng.subtitle-revision.v1',
      'id': '0_0',
      'createdAt': value['createdAt'],
      'operation': value['operation'],
      'languageCode': value['language'],
      'onItemTimeline': value['onItemTimeline'] ?? false,
      'cues': value['cues'],
      'wordTimings': wordTimings,
    };
  }

  String _importedSubtitleOperation(String value) {
    const prefix = 'Imported: ';
    final source = value.replaceFirst(RegExp(r'^(?:Imported: )+'), '');
    final suffix = StringBuffer();
    var codeUnits = 0;
    for (final rune in source.runes) {
      final runeLength = rune > 0xffff ? 2 : 1;
      if (codeUnits + runeLength > 120 - prefix.length) break;
      suffix.writeCharCode(rune);
      codeUnits += runeLength;
    }
    return '$prefix${suffix.toString()}';
  }

  String _formatRevisionDate(DateTime value) {
    final local = value.toLocal();
    String pad(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
  }

  Future<void> _showRevisionHistory() async {
    final identity = _revisionIdentity;
    if (identity == null) {
      setState(() => _revisionStatus = 'Revision history needs a stable profile and media item.');
      return;
    }
    try {
      var revisions = await SubtitleRevisionService.loadRevisions(identity);
      var draft = await SubtitleRevisionService.loadDraftForIdentity(identity);
      if (!mounted || _revisionIdentity?.storageKey != identity.storageKey) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final height = (MediaQuery.sizeOf(dialogContext).height - 220).clamp(240.0, 460.0).toDouble();
            return AlertDialog(
              title: Row(
                children: [
                  const Expanded(child: Text('Subtitle revision history')),
                  IconButton(
                    tooltip: 'Export history bundle',
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(_run(() => _exportSubtitleHistoryJson(identity)));
                    },
                    icon: const AppIcon(Symbols.file_download_rounded),
                  ),
                ],
              ),
              content: SizedBox(
                width: 620,
                height: height,
                child: revisions.isEmpty && draft == null
                    ? const Center(child: Text('No reviewed revisions have been saved for this item yet.'))
                    : ListView.separated(
                        itemCount: revisions.length + (draft == null ? 0 : 1),
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, index) {
                          if (draft != null && index == 0) {
                            final pendingDraft = draft!;
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'Unfinished review · ${pendingDraft.operation}',
                                      style: Theme.of(context).textTheme.titleSmall,
                                    ),
                                    Text(
                                      '${_formatRevisionDate(pendingDraft.savedAt)} · ${pendingDraft.cues.length} cues · '
                                      '${pendingDraft.undoHistory.length} undo steps',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        TextButton.icon(
                                          onPressed: () {
                                            Navigator.of(dialogContext).pop();
                                            unawaited(
                                              _run(() async {
                                                await _writeAndApply(
                                                  pendingDraft.baseCues,
                                                  operationLabel: pendingDraft.operation,
                                                  operationLanguageCode: pendingDraft.languageCode,
                                                  sourceCues: pendingDraft.sourceCues,
                                                  wordTimings: pendingDraft.wordTimings,
                                                  resumeDraft: pendingDraft,
                                                  onItemTimeline: pendingDraft.onItemTimeline,
                                                  resumeIdentity: identity,
                                                );
                                              }),
                                            );
                                          },
                                          icon: const AppIcon(Symbols.play_arrow_rounded),
                                          label: const Text('Resume review'),
                                        ),
                                        TextButton.icon(
                                          onPressed: () async {
                                            await SubtitleRevisionService.deleteDraft(identity);
                                            if (!mounted || !dialogContext.mounted) return;
                                            setDialogState(() => draft = null);
                                          },
                                          icon: const AppIcon(Symbols.delete_outline_rounded),
                                          label: const Text('Delete draft'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                          final revisionIndex = index - (draft == null ? 0 : 1);
                          final revision = revisions[revisionIndex];
                          final language = revision.languageCode == null ? '' : ' · ${revision.languageCode}';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(revision.operation, style: Theme.of(context).textTheme.titleSmall),
                                Text(
                                  '${_formatRevisionDate(revision.createdAt)} · ${revision.cues.length} cues$language',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (revision.wordTimings.isNotEmpty)
                                  Text(
                                    '${revision.wordTimings.length} token-derived timing spans retained',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        unawaited(_run(() => _restoreSubtitleRevision(revision, identity)));
                                      },
                                      icon: AppIcon(
                                        revision.operation.startsWith(_subtitleUndoCheckpointPrefix)
                                            ? Symbols.undo_rounded
                                            : Symbols.subtitles_rounded,
                                      ),
                                      label: Text(
                                        revision.operation.startsWith(_subtitleUndoCheckpointPrefix)
                                            ? 'Restore checkpoint'
                                            : 'Attach',
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        unawaited(_run(() => _exportSubtitleRevision(revision)));
                                      },
                                      icon: const AppIcon(Symbols.save_alt_rounded),
                                      label: const Text('Export'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        unawaited(_run(() => _exportSubtitleRevisionJson(revision)));
                                      },
                                      icon: const AppIcon(Symbols.data_object_rounded),
                                      label: const Text('Export JSON'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () async {
                                        await SubtitleRevisionService.deleteRevision(identity, revision.id);
                                        if (!mounted || !dialogContext.mounted) return;
                                        setDialogState(
                                          () => revisions = revisions
                                              .where((item) => item.id != revision.id)
                                              .toList(growable: false),
                                        );
                                      },
                                      icon: const AppIcon(Symbols.delete_outline_rounded),
                                      label: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: () async {
                    try {
                      if (!await _confirmSubtitleHistoryImport() || !mounted || !dialogContext.mounted) return;
                      final imported = await _importSubtitleRevisionJson(identity);
                      if (imported != null && mounted && dialogContext.mounted) {
                        final refreshed = await SubtitleRevisionService.loadRevisions(identity);
                        if (!mounted || !dialogContext.mounted) return;
                        setDialogState(() => revisions = refreshed);
                        setState(
                          () => _revisionStatus =
                              'Imported ${imported.length} subtitle revision${imported.length == 1 ? '' : 's'} into this item history.',
                        );
                      }
                    } catch (error) {
                      if (mounted) setState(() => _error = _readableError(error));
                    }
                  },
                  icon: const AppIcon(Symbols.file_upload),
                  label: const Text('Import JSON'),
                ),
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
              ],
            );
          },
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _revisionStatus = 'Could not open subtitle revision history: $error');
    }
  }

  String _currentGlossaryPairKey() {
    String code(TranslateLanguage language) => language.bcpCode.toLowerCase().split('-').first;
    return '${code(_sourceLanguage)}>${code(_targetLanguage)}';
  }

  String _currentGlossaryDraftKey() =>
      '${_useSeriesGlossary ? 'series:${widget.seriesKey}' : 'profile'}|${_currentGlossaryPairKey()}';

  Future<void> _loadSpeechLanguageForProfile() async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    try {
      final code = SettingsService.instance.read(SettingsService.subtitleSpeechLanguageForProfile(profileId));
      if (!mounted) return;
      if (code == 'auto' || _whisperLanguagesByCode().containsKey(code)) {
        setState(() => _speechLanguageCode = code);
      }
    } catch (_) {
      // A corrupt or stale preference should not block subtitle generation.
    }
  }

  Future<void> _saveSpeechLanguageForProfile(String code) async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    try {
      await SettingsService.instance.write(SettingsService.subtitleSpeechLanguageForProfile(profileId), code);
    } catch (_) {
      if (mounted) setState(() => _status = 'Could not save the speech language preference for this profile.');
    }
  }

  Future<void> _loadGlossaryForCurrentPair() async {
    final draft = _glossaryDrafts[_currentGlossaryDraftKey()];
    final profileId = _activeProfileId;
    Map<String, String> saved = const {};
    if (draft == null && profileId != null) {
      try {
        saved = SubtitleTranslationService.loadGlossaryForProfile(
          profileId: profileId,
          sourceLanguage: _sourceLanguage,
          targetLanguage: _targetLanguage,
          seriesId: _useSeriesGlossary ? widget.seriesKey : null,
        );
      } catch (_) {
        saved = const {};
      }
    }
    if (!mounted) return;
    _glossaryController.text = draft ?? (saved.isEmpty ? '' : JsonEncoder.withIndent('  ').convert(saved));
  }

  void _changeTranslationLanguage({required bool source, required TranslateLanguage? value}) {
    if (value == null || (source ? value == _sourceLanguage : value == _targetLanguage)) return;
    _glossaryDrafts[_currentGlossaryDraftKey()] = _glossaryController.text;
    if (_glossaryDrafts.length > 16) _glossaryDrafts.remove(_glossaryDrafts.keys.first);
    setState(() {
      if (source) {
        _sourceLanguage = value;
      } else {
        _targetLanguage = value;
      }
    });
    unawaited(_loadGlossaryForCurrentPair());
  }

  Future<void> _saveGlossary() async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      throw StateError('An active profile is required to save a translation glossary.');
    }
    final glossary = _parseGlossary();
    await SubtitleTranslationService.saveGlossaryForProfile(
      profileId: profileId,
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      seriesId: _useSeriesGlossary ? widget.seriesKey : null,
      glossary: glossary,
    );
    _glossaryDrafts[_currentGlossaryDraftKey()] = _glossaryController.text;
    if (mounted) {
      setState(
        () => _status = _useSeriesGlossary
            ? 'Saved glossary override for this series and language pair.'
            : 'Saved glossary for this profile and language pair.',
      );
    }
  }

  Future<void> _showGlossaryHistory() async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      if (mounted) setState(() => _status = 'An active profile is required to load glossary history.');
      return;
    }
    final revisions = SubtitleTranslationService.loadGlossaryHistoryForProfile(
      profileId: profileId,
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      seriesId: _useSeriesGlossary ? widget.seriesKey : null,
    );
    if (revisions.isEmpty) {
      if (mounted) setState(() => _status = 'No previous glossary versions are saved for this scope and language pair.');
      return;
    }
    final selected = await showDialog<SubtitleGlossaryRevision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Saved glossary history'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: ListView.builder(
            itemCount: revisions.length,
            itemBuilder: (context, index) {
              final revision = revisions[index];
              return ListTile(
                title: Text(_formatRevisionDate(revision.createdAt)),
                subtitle: Text('${revision.glossary.length} terms · ${_useSeriesGlossary ? 'series' : 'profile'} scope'),
                onTap: () => Navigator.of(dialogContext).pop(revision),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.cancel)),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final restoredDraft = JsonEncoder.withIndent('  ').convert(selected.glossary);
    setState(() {
      _glossaryController.text = restoredDraft;
      _glossaryDrafts[_currentGlossaryDraftKey()] = restoredDraft;
      _status = 'Loaded glossary version from ${_formatRevisionDate(selected.createdAt)}. Save it to replace the current glossary.';
    });
  }

  Future<void> _prepareTranslationModels() => _run(() async {
    await SubtitleTranslationService.prepareMobileModels(
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      allowMobileData: _allowMobileData,
      onStatus: (status) {
        if (mounted) setState(() => _status = status);
      },
    );
    if (mounted) setState(() => _status = 'Selected language models are ready for offline translation.');
  });

  Future<void> _translate() => _run(() async {
    if (!await SubtitleTranslationService.isSupportedOnCurrentDevice()) {
      throw UnsupportedError(
        SubtitleTranslationService.desktopPlatformSupported
            ? 'Install Argos Translate in Python and the selected language pair to translate locally on desktop.'
            : 'On-device translation is available on supported phones and tablets only.',
      );
    }
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    final glossary = _parseGlossary();
    final profileId = _activeProfileId;
    if (profileId != null) {
      await SubtitleTranslationService.saveGlossaryForProfile(
        profileId: profileId,
        sourceLanguage: _sourceLanguage,
        targetLanguage: _targetLanguage,
        seriesId: _useSeriesGlossary ? widget.seriesKey : null,
        glossary: glossary,
      );
      _glossaryDrafts[_currentGlossaryDraftKey()] = _glossaryController.text;
    }
    setState(
      () => _status = SubtitleTranslationService.desktopPlatformSupported
          ? 'Starting local translation…'
          : 'Preparing on-device language models…',
    );
    final memoryIdentity = _operationRevisionIdentity?.storageKey;
    final memoryEnabled = _useTranslationMemory && profileId != null && memoryIdentity != null;
    final memoryNamespace = SubtitleTranslationMemory.namespace(
      source: _sourceLanguage.bcpCode, target: _targetLanguage.bcpCode,
      engine: SubtitleTranslationService.desktopPlatformSupported ? 'argos-local' : 'mlkit-local',
      glossary: glossary, bilingual: _bilingualTranslation,
    );
    final remembered = memoryEnabled ? await SubtitleTranslationMemory.lookup(
      profileId: profileId!, namespace: memoryNamespace, cues: selected.$1,
    ) : <String, String>{};
    final pending = selected.$1.where((cue) => !remembered.containsKey(cue.stableId)).toList();
    final generated = pending.isEmpty
        ? const SubtitleTranslationResult(cues: [], backendLabel: 'Reviewed translation memory', fellBackToCpu: false, qualityWarnings: [])
        : await SubtitleTranslationService.translateCues(
      cues: pending,
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      allowMobileData: _allowMobileData,
      requestDesktopCuda: _requestTranslationCuda,
      bilingual: _bilingualTranslation,
      glossary: glossary,
      onProgress: (completed, total) {
        if (mounted) setState(() => _status = 'Translating cue $completed of $total on this device…');
      },
    );
    final byId = {for (final cue in generated.cues) cue.stableId: cue};
    final result = SubtitleTranslationResult(
      cues: selected.$1.map((source) {
        final text = remembered[source.stableId];
        if (text == null) return byId[source.stableId] ?? (throw StateError('Translation omitted a cue.'));
        return SubtitleCue(index: source.index, startMs: source.startMs, endMs: source.endMs, text: text, cueId: source.stableId);
      }).toList(growable: false),
      backendLabel: generated.backendLabel, fellBackToCpu: generated.fellBackToCpu,
      qualityWarnings: [
        ...generated.qualityWarnings,
        if (remembered.isNotEmpty) '${remembered.length} reviewed translations reused with exact source-context and glossary matches. '
            'Local translators do not expose their model revision; review the reused text before saving.',
      ],
    );
    _requireSubtitleCueIdentityPreserved(selected.$1, result.cues);
    if (!await _writeAndApply(
      result.cues,
      operationLabel: 'Translated subtitles',
      operationLanguageCode: _targetLanguage.bcpCode,
      sourceCues: selected.$1,
      reviewWarnings: result.qualityWarnings,
      onAcceptedReview: !memoryEnabled ? null : (reviewed) => SubtitleTranslationMemory.remember(
        profileId: profileId!, namespace: memoryNamespace, source: selected.$1, reviewed: reviewed,
        backendLabel: result.backendLabel, itemIdentity: memoryIdentity!,
      ),
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _status =
          'Translated ${result.cues.length} cues from '
          '${SubtitleTranslationService.languageLabel(_sourceLanguage)} to '
          '${SubtitleTranslationService.languageLabel(_targetLanguage)}. '
          'Timing and original subtitle file were preserved. ${result.backendLabel}.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
  });

  Future<SubtitleCue?> _editCueForReview(BuildContext dialogContext, SubtitleCue cue) async {
    final textController = TextEditingController(text: cue.text);
    final startController = TextEditingController(text: cue.startMs.toString());
    final endController = TextEditingController(text: cue.endMs.toString());
    SubtitleCue? edited;
    String? validationError;
    try {
      await showDialog<bool>(
        context: dialogContext,
        builder: (editorContext) => StatefulBuilder(
          builder: (context, setEditorState) => AlertDialog(
            title: const Text('Edit subtitle cue'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: textController,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(labelText: 'Cue text', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Start (ms)', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: endController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'End (ms)', border: OutlineInputBorder()),
                          ),
                        ),
                      ],
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 8),
                      Text(validationError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(editorContext).pop(false), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final startMs = int.tryParse(startController.text.trim());
                  final endMs = int.tryParse(endController.text.trim());
                  final text = textController.text.trimRight();
                  if (startMs == null ||
                      endMs == null ||
                      startMs < 0 ||
                      endMs <= startMs ||
                      endMs > SubtitleRetimer.maximumTimeMs ||
                      text.trim().isEmpty ||
                      text.length > 4000) {
                    setEditorState(() {
                      validationError = 'Use non-empty text up to 4000 characters and valid millisecond times.';
                    });
                    return;
                  }
                  edited = SubtitleCue(
                    index: cue.index,
                    startMs: startMs,
                    endMs: endMs,
                    text: text,
                    cueId: cue.stableId,
                  );
                  Navigator.of(editorContext).pop(true);
                },
                child: const Text('Save cue'),
              ),
            ],
          ),
        ),
      );
      return edited;
    } finally {
      textController.dispose();
      startController.dispose();
      endController.dispose();
    }
  }

  void _rememberCueEdit(List<(int, SubtitleCue)> undoHistory, int index, SubtitleCue cue) {
    if (undoHistory.length == 100) undoHistory.removeAt(0);
    undoHistory.add((index, cue));
  }

  Future<void> _showFullCueEditor(
    BuildContext dialogContext,
    List<SubtitleCue> cues, {
    List<SubtitleCue>? sourceCues,
    required List<(int, SubtitleCue)> undoHistory,
    VoidCallback? onChanged,
  }) async {
    final searchController = TextEditingController();
    var query = '';
    try {
      await showDialog<void>(
        context: dialogContext,
        builder: (editorContext) => StatefulBuilder(
          builder: (context, setEditorState) {
            final normalizedQuery = query.trim().toLowerCase();
            final visibleIndexes = List<int>.generate(cues.length, (index) => index)
                .where((index) {
                  if (normalizedQuery.isEmpty) return true;
                  final output = cues[index].text.toLowerCase();
                  final original = sourceCues != null && index < sourceCues.length
                      ? sourceCues[index].text.toLowerCase()
                      : '';
                  return output.contains(normalizedQuery) || original.contains(normalizedQuery);
                })
                .toList(growable: false);
            return AlertDialog(
              title: Text('Edit all ${cues.length} cues'),
              content: SizedBox(
                width: 720,
                height: (MediaQuery.sizeOf(editorContext).height - 220).clamp(280.0, 560.0).toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Review or edit any output cue. Changes stay in this result until you attach it.'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchController,
                      maxLength: 128,
                      decoration: const InputDecoration(
                        labelText: 'Find in source or output cues',
                        prefixIcon: AppIcon(Symbols.search_rounded),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (value) => setEditorState(() => query = value),
                    ),
                    const SizedBox(height: 4),
                    Text('Showing ${visibleIndexes.length} of ${cues.length} cues.'),
                    const SizedBox(height: 6),
                    Expanded(
                      child: visibleIndexes.isEmpty
                          ? const Center(child: Text('No cues match this search.'))
                          : ListView.builder(
                              itemCount: visibleIndexes.length,
                              itemBuilder: (context, visibleIndex) {
                                final cueIndex = visibleIndexes[visibleIndex];
                                final cue = cues[cueIndex];
                                final original = sourceCues != null && cueIndex < sourceCues.length
                                    ? sourceCues[cueIndex].text
                                    : null;
                                Future<void> editCue() async {
                                  final edited = await _editCueForReview(editorContext, cue);
                                  if (edited != null && mounted) {
                                    _rememberCueEdit(undoHistory, cueIndex, cue);
                                    setEditorState(() => cues[cueIndex] = edited);
                                    onChanged?.call();
                                  }
                                }

                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    'Cue ${cue.index} · ${_formatCueTime(cue.startMs)} – ${_formatCueTime(cue.endMs)}',
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (original != null) ...[
                                        Text('Original', style: Theme.of(context).textTheme.labelSmall),
                                        SelectableText(original),
                                        const SizedBox(height: 4),
                                      ],
                                      Text('Output', style: Theme.of(context).textTheme.labelSmall),
                                      SelectableText(cue.text),
                                    ],
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Edit cue',
                                    onPressed: editCue,
                                    icon: const AppIcon(Symbols.edit_rounded),
                                  ),
                                  onTap: editCue,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (undoHistory.isNotEmpty)
                  TextButton.icon(
                    onPressed: () {
                      final previous = undoHistory.removeLast();
                      setEditorState(() => cues[previous.$1] = previous.$2);
                      onChanged?.call();
                    },
                    icon: const AppIcon(Symbols.undo_rounded),
                    label: Text('Undo (${undoHistory.length})'),
                  ),
                TextButton(onPressed: () => Navigator.of(editorContext).pop(), child: const Text('Done')),
              ],
            );
          },
        ),
      );
    } finally {
      searchController.dispose();
    }
  }

  String? _normalizedUploadLanguage(String? languageCode) {
    final code = languageCode?.trim().toLowerCase().split(RegExp(r'[-_]')).first ?? '';
    return RegExp(r'^[a-z]{2,3}$').hasMatch(code) ? code : null;
  }

  String get _resultPersistenceSuffix {
    if (_lastResultSavedToSource) return ' Saved to the standalone source item.';
    if (_lastResultUploadedToServer) return ' Uploaded to the server library.';
    return '';
  }


  Future<void> _uploadSubtitleToServer(Uint8List bytes, String languageCode, String originToken) async {
    final serverId = widget.serverId;
    final ratingKey = widget.ratingKey;
    if (serverId == null || serverId.isEmpty || ratingKey == null || ratingKey.isEmpty) {
      throw StateError('This playback item is not linked to a server library entry.');
    }
    final client = context.tryGetMediaClientForServer(ServerId(serverId));
    if (client == null) throw StateError('The media server is offline or unavailable.');
    final uploaded = await client.attachSubtitle(
      ratingKey,
      bytes: bytes,
      fileName: 'PlezyNG.$originToken.$languageCode.srt',
      format: 'srt',
      language: languageCode,
      mediaIndex: widget.mediaIndex,
    );
    if (!uploaded) {
      throw UnsupportedError('The server refused this subtitle upload or does not support library attachment.');
    }
  }

  String _originTokenForOperation(String operationLabel) {
    final normalized = operationLabel.toLowerCase();
    if (normalized.contains('translat')) return 'translated';
    if (normalized.contains('sync') || normalized.contains('repair') || normalized.contains('align') ||
        normalized.contains('timing edit')) return 'synchronized';
    return 'generated';
  }

  Future<bool> _writeAndApply(
    List<SubtitleCue> cues, {
    required String operationLabel,
    String? operationLanguageCode,
    List<SubtitleCue>? sourceCues,
    List<String> reviewWarnings = const [],
    Map<String, Rect> regions = const {},
    bool onItemTimeline = false,
    Map<String, List<Rect>> avoidRegions = const {},
    List<SubtitleWordTiming> wordTimings = const <SubtitleWordTiming>[],
    SubtitleRevisionDraft? resumeDraft,
    SubtitleRevisionIdentity? resumeIdentity,
    Future<void> Function(List<SubtitleCue>)? onAcceptedReview,
  }) async {
    if (cues.isEmpty || cues.length > SubtitleRetimer.maximumCueCount) {
      throw const FormatException('Subtitle result has no cues or exceeds the 50000 cue processing bound.');
    }
    if (sourceCues != null && sourceCues.length != cues.length) {
      throw StateError('Source and output cue counts do not match; no subtitle was attached.');
    }
    var reviewedCues = List<SubtitleCue>.from(cues);
    Future<void> rememberAcceptedReview() async {
      if (onAcceptedReview == null) return;
      try { await onAcceptedReview(List<SubtitleCue>.unmodifiable(reviewedCues)); }
      catch (_) {
        if (mounted) setState(() => _revisionStatus = 'The subtitle was saved, but translation memory could not be updated.');
      }
    }
    final originalCuesById = <String, SubtitleCue>{for (final cue in cues) cue.stableId: cue};
    var reviewedWordTimings = SubtitleWordTimingBuilder.attachCueIndices(wordTimings, reviewedCues).toList();
    var invalidatedWordTimingCount = 0;
    final undoHistory = <(int, SubtitleCue)>[];
    final snapshot = _operationSnapshot;
    final draftIdentity = resumeIdentity ?? (snapshot == null ? _revisionIdentity : snapshot.revisionIdentity);
    final sourceFingerprint = SubtitleRevisionService.reviewFingerprint(cues, sourceCues: sourceCues);
    if (resumeDraft != null) {
      if (draftIdentity == null ||
          resumeIdentity == null ||
          draftIdentity.storageKey != resumeIdentity.storageKey ||
          (snapshot != null && snapshot.revisionIdentity?.storageKey != resumeIdentity.storageKey) ||
          resumeDraft.sourceFingerprint != sourceFingerprint ||
          resumeDraft.operation != operationLabel || resumeDraft.onItemTimeline != onItemTimeline) {
        throw StateError('This subtitle review draft no longer matches the active item or cue set.');
      }
      reviewedCues = List<SubtitleCue>.from(resumeDraft.cues);
      reviewedWordTimings = List<SubtitleWordTiming>.from(resumeDraft.wordTimings);
      undoHistory.addAll(resumeDraft.undoHistory);
    } else if (draftIdentity != null) {
      final draft = await SubtitleRevisionService.loadDraftForIdentity(draftIdentity);
      if (draft != null && mounted) {
        if (draft.sourceFingerprint == sourceFingerprint && draft.operation == operationLabel && draft.onItemTimeline == onItemTimeline) {
          final recovery = await _askToRecoverSubtitleDraft(draft);
          if (recovery == null) {
            setState(() => _revisionStatus = 'The saved review draft is still available to resume later.');
            return false;
          }
          if (recovery) {
            reviewedCues = List<SubtitleCue>.from(draft.cues);
            reviewedWordTimings = List<SubtitleWordTiming>.from(draft.wordTimings);
            undoHistory.addAll(draft.undoHistory);
          } else {
            await _deleteSubtitleDraft(draftIdentity);
          }
        } else {
          final discardPriorDraft = await _askToReplaceSubtitleDraft(draft);
          if (discardPriorDraft != true) {
            setState(() => _revisionStatus = 'The earlier review draft was kept; resume it from subtitle history.');
            return false;
          }
          await _deleteSubtitleDraft(draftIdentity);
        }
      }
    }
    Future<void> persistReviewDraft() async {
      if (draftIdentity == null) return;
      try {
        await SubtitleRevisionService.saveDraft(
          identity: draftIdentity,
          draft: SubtitleRevisionDraft(
            onItemTimeline: onItemTimeline,
            sourceFingerprint: sourceFingerprint,
            savedAt: DateTime.now().toUtc(),
            operation: operationLabel,
            languageCode: operationLanguageCode,
            baseCues: List<SubtitleCue>.unmodifiable(cues),
            sourceCues: sourceCues == null ? null : List<SubtitleCue>.unmodifiable(sourceCues),
            cues: List<SubtitleCue>.unmodifiable(reviewedCues),
            wordTimings: List<SubtitleWordTiming>.unmodifiable(reviewedWordTimings),
            undoHistory: List<(int, SubtitleCue)>.unmodifiable(undoHistory),
          ),
        );
        if (mounted) setState(() => _revisionStatus = 'Saved this subtitle review and its undo steps on this device.');
      } catch (error) {
        if (mounted) setState(() => _revisionStatus = 'Could not save the subtitle review draft: $error');
      }
    }
    var pendingDraftWrite = Future<void>.value();
    void scheduleDraftPersistence() {
      pendingDraftWrite = pendingDraftWrite.then((_) => persistReviewDraft());
    }

    Future<void> clearReviewDraft() async {
      await pendingDraftWrite;
      await _deleteSubtitleDraft(draftIdentity);
    }
    _lastResultUploadedToServer = false;
    _lastResultSavedToSource = false;
    final uploadLanguage = _normalizedUploadLanguage(operationLanguageCode);
    final canUploadToServer =
        !onItemTimeline && uploadLanguage != null && widget.serverId?.isNotEmpty == true && widget.ratingKey?.isNotEmpty == true;
    final canSaveToSource = widget.onSaveToSource != null;
    final List<int> previewIndexes;
    if (cues.length <= 12) {
      previewIndexes = List<int>.generate(cues.length, (index) => index);
    } else {
      final sample = <int>{
        ...List<int>.generate(8, (index) => index),
        cues.length ~/ 2,
        ...List<int>.generate(3, (index) => cues.length - 3 + index),
      };
      previewIndexes = sample.toList()..sort();
    }
    final choice = await showDialog<_SubtitleReviewChoice>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Review $operationLabel'),
          content: SizedBox(
            width: 560,
            height: (MediaQuery.sizeOf(dialogContext).height - 220).clamp(240.0, 420.0).toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${cues.length} cues are ready. Review this sample before attaching the generated SRT.'),
                if (onItemTimeline) const Text('These cues use the complete item timeline. Native/local sidecar attachment converts to the opened part; multipart server upload is unavailable without an explicit server part contract.'),
                if (reviewWarnings.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Translation review found ${reviewWarnings.length} possible mismatch${reviewWarnings.length == 1 ? '' : 'es'} in glossary terms or numbers. Review these cues before attaching.',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const SizedBox(height: 4),
                        ...reviewWarnings
                            .take(3)
                            .map(
                              (warning) => Tooltip(
                                message: warning,
                                child: Text(
                                  warning,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        if (reviewWarnings.length > 3)
                          Text('And ${reviewWarnings.length - 3} more.', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                Text(
                  draftIdentity == null
                      ? 'Edits and undo stay in this review session. Save SRT or JSON exports a separate result without changing the source subtitle.'
                      : 'Edits and undo steps auto-save to this device for this item. Save SRT or JSON exports a separate result without changing the source subtitle.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  reviewedWordTimings.isEmpty
                      ? 'This backend did not return token timestamps; cue timing remains available.'
                      : 'JSON includes ${reviewedWordTimings.length} token-derived word timings. Editing a cue omits its linked spans so timings cannot become stale. Whisper token confidence is not calibrated.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton.icon(
                  onPressed: () => unawaited(
                    _showFullCueEditor(
                      dialogContext,
                      reviewedCues,
                      sourceCues: sourceCues,
                      undoHistory: undoHistory,
                      onChanged: () {
                        setDialogState(() {});
                        scheduleDraftPersistence();
                      },
                    ),
                  ),
                  icon: const AppIcon(Symbols.edit_rounded),
                  label: const Text('Edit all cues'),
                ),
                if (widget.selectedSubtitleBurnedIn)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'The currently selected captions are burned into this video image. Attaching generated subtitles adds a separate track and cannot erase those pixels.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (canUploadToServer)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Upload + attach stores this SRT on the active library item when the server allows it.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else if (canSaveToSource)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'This SRT can be stored with the active standalone source item and attached to this player.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      uploadLanguage == null
                          ? 'Server upload is unavailable because this result has no known subtitle language. You can still attach it to the current player.'
                          : 'Server upload is unavailable because this is not an active server library item. You can still attach it to the current player.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.builder(
                    itemCount: previewIndexes.length,
                    itemBuilder: (context, index) {
                      final cueIndex = previewIndexes[index];
                      final cue = reviewedCues[cueIndex];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_formatCueTime(cue.startMs)} – ${_formatCueTime(cue.endMs)}',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const SizedBox(height: 2),
                            if (sourceCues != null && cueIndex < sourceCues.length) ...[
                              Text('Original', style: Theme.of(context).textTheme.labelSmall),
                              SelectableText(sourceCues[cueIndex].text),
                              const SizedBox(height: 2),
                            ],
                            SelectableText(cue.text),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () async {
                                  final edited = await _editCueForReview(dialogContext, cue);
                                  if (edited != null && mounted) {
                                    setDialogState(() {
                                      _rememberCueEdit(undoHistory, cueIndex, cue);
                                      reviewedCues[cueIndex] = edited;
                                    });
                                    scheduleDraftPersistence();
                                  }
                                },
                                icon: const AppIcon(Symbols.edit_rounded),
                                label: const Text('Edit sample cue'),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (undoHistory.isNotEmpty)
              TextButton.icon(
                onPressed: () {
                  final previous = undoHistory.removeLast();
                  setDialogState(() => reviewedCues[previous.$1] = previous.$2);
                  scheduleDraftPersistence();
                },
                icon: const AppIcon(Symbols.undo_rounded),
                label: Text('Undo (${undoHistory.length})'),
              ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.exportSrt),
              icon: const AppIcon(Symbols.save_alt_rounded),
              label: const Text('Save SRT'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.exportJson),
              icon: const AppIcon(Symbols.data_object_rounded),
              label: const Text('Save JSON'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.discard),
              child: const Text('Discard'),
            ),
            if (canUploadToServer)
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.serverAndPlayer),
                child: const Text('Upload + attach'),
              ),
            if (canSaveToSource)
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.sourceAndPlayer),
                child: const Text('Save to source + attach'),
              ),
            for (final lane in [_SubtitleReviewChoice.overlayPrimary, _SubtitleReviewChoice.overlaySecondary])
              OutlinedButton(onPressed: () => Navigator.of(dialogContext).pop(lane),
                child: Text(lane == _SubtitleReviewChoice.overlayPrimary ? 'App overlay 1' : 'App overlay 2')),
            FilledButton(
              onPressed: widget.player.supportedLocalSubtitleExtensions.contains('srt')
                  ? () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.player) : null,
              child: const Text('Attach to player'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null || choice == _SubtitleReviewChoice.discard) {
      if (mounted) {
        setState(() => _status = 'Subtitle result discarded; the current track and source file are unchanged.');
      }
      await clearReviewDraft();
      return false;
    }
    if (choice != _SubtitleReviewChoice.exportSrt && choice != _SubtitleReviewChoice.exportJson) {
      _requireCurrentOperationIdentity();
    }
    final editedCueIds = <String>{};
    for (final cue in reviewedCues) {
      final original = originalCuesById[cue.stableId];
      if (original != null &&
          (original.startMs != cue.startMs || original.endMs != cue.endMs || original.text != cue.text)) {
        editedCueIds.add(cue.stableId);
      }
    }
    if (editedCueIds.isNotEmpty && reviewedWordTimings.isNotEmpty) {
      final retainedWordTimings = reviewedWordTimings
          .where((word) => word.cueId == null || !editedCueIds.contains(word.cueId))
          .toList(growable: false);
      invalidatedWordTimingCount = reviewedWordTimings.length - retainedWordTimings.length;
      reviewedWordTimings = retainedWordTimings;
    }
    final bytes = SubtitleSyncService.writeSrt(reviewedCues);
    final originToken = _originTokenForOperation(operationLabel);
    if (choice == _SubtitleReviewChoice.exportSrt) {
      final exportPath = await FilePickerService.instance.saveFile(
        dialogTitle: 'Save reviewed subtitle',
        fileName: 'PlezyNG_${originToken}_${DateTime.now().microsecondsSinceEpoch}.srt',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['srt'],
      );
      if (!mounted) return false;
      if (exportPath == null) {
        setState(() => _status = 'SRT export was cancelled; the active track and source subtitle are unchanged.');
        return false;
      }
      await _storeUndoHistory(
        cues: reviewedCues,
        undoHistory: undoHistory,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
        identity: draftIdentity,
        onItemTimeline: onItemTimeline,
      );
      final revisionSaved = await _storeReviewedRevision(
        cues: reviewedCues,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
        identity: draftIdentity,
        onItemTimeline: onItemTimeline,
      );
      if (revisionSaved) await clearReviewDraft();
      await rememberAcceptedReview();
      if (mounted) setState(() => _status = 'Reviewed subtitle exported as SRT.');
      return false;
    }
    if (choice == _SubtitleReviewChoice.exportJson) {
      final jsonBytes = Uint8List.fromList(
        utf8.encode(
          JsonEncoder.withIndent('  ').convert({
            'schema': 'plezyng.subtitle-cues.v3',
            'onItemTimeline': onItemTimeline,
            'generatedBy': 'PlezyNG',
            'operation': operationLabel,
            'language': operationLanguageCode,
            'timebase': 'milliseconds',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'cues': reviewedCues
                .map(
                  (cue) => {
                    'cueId': cue.stableId,
                    'index': cue.index,
                    'startMs': cue.startMs,
                    'endMs': cue.endMs,
                    'text': cue.text,
                  },
                )
                .toList(growable: false),
            'wordTimingAvailability': reviewedWordTimings.isEmpty
                ? (wordTimings.isEmpty ? 'not-returned-by-backend' : 'omitted-after-cue-edits')
                : (invalidatedWordTimingCount > 0 ? 'partial-after-cue-edits' : 'backend-word-or-token-timestamps'),
            'wordTimingOmittedCount': invalidatedWordTimingCount,
            'wordTimings': reviewedWordTimings
                .map(
                  (word) => {
                    'startMs': word.startMs,
                    'endMs': word.endMs,
                    'text': word.text,
                    'unit': word.unit.name,
                    'probability': word.confidence,
                    'cueIndex': word.cueIndex,
                    'cueId': word.cueId,
                  },
                )
                .toList(growable: false),
          }),
        ),
      );
      final exportPath = await FilePickerService.instance.saveFile(
        dialogTitle: 'Save reviewed subtitle cue JSON',
        fileName: 'PlezyNG_${originToken}_${DateTime.now().microsecondsSinceEpoch}.json',
        bytes: jsonBytes,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (!mounted) return false;
      if (exportPath == null) {
        setState(() => _status = 'JSON export was cancelled; the active track and source subtitle are unchanged.');
        return false;
      }
      await _storeUndoHistory(
        cues: reviewedCues,
        undoHistory: undoHistory,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
        identity: draftIdentity,
        onItemTimeline: onItemTimeline,
      );
      final revisionSaved = await _storeReviewedRevision(
        cues: reviewedCues,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
        identity: draftIdentity,
        onItemTimeline: onItemTimeline,
      );
      if (revisionSaved) await clearReviewDraft();
      await rememberAcceptedReview();
      if (mounted) setState(() => _status = 'Reviewed subtitle exported as versioned cue JSON.');
      return false;
    }
    final nativeBytes = choice == _SubtitleReviewChoice.overlayPrimary || choice == _SubtitleReviewChoice.overlaySecondary
        ? bytes : await _bytesForNativeTimeline(reviewedCues, onItemTimeline);
    if (choice == _SubtitleReviewChoice.serverAndPlayer) {
      final languageCode = uploadLanguage;
      if (languageCode == null) throw StateError('The result language could not be identified for server upload.');
      await _uploadSubtitleToServer(bytes, languageCode, originToken);
      _lastResultUploadedToServer = true;
    }
    try {
      if (choice == _SubtitleReviewChoice.overlayPrimary || choice == _SubtitleReviewChoice.overlaySecondary) {
        final profiles = context.read<ActiveProfileProvider>();
        final profileId = profiles.activeId;
        final isSourceCurrent = widget.isRevisionIdentityCurrent;
        final lane = choice == _SubtitleReviewChoice.overlayPrimary ? 0 : 1;
        final surviving = reviewedCues.map((c) => c.stableId).toSet();
        final originalById = {for (final c in cues) c.stableId: c};
        final unchangedTimes = {for (final c in reviewedCues) if (originalById[c.stableId]?.startMs == c.startMs && originalById[c.stableId]?.endMs == c.endMs) c.stableId};
        final overlayOffset = onItemTimeline ? 0 : widget.player.timelineOffset.inMilliseconds;
        final overlayWords = overlayOffset == 0 ? reviewedWordTimings : reviewedWordTimings.map((word) => SubtitleWordTiming(
          startMs: word.startMs + overlayOffset, endMs: word.endMs + overlayOffset,
          text: word.text, confidence: word.confidence, unit: word.unit, cueIndex: word.cueIndex, cueId: word.cueId,
        )).toList(growable: false);
        final track = SubtitleOverlayTrack(cues: onItemTimeline ? reviewedCues : _fileCuesOnItemTimeline(reviewedCues),
          words: overlayWords, title: operationLabel, reviewed: true,
          regions: {for (final r in regions.entries) if (surviving.contains(r.key)) r.key: r.value},
          avoidRegions: {for (final r in avoidRegions.entries) if (unchangedTimes.contains(r.key)) r.key: r.value}, profileId: profileId, language: operationLanguageCode,
          isCurrent: () => profiles.activeId == profileId && isSourceCurrent?.call() != false);
        track.position = lane == 0 ? .9 : .12;
        SubtitleOverlayService.attach(widget.player, lane, track);
      } else if (choice == _SubtitleReviewChoice.sourceAndPlayer) {
        final saveToSource = widget.onSaveToSource;
        if (saveToSource == null) throw StateError('This item cannot store a standalone subtitle sidecar.');
        _requireCurrentOperationIdentity();
        await saveToSource('PlezyNG.$originToken.srt', nativeBytes, operationLanguageCode?.trim() ?? '');
        _lastResultSavedToSource = true;
      } else {
        final directory = await getTemporaryDirectory();
        final path = p.join(
          directory.path,
          'plezyng_ai_${originToken}_${DateTime.now().microsecondsSinceEpoch}.srt',
        );
        await File(path).writeAsBytes(nativeBytes, flush: true);
        _requireCurrentOperationIdentity();
        await widget.player.command(['sub-add', path, 'select']);
      }
    } catch (error) {
      if (_lastResultUploadedToServer) {
        await _storeUndoHistory(
          cues: reviewedCues,
          undoHistory: undoHistory,
          operation: operationLabel,
          languageCode: operationLanguageCode,
          wordTimings: reviewedWordTimings,
          identity: draftIdentity,
          onItemTimeline: onItemTimeline,
        );
        await _storeReviewedRevision(
          cues: reviewedCues,
          operation: operationLabel,
          languageCode: operationLanguageCode,
          wordTimings: reviewedWordTimings,
          identity: draftIdentity,
          onItemTimeline: onItemTimeline,
        );
        throw StateError('Uploaded to the server library, but could not attach the local copy: $error');
      }
      rethrow;
    }
    await _storeUndoHistory(
      cues: reviewedCues,
      undoHistory: undoHistory,
      operation: operationLabel,
      languageCode: operationLanguageCode,
      wordTimings: reviewedWordTimings,
      identity: draftIdentity,
      onItemTimeline: onItemTimeline,
    );
    final revisionSaved = await _storeReviewedRevision(
      cues: reviewedCues,
      operation: operationLabel,
      languageCode: operationLanguageCode,
      wordTimings: reviewedWordTimings,
      identity: draftIdentity,
      onItemTimeline: onItemTimeline,
    );
    if (revisionSaved) await clearReviewDraft();
    await rememberAcceptedReview();
    return true;
  }

  String _formatCueTime(int milliseconds) {
    final hours = milliseconds ~/ 3600000;
    final minutes = milliseconds ~/ 60000 % 60;
    final seconds = milliseconds ~/ 1000 % 60;
    final millis = milliseconds % 1000;
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    return '${pad(hours, 2)}:${pad(minutes, 2)}:${pad(seconds, 2)},${pad(millis, 3)}';
  }

  Future<void> _showApplied() async {
    if (!mounted) return;
    // Keep the result attached to the current session. The path is app-managed
    // temporary storage and will be removed by the OS when its cache is cleared.
    OverlaySheetController.of(context).refocus();
  }

  String _readableError(Object error) {
    if (error is UnsupportedError || error is FormatException || error is ArgumentError || error is StateError) {
      return error.toString().replaceFirst(
        RegExp(r'^(Unsupported operation|FormatException|Invalid argument|Bad state):\s*'),
        '',
      );
    }
    return 'Subtitle operation failed: $error';
  }

  Widget _languageSelector({
    required String label,
    required TranslateLanguage value,
    required ValueChanged<TranslateLanguage?> onChanged,
  }) {
    return Expanded(
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<TranslateLanguage>(
            value: value,
            isExpanded: true,
            items: SubtitleTranslationService.languages
                .map(
                  (language) => DropdownMenuItem(
                    value: language,
                    child: Text(SubtitleTranslationService.languageLabel(language), overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(growable: false),
            onChanged: _busy ? null : onChanged,
          ),
        ),
      ),
    );
  }

  Map<String, TranslateLanguage> _whisperLanguagesByCode() {
    final languages = <String, TranslateLanguage>{};
    for (final language in SubtitleTranslationService.languages) {
      final code = language.bcpCode.toLowerCase().split(RegExp(r'[-_]')).first;
      if (RegExp(r'^[a-z]{2,3}$').hasMatch(code)) languages.putIfAbsent(code, () => language);
    }
    return languages;
  }

  Widget _speechLanguageSelector() {
    final supportsOverride =
        _provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu;
    final languages = _whisperLanguagesByCode();
    final selected = languages.containsKey(_speechLanguageCode) ? _speechLanguageCode : 'auto';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Speech language', border: OutlineInputBorder()),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              items: [
                const DropdownMenuItem(value: 'auto', child: Text('Auto-detect')),
                ...languages.entries.map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      '${SubtitleTranslationService.languageLabel(entry.value)} (${entry.key.toUpperCase()})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: _busy || !supportsOverride
                  ? null
                  : (value) {
                      final code = value ?? 'auto';
                      setState(() => _speechLanguageCode = code);
                      unawaited(_saveSpeechLanguageForProfile(code));
                    },
            ),
          ),
        ),
        if (!supportsOverride)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'The selected accelerator uses an English-only model. Choose Whisper CPU or desktop GPU to override language.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final localSpeech = SubtitleAiService.supportedPlatform;
    final providers = SubtitleAiService.availableProviderRequests;
    final liveProviders = providers
        .where(
          (provider) =>
              provider == SubtitleInferenceProvider.cpu || provider == SubtitleInferenceProvider.desktopGpu,
        )
        .toList(growable: false);
    if (!providers.contains(_provider)) _provider = SubtitleInferenceProvider.cpu;
    if (!liveProviders.contains(_liveProvider)) _liveProvider = SubtitleInferenceProvider.cpu;
    return BaseVideoControlSheet(
      title: 'AI subtitles',
      icon: Symbols.auto_awesome_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          Text(
            'WAV transcription and audio sync use a 16-bit PCM WAV from the same title and audio track; subtitle sync can also use an already synchronized same-language reference. Live captions are available only when the active player build exposes its bounded decoded-PCM tap.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Inference backend', border: OutlineInputBorder()),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<SubtitleInferenceProvider>(
                value: _provider,
                isExpanded: true,
                items: providers
                    .map(
                      (provider) => DropdownMenuItem(
                        value: provider,
                        child: Text(provider.displayName, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _busy || providers.length < 2
                    ? null
                    : (value) => setState(() {
                        _provider = value ?? SubtitleInferenceProvider.cpu;
                        if (_provider != SubtitleInferenceProvider.cpu &&
                            _provider != SubtitleInferenceProvider.desktopGpu) {
                          _translateSpeechToEnglish = false;
                          _speechLanguageCode = 'auto';
                          unawaited(_saveSpeechLanguageForProfile('auto'));
                        }
                      }),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _provider == SubtitleInferenceProvider.desktopGpu
                ? 'Desktop GPU uses CUDA or Vulkan only when compiled into the native Whisper runtime. Successful inference does not prove every operation ran on the GPU; placement is unverified and failures restart on CPU.'
                : 'CPU is the baseline. Core ML/QNN/RKNN are provider requests for the installed native runtime; unsupported requests retry on CPU. The result reports provider initialization/fallback and marks per-operation placement as unverified.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _speechLanguageSelector(),
          const SizedBox(height: 10),
          if (_busy) const LinearProgressIndicator(),
          if (_busy && _activeCompanion != null)
            TextButton(onPressed: _cancelCompanionUpload, child: const Text('Cancel companion upload/job')),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_revisionStatus != null) ...[
            const SizedBox(height: 6),
            Text(_revisionStatus!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_revisionIdentity != null)
            FocusableListTile(
              leading: const AppIcon(Symbols.history_rounded),
              title: const Text('Subtitle revision history'),
              subtitle: const Text('Restore, export, or delete reviewed versions stored on this device'),
              onTap: _busy ? null : () => unawaited(_showRevisionHistory()),
            ),
          if (_revisionIdentity != null)
            FocusableListTile(leading: const Icon(Icons.cloud_sync), title: const Text('Sync reviewed subtitles across devices'),
              subtitle: const Text('Encrypted cloud transfer with explicit item pairing and conflict choices'),
              onTap: _busy ? null : () => unawaited(_run(() async {
                final identity = _operationRevisionIdentity;
                if (identity == null) return;
                await showDialog<void>(context: context, builder: (_) => SubtitleCloudSyncDialog(identity: identity,
                  isCurrent: () => mounted && _operationIdentityIsCurrent && _operationRevisionIdentity?.storageKey == identity.storageKey));
              }))),
          const Divider(height: 24),
          Text('Companion processing', style: Theme.of(context).textTheme.titleMedium),
          const Text('Optional processing on a paired host. Each upload requires explicit selection. Results are reviewed before attachment.'),
          FocusableListTile(leading: const AppIcon(Symbols.settings_rounded), title: const Text('Pair subtitle companion'),
            onTap: _busy ? null : () => unawaited(_configureCompanion())),
          FocusableListTile(leading: const AppIcon(Symbols.history_rounded), title: const Text('Companion jobs'),
            subtitle: const Text('Resume, cancel, review, or delete uploaded media and results'),
            onTap: _busy ? null : () => unawaited(_showCompanionJobs())),
          Row(children: [
            _languageSelector(label: 'Companion source / spoken language', value: _sourceLanguage,
              onChanged: (value) => _changeTranslationLanguage(source: true, value: value)),
            const SizedBox(width: 8),
            _languageSelector(label: 'Companion translation language', value: _targetLanguage,
              onChanged: (value) => _changeTranslationLanguage(source: false, value: value)),
          ]),
          for (final entry in const <(String, String)>[
            ('transcribe', 'Transcribe a media file on the companion'),
            ('ensemble', 'Compare two recognition models'),
            ('separate', 'Separate overlapping voice candidates (experimental)'),
            ('sound_events', 'Propose sound-event captions (experimental)'),
            ('completeness', 'Compare detected speech against subtitle coverage'),
            ('extract_text', 'Extract an embedded text subtitle stream'),
            ('signs', 'Read on-screen signs in a chosen crop'),
            ('align', 'Force-align a matching-language transcript'),
            ('singing_align', 'Propose lyric word timing against music (experimental)'),
            ('diarize', 'Transcribe with anonymous speaker labels'),
            ('translate', 'Translate subtitles on the companion'),
            ('translate_model', 'Translate with faithful, natural, or literal wording'),
            ('script_convert', 'Convert Chinese script or region variants'),
            ('reading', 'Add Japanese kana or romanization readings'),
            ('dubbing', 'Synthesize a timed subtitle voice track'),
            ('dub_mix', 'Mix synthesized subtitles with explicitly uploaded audio'),
            ('scene_review', 'Review uncertain captions against scene images'),
            ('ocr_auto', 'Find a burned-caption region and read it'),
            ('ocr', 'Extract burned captions from a video crop'),
            ('bitmap_ocr', 'Read PGS/VobSub images and correct OCR'),
          ]) FocusableListTile(leading: const AppIcon(Symbols.auto_awesome_rounded), title: Text(entry.$2),
            onTap: _busy || _revisionIdentity == null ? null : () => unawaited(_submitCompanion(entry.$1))),
          TextButton(onPressed: () => unawaited(_run(_openOverlayControls)), child: const Text('App overlay appearance and cover')),
          if (localSpeech && SubtitleReadAheadService.available) AnimatedBuilder(
            animation: SubtitleReadAheadService.instance, builder: (context, _) {
              final service = SubtitleReadAheadService.instance;
              return FocusableListTile(leading: const AppIcon(Symbols.subtitles_rounded),
                title: Text(service.running ? 'Stop preparing playback captions' : 'Prepare playback captions ahead'),
                subtitle: Text(service.status), onTap: _busy || service.busy && !service.running
                    ? null : () => unawaited(_preparePlaybackCaptions()));
            }),
          if (!localSpeech) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Local speech inference is unavailable in this build. Companion processing and text-based editing remain available.')),
          if (_playbackCaptureSupported) ...[
            const Divider(height: 24),
            Text('Live captions from playback', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'The active player copies bounded decoded PCM with media timestamps. '
              'Live Whisper supports CPU and a best-effort compiled desktop GPU request; '
              'GPU placement is unverified and inference failures fall back to CPU. '
              'Audio is not saved, and captions arrive with a short delay.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            AnimatedBuilder(
              animation: SubtitlePlaybackTranscriptionService.instance,
              builder: (context, _) {
                final service = SubtitlePlaybackTranscriptionService.instance;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (SubtitleOnlineRecognizer.supported) ...[
                      TextButton(onPressed: _busy || service.isStarting || service.hasActiveSession ? null : () => unawaited(_run(() async {
                        final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
                        final path = result?.files.single.path;
                        if (mounted && path != null) setState(() => _streamingModelManifest = path);
                      })), child: const Text('Choose a local streaming-model manifest')),
                      if (_streamingModelManifest != null) ...[
                        Text('Streaming CPU model: ${p.basename(_streamingModelManifest!)}. Uses the manifest’s declared language. '
                          'Partial text can change. Final cue times cover decoder utterance windows; no word alignment is claimed.'),
                        TextButton(onPressed: _busy || service.isStarting || service.hasActiveSession ? null :
                          () => setState(() => _streamingModelManifest = null), child: const Text('Use multilingual Whisper')),
                      ],
                    ],
                    if (_streamingModelManifest == null && liveProviders.length > 1) ...[
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Live captions backend',
                          border: OutlineInputBorder(),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<SubtitleInferenceProvider>(
                            value: _liveProvider,
                            isExpanded: true,
                            items: liveProviders
                                .map(
                                  (provider) => DropdownMenuItem(
                                    value: provider,
                                    child: Text(provider.displayName, overflow: TextOverflow.ellipsis),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: _busy || service.isRunning || service.hasActiveSession || service.isStarting
                                ? null
                                : (value) => setState(() => _liveProvider = value ?? SubtitleInferenceProvider.cpu),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                    ] else if (_streamingModelManifest == null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Live captions backend: CPU (multilingual Whisper)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (_streamingModelManifest == null) SwitchListTile(title: const Text('Stabilize live partial captions'),
                      subtitle: const Text('Compare overlapping recognition passes before freezing text. Partial text can change and is excluded from history; pause/end and 12-second boundaries may finalize a single pass. Uses more inference work.'),
                      value: service.stableStreaming,
                      onChanged: service.isStarting || service.hasActiveSession ? null : service.setStableStreaming),
                    if (service.singlePassTails > 0) Text('${service.singlePassTails} caption tails finalized at a pause or bounded window without two-pass agreement.'),
                    SwitchListTile(
                      title: const Text('Show late captions when recognition finishes'),
                      subtitle: const Text('Off uses exact media timing only. DVR replay reuses retained finalized cues. '
                        'This does not delay the video or send overlays into native PiP or Cast.'),
                      value: service.showDelayedText,
                      onChanged: service.setShowDelayedText,
                    ),
                    if (service.droppedAudioMs > 0 || service.discontinuities > 0)
                      Text('Dropped analysis audio: ${service.droppedAudioMs} ms; '
                        'clock discontinuities: ${service.discontinuities}. Missing audio is not inferred.'),
                    if (service.status != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(service.status!, style: Theme.of(context).textTheme.bodySmall),
                      ),
                    FocusableListTile(
                      leading: AppIcon(
                        service.isStarting
                            ? Symbols.sync_rounded
                            : (service.isRunning || service.hasActiveSession)
                            ? Symbols.stop_circle_rounded
                            : Symbols.closed_caption_rounded,
                      ),
                      title: Text(
                        service.isStarting
                            ? 'Preparing live captions…'
                            : (service.isRunning || service.hasActiveSession)
                            ? 'Stop live capture'
                            : 'Start live captions',
                      ),
                      subtitle: Text(
                        service.isStarting
                            ? 'Loading the local recognition model'
                            : (service.isRunning || service.hasActiveSession)
                            ? 'Stop capture and retain the transcript for sync'
                            : _streamingModelManifest == null
                            ? 'This player session; downloads the local Whisper model on first use'
                            : 'This player session; verifies and loads the selected local streaming model',
                      ),
                      onTap: (_busy || service.isStarting) ? null : () => unawaited(_captureLivePlayback()),
                    ),
                    if (service.hasRecentTranscript)
                      FocusableListTile(
                        leading: const AppIcon(Symbols.search_rounded),
                        title: const Text('Browse captured transcript'),
                        subtitle: const Text('Search cues, seek to their start, or hide future dialogue'),
                        onTap: () => unawaited(_showCapturedTranscript(service)),
                      ),
                    if (service.hasRecentTranscript &&
                        !service.isRunning &&
                        !service.isStarting &&
                        !service.hasActiveSession &&
                        _revisionIdentity != null)
                      FocusableListTile(
                        leading: const AppIcon(Symbols.save_rounded),
                        title: const Text('Save transcript to revision history'),
                        subtitle: const Text('Keep its cues and word timings with this item on this device'),
                        onTap: _busy ? null : () => unawaited(_saveCapturedTranscript(service)),
                      ),
                    if (_revisionIdentity != null) ...[
                      FocusableListTile(
                        leading: const AppIcon(Symbols.sync_rounded),
                        title: const Text('Sync from a saved transcript'),
                        subtitle: const Text('Reuse watched-portion speech saved for this item'),
                        onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscript(repairCuts: false)),
                      ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.content_cut_rounded),
                        title: const Text('Repair cuts from a saved transcript'),
                        subtitle: const Text('Keep timing outside the transcript evidence'),
                        onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscript(repairCuts: true)),
                      ),
                      if (_translationSupported) ...[
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: const Text('Translate a saved transcript into subtitles'),
                          subtitle: const Text('Reuse its speech timings for another subtitle language'),
                          onTap: _busy ? null : () => unawaited(_translateSavedTranscript()),
                        ),
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: const Text('Sync across languages from a saved transcript'),
                          subtitle: const Text('Translate target cues locally to match this transcript language'),
                          onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscriptAcrossLanguages(repairCuts: false)),
                        ),
                        FocusableListTile(
                          leading: const AppIcon(Symbols.content_cut_rounded),
                          title: const Text('Repair cuts across languages from a saved transcript'),
                          subtitle: const Text('Use translated text for anchors and preserve original dialogue'),
                          onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscriptAcrossLanguages(repairCuts: true)),
                        ),
                      ],
                    ],
                    if (service.hasRecentTranscript && !service.isRunning) ...[
                      if (_translationSupported)
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: const Text('Translate captured speech into subtitles'),
                          subtitle: const Text('Create timed subtitles in another language for the watched portion'),
                          onTap: _busy ? null : () => unawaited(_translateCapturedTranscript()),
                        ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.sync_rounded),
                        title: const Text('Sync from captured playback'),
                        subtitle: const Text('Aligns the watched portion against an existing subtitle'),
                        onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlayback(repairCuts: false)),
                      ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.content_cut_rounded),
                        title: const Text('Repair cuts from captured playback'),
                        subtitle: const Text('Preserves cue timing outside speech-matched evidence'),
                        onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlayback(repairCuts: true)),
                      ),
                      if (_translationSupported) ...[
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: const Text('Sync across languages from captured playback'),
                          subtitle: const Text('Translate target cues locally to match detected speech language'),
                          onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlaybackAcrossLanguages(repairCuts: false)),
                        ),
                        FocusableListTile(
                          leading: const AppIcon(Symbols.content_cut_rounded),
                          title: const Text('Repair cuts across languages from captured playback'),
                          subtitle: const Text('Use translated text for anchors and preserve original dialogue'),
                          onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlaybackAcrossLanguages(repairCuts: true)),
                        ),
                      ],
                    ],
                  ],
                );
              },
            ),
          ],
          const Divider(height: 24),
          if (_provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Translate detected speech to English'),
              subtitle: const Text(
                'Used only for generation; sync always transcribes the source language. Whisper translates audio instead of transcribing it.',
              ),
              value: _translateSpeechToEnglish,
              onChanged: _busy ? null : (value) => setState(() => _translateSpeechToEnglish = value),
            ),
          FocusableListTile(
            leading: const AppIcon(Symbols.graphic_eq_rounded),
            title: Text(
              _translateSpeechToEnglish ? 'Translate speech to English from WAV' : 'Generate subtitles from WAV',
            ),
            subtitle: Text(
              _provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu
                  ? 'Downloads a verified multilingual Whisper model on first use'
                  : 'Downloads a verified English model on first use',
            ),
            onTap: _busy || !localSpeech ? null : () => unawaited(_transcribe()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.queue_music_rounded),
            title: const Text('Queue resumable WAV transcription'),
            subtitle: const Text('Checkpointed windows, playhead priority, pause/resume, and power policy'),
            onTap: _busy || !localSpeech || _revisionIdentity == null ? null : () => unawaited(_queueTranscription()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.settings_rounded),
            title: const Text('Local subtitle resources'),
            subtitle: const Text('Power, heat, memory pressure and multiview admission controls'),
            onTap: () => unawaited(showDialog<void>(context: context, builder: (_) => const SubtitleResourceDialog())),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.history_rounded),
            title: const Text('Transcription jobs'),
            subtitle: const Text('Manage this profile’s jobs and review complete or partial results'),
            onTap: _busy ? null : () => unawaited(_manageTranscriptionJobs()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.queue_music_rounded),
            title: const Text('Replace captions in an interval'),
            subtitle: const Text('Transcribe a selected WAV range; keep source cues outside it'),
            onTap: _busy || !localSpeech ? null : () => unawaited(_generateInterval(fillSpeechGaps: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.add_comment_rounded),
            title: const Text('Fill speech-detected caption gaps'),
            subtitle: const Text('Add recognized speech only in long uncovered ranges; review before attaching'),
            onTap: _busy || !localSpeech ? null : () => unawaited(_generateInterval(fillSpeechGaps: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.sync_rounded),
            title: const Text('Automatically sync an existing subtitle'),
            subtitle: const Text('Aligns SRT, VTT, ASS, or SSA text against local speech recognition'),
            onTap: _busy || !localSpeech ? null : () => unawaited(_synchronize(repairCuts: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.edit_rounded),
            title: const Text('Reflow, correct, filter, or convert FPS'),
            subtitle: const Text('Preview reading limits, explicit spelling fixes, SDH/song/credit filters, and timing conversion'),
            onTap: _busy ? null : () => unawaited(_transformSubtitles()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.spellcheck_rounded),
            title: const Text('Review spelling with an offline dictionary'),
            subtitle: const Text('Choose a language pack and approve individual word occurrences'),
            onTap: _busy ? null : () => unawaited(_reviewDictionarySpelling()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.subtitles_rounded),
            title: const Text('Convert or repair subtitle text encoding'),
            subtitle: const Text('Preview legacy encodings, TTML/IMSC text, SAMI, MicroDVD, SBV, LRC, or MPL2 as a separate SRT'),
            onTap: _busy ? null : () => unawaited(_importTextSubtitle()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.folder_open_rounded),
            title: const Text('Find subtitles in folders'),
            subtitle: const Text('Search beside local media or in this profile’s chosen subtitle folders'),
            onTap: _busy ? null : () => unawaited(_discoverSubtitles()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.replay_rounded),
            title: const Text('Study a subtitle transcript'),
            subtitle: const Text('Search, replay, pause after lines, loop with gaps, and save phrases from a matching subtitle'),
            onTap: _busy ? null : () => unawaited(_studySubtitle()),
          ),
          if (_revisionIdentity != null) FocusableListTile(
            leading: const AppIcon(Symbols.history_rounded),
            title: const Text('Study a saved transcript'),
            subtitle: const Text('Reuse this item’s saved speech transcript and source times'),
            onTap: _busy ? null : () => unawaited(_studySubtitle(saved: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.graphic_eq_rounded),
            title: const Text('Waveform and spectrogram editor'),
            subtitle: const Text('Edit cue anchors against a matching WAV interval up to five minutes'),
            onTap: _busy ? null : () => unawaited(_editWaveform()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: const Text('Repair cuts and sync'),
            subtitle: const Text('Uses piecewise timing where subtitle/audio text anchors suggest a cut offset change'),
            onTap: _busy || !localSpeech ? null : () => unawaited(_synchronize(repairCuts: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.closed_caption_rounded),
            title: const Text('Sync to another subtitle'),
            subtitle: const Text('Use a same-language SRT, VTT, ASS, or SSA subtitle as the timing reference'),
            onTap: _busy ? null : () => unawaited(_synchronizeToReference(repairCuts: false)),
          ),
          if (_translationSupported)
            FocusableListTile(
              leading: const AppIcon(Symbols.translate_rounded),
              title: const Text('Sync across subtitle languages'),
              subtitle: const Text('Translate target text locally for matching; keep its original text'),
              onTap: _busy ? null : () => unawaited(_synchronizeAcrossLanguages(repairCuts: false)),
            ),
          if (_translationSupported)
            FocusableListTile(
              leading: const AppIcon(Symbols.content_cut_rounded),
              title: const Text('Repair cuts across subtitle languages'),
              subtitle: const Text('Uses translated text for anchors and keeps the original target text'),
              onTap: _busy ? null : () => unawaited(_synchronizeAcrossLanguages(repairCuts: true)),
            ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: const Text('Repair cuts using another subtitle'),
            subtitle: const Text('Apply piecewise offsets where dialogue anchors show a timing discontinuity'),
            onTap: _busy ? null : () => unawaited(_synchronizeToReference(repairCuts: true)),
          ),
          if (_translationSupported) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Reuse and remember reviewed translations'),
              subtitle: const Text('Profile-local exact text/context and glossary matches. Only accepted results are remembered; model revisions are not reported.'),
              value: _useTranslationMemory,
              onChanged: _busy ? null : (value) => setState(() => _useTranslationMemory = value),
            ),
            TextButton(onPressed: _busy ? null : () => _run(() async {
              final profile = _activeProfileId;
              if (profile == null) return;
              await SubtitleTranslationMemory.clear(profile);
              if (mounted) setState(() => _status = 'Reviewed translation memory cleared for this profile.');
            }), child: const Text('Clear this profile’s translation memory')),
            const Divider(height: 24),
            Text('Local subtitle translation', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              SubtitleTranslationService.desktopPlatformSupported
                  ? 'Desktop uses optional local Argos Translate. Install its Python package and the source-to-target language model; set PLEZY_ARGOS_PYTHON if python/python3 is not on PATH.'
                  : 'Mobile translation uses on-device ML Kit models.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _languageSelector(
                  label: 'Source',
                  value: _sourceLanguage,
                  onChanged: (value) => _changeTranslationLanguage(source: true, value: value),
                ),
                const SizedBox(width: 8),
                _languageSelector(
                  label: 'Target',
                  value: _targetLanguage,
                  onChanged: (value) => _changeTranslationLanguage(source: false, value: value),
                ),
              ],
            ),
            if (widget.seriesKey?.isNotEmpty == true)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use a series-specific glossary'),
                subtitle: const Text('Starts with the profile glossary; saved edits apply only to this series.'),
                value: _useSeriesGlossary,
                onChanged: _busy
                    ? null
                    : (value) {
                        _glossaryDrafts[_currentGlossaryDraftKey()] = _glossaryController.text;
                        setState(() => _useSeriesGlossary = value);
                        unawaited(_loadGlossaryForCurrentPair());
                      },
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Bilingual subtitle output'),
              subtitle: const Text('Show the original line followed by its translation in each cue'),
              value: _bilingualTranslation,
              onChanged: _busy ? null : (value) => setState(() => _bilingualTranslation = value),
            ),
            TextField(
              controller: _glossaryController,
              minLines: 2,
              maxLines: 4,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Translation glossary (JSON)',
                hintText: '{"TARDIS":"TARDIS","The Doctor":"El Doctor"}',
                helperText: widget.seriesKey == null
                    ? 'Protects up to 200 whole terms. Saved for this profile and language pair.'
                    : 'Protects up to 200 terms. Choose profile or series scope above.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => _glossaryDrafts[_currentGlossaryDraftKey()] = value,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_showGlossaryHistory()),
                    icon: const AppIcon(Symbols.history_rounded),
                    label: const Text('History'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => unawaited(_run(_saveGlossary)),
                    icon: const AppIcon(Symbols.save_rounded),
                    label: const Text('Save glossary'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (SubtitleTranslationService.mobilePlatformSupported) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow language-model downloads over mobile data'),
                value: _allowMobileData,
                onChanged: _busy ? null : (value) => setState(() => _allowMobileData = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_prepareTranslationModels()),
                  icon: const AppIcon(Symbols.download_for_offline_rounded),
                  label: const Text('Prepare offline language models'),
                ),
              ),
            ],
            if (SubtitleTranslationService.desktopPlatformSupported && (Platform.isWindows || Platform.isLinux))
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Request Argos CUDA'),
                subtitle: const Text(
                  'Requires a CUDA-enabled Argos/CTranslate2 install and an NVIDIA driver. If the request fails, translation retries on CPU; actual per-operation placement is not reported.',
                ),
                value: _requestTranslationCuda,
                onChanged: _busy ? null : (value) => setState(() => _requestTranslationCuda = value),
              ),
            Text(
              SubtitleTranslationService.desktopPlatformSupported
                  ? 'Subtitle text stays local. Argos does not report per-cue hardware placement; GPU requests are best-effort.'
                  : 'Translation runs locally through ML Kit. Its CPU/GPU choice is not exposed by the provider.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            FocusableListTile(
              leading: const AppIcon(Symbols.translate_rounded),
              title: const Text('Translate an existing subtitle'),
              subtitle: const Text('Timing and source file remain unchanged'),
              onTap: _busy ? null : () => unawaited(_translate()),
            ),
          ],
        ],
      ),
    );
  }
}

/// Search and seek within the in-memory transcript captured from the watched
/// portion of the current Android ExoPlayer VOD session.
class _CapturedTranscriptDialog extends StatefulWidget {
  const _CapturedTranscriptDialog({required this.player, required this.service});

  final Player player;
  final SubtitlePlaybackTranscriptionService service;

  @override
  State<_CapturedTranscriptDialog> createState() => _CapturedTranscriptDialogState();
}

class _CapturedTranscriptDialogState extends State<_CapturedTranscriptDialog> {
  final TextEditingController _searchController = TextEditingController();
  bool _hideFutureDialogue = false;
  List<SubtitleCue>? _cachedSource;
  List<SubtitleCue> _filteredCues = const <SubtitleCue>[];
  String _cachedQuery = '';
  int _cachedVisibleCount = -1;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int _visibleCueCount(List<SubtitleCue> cues, int positionMs) {
    var low = 0;
    var high = cues.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (cues[middle].startMs <= positionMs) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  List<SubtitleCue> _filterCues(List<SubtitleCue> cues, int visibleCount) {
    final query = _searchController.text.trim().toLowerCase();
    if (identical(_cachedSource, cues) && _cachedQuery == query && _cachedVisibleCount == visibleCount) {
      return _filteredCues;
    }
    final results = <SubtitleCue>[];
    for (var index = 0; index < visibleCount; index++) {
      final cue = cues[index];
      if (query.isEmpty || cue.text.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), ' ').toLowerCase().contains(query)) {
        results.add(cue);
      }
    }
    _cachedSource = cues;
    _cachedQuery = query;
    _cachedVisibleCount = visibleCount;
    _filteredCues = results;
    return results;
  }

  String _formatTime(int milliseconds) {
    final totalMs = milliseconds.clamp(0, SubtitleRetimer.maximumTimeMs).toInt();
    final hours = totalMs ~/ 3600000;
    final minutes = totalMs ~/ 60000 % 60;
    final seconds = totalMs ~/ 1000 % 60;
    final millis = totalMs % 1000;
    final clock =
        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
    return hours == 0 ? clock : '${hours.toString().padLeft(2, '0')}:$clock';
  }

  Future<void> _seekToCue(SubtitleCue cue) async {
    try {
      await widget.player.seek(Duration(milliseconds: cue.startMs));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Could not seek to this transcript cue.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final cues = widget.service.recentTranscript?.cues ?? const <SubtitleCue>[];
        return StreamBuilder<Duration>(
          stream: widget.player.streams.position,
          initialData: widget.player.currentPosition,
          builder: (context, snapshot) {
            final position = snapshot.data ?? widget.player.currentPosition;
            final visibleCount = _hideFutureDialogue ? _visibleCueCount(cues, position.inMilliseconds) : cues.length;
            final filtered = _filterCues(cues, visibleCount);
            final canSeek = widget.player.state.seekable && !widget.player.disposed;
            final height = (MediaQuery.of(context).size.height * 0.68).clamp(260.0, 560.0).toDouble();
            return AlertDialog(
              title: const Text('Captured transcript'),
              content: SizedBox(
                width: 620,
                height: height,
                child: Column(
                  children: [
                    Text(
                      'Only watched portions are included. Selecting a cue seeks to its start.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const AppIcon(Symbols.search_rounded),
                        labelText: 'Search transcript',
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const AppIcon(Symbols.clear_rounded),
                              ),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Hide future dialogue'),
                      subtitle: const Text('Show cues from the current playhead and earlier'),
                      value: _hideFutureDialogue,
                      onChanged: (value) => setState(() => _hideFutureDialogue = value),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${filtered.length} of ${cues.length} cues'
                        '${canSeek ? '' : ' · seeking unavailable'}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                cues.isEmpty
                                    ? 'No speech cues yet. Keep capture running or stop it after speech is recognized.'
                                    : 'No cues match this view.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final cue = filtered[index];
                                final current =
                                    position.inMilliseconds >= cue.startMs && position.inMilliseconds <= cue.endMs;
                                return ListTile(
                                  dense: true,
                                  selected: current,
                                  enabled: canSeek,
                                  leading: Text(
                                    _formatTime(cue.startMs),
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                  title: Text(cue.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                                  onTap: canSeek ? () => unawaited(_seekToCue(cue)) : null,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
            );
          },
        );
      },
    );
  }
}
