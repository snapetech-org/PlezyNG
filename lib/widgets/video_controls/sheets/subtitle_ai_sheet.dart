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

import '../../../i18n/strings.g.dart';
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
import '../../../services/subtitle_language_text.dart';
import '../../../services/subtitle_sync_service.dart';
import '../../../services/subtitle_interval_service.dart';
import '../../../services/subtitle_job_service.dart';
import '../../../services/subtitle_job_source.dart';
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
import 'subtitle_array_dialog.dart';
import 'subtitle_dictionary_dialog.dart';
import 'subtitle_language_dialog.dart';
import 'subtitle_archive_dialog.dart';

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
    required this.profileId,
    required this.audioId,
    required this.timelineOffsetMs,
  });

  final Player player;
  final int? mediaSessionGeneration;
  final SubtitleRevisionIdentity? revisionIdentity;
  final String? profileId;
  final String? audioId;
  final int timelineOffsetMs;

  bool isCurrent({
    required Player currentPlayer,
    required SubtitleRevisionIdentity? currentRevisionIdentity,
    required String? currentProfileId,
    required bool Function()? isRevisionIdentityCurrent,
  }) {
    if (!identical(player, currentPlayer)) return false;
    if (currentPlayer.disposed || currentPlayer.state.track.audio?.id != audioId) return false;
    if (currentPlayer.timelineOffset.inMilliseconds != timelineOffsetMs) return false;
    if (currentProfileId != profileId) return false;
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
    this.openReadAheadSource,
    this.seriesKey,
    this.selectedSubtitleBurnedIn = false,
    this.appOverlayOnly = false,
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
  /// Optional explicit live-clock preparation owned by a standalone source UI.
  final Future<SubtitleAnalysisSource?> Function()? openReadAheadSource;
  final String? seriesKey;
  final bool selectedSubtitleBurnedIn;
  /// Audio-only owners have no native caption presentation surface.
  final bool appOverlayOnly;

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

  Translations get _t => Translations.of(context);

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
      profileId: _activeProfileId,
      audioId: player.state.track.audio?.id,
      timelineOffsetMs: player.timelineOffset.inMilliseconds,
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
      if (!mounted || !_operationIdentityIsCurrent) return;
    } catch (error) {
      if (mounted && _operationIdentityIsCurrent) {
        setState(() => _error = _readableError(error));
      }
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
      currentProfileId: _activeProfileId,
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

  Future<SubtitleJobSource> _openJobSource(int ordinal) async {
    _requireCurrentOperationIdentity();
    final player = widget.player, profiles = context.read<ActiveProfileProvider>();
    final profile = profiles.activeId, track = player.state.track.audio;
    if (player is SubtitlePcmCaptureSource && player.isLivePlayback) {
      throw UnsupportedError('Resumable source jobs require a complete VOD file.');
    }
    final generation = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final sourceCurrent = widget.isRevisionIdentityCurrent;
    bool current() => profiles.activeId == profile && !player.disposed && sourceCurrent?.call() != false &&
        (generation == null || (player as PlayerMediaSessionIdentity).mediaSessionGeneration == generation) &&
        player.state.track.audio?.id == track?.id;
    return SubtitleJobSource.open(
      openSource: widget.openAnalysisSource ?? () => SubtitleAnalysisSource.localPlayer(player, current),
      audioOrdinal: ordinal,
      audioDescriptor: jsonEncode([track?.id, track?.language, track?.title, track?.codec, track?.channels]),
      fallbackDurationMs: player.state.duration.inMilliseconds, isCurrent: current);
  }

  Future<void> _queueTranscription({bool useSource = false}) => _run(() async {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleJobs;
    final identity = _operationRevisionIdentity;
    if (identity == null) throw StateError('Open a stable library item or local file to create a resumable job.');
    final profiles = context.read<ActiveProfileProvider>();
    final service = SubtitleJobService.instance..bindProfile(profiles);
    await service.ready;
    final wavPath = useSource ? null : await _pickWav();
    if (!useSource && wavPath == null || !mounted) return;
    var chargingOnly = false;
    var idleOnly = false;
    var followPlayhead = true;
    final ordinalInput = TextEditingController(text: '0');
    var ordinal = 0;
    bool? accepted;
    try {
    accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, update) => AlertDialog(
        title: Text(copy.queueTitle),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(useSource ? copy.sourceHelp : copy.wavHelp),
          if (useSource) TextField(controller: ordinalInput, keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: copy.ordinalLabel, helperText: copy.ordinalHelp)),
          SwitchListTile(title: Text(copy.prioritizePlayhead), value: followPlayhead,
              onChanged: (value) => update(() => followPlayhead = value)),
          SwitchListTile(title: Text(copy.externalPower), value: chargingOnly,
              onChanged: (value) => update(() => chargingOnly = value)),
          SwitchListTile(title: Text(copy.playbackIdle), value: idleOnly,
              onChanged: (value) => update(() => idleOnly = value)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () {
            final value = int.tryParse(ordinalInput.text);
            if (useSource && (value == null || value < 0 || value > 63)) return;
            ordinal = value ?? 0; Navigator.pop(dialogContext, true);
          }, child: Text(copy.queueAction)),
        ],
      )),
    );
    } finally { ordinalInput.dispose(); }
    if (accepted != true || !mounted) return;
    _requireCurrentOperationIdentity();
    final player = widget.player;
    final session = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final profileId = profiles.activeId;
    int playhead() => !player.disposed && profiles.activeId == profileId &&
        (session == null || (player as PlayerMediaSessionIdentity).mediaSessionGeneration == session)
        ? player.currentPosition.inMilliseconds : 0;
    bool playing() => !player.disposed && player.state.playing;
    if (useSource) {
      final source = await _openJobSource(ordinal);
      await service.enqueueSource(source: source,
        identityKey: identity.storageKey, title: widget.mediaTitle ?? copy.sourceTitle,
        provider: _provider, language: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
        translateToEnglish: _translateSpeechToEnglish, chargingOnly: chargingOnly, idleOnly: idleOnly,
        playheadMs: followPlayhead ? playhead : null, playbackBusy: playing);
    } else {
    await service.enqueue(
      wavPath: wavPath!, identityKey: identity.storageKey, title: widget.mediaTitle ?? copy.wavTitle,
      provider: _provider, language: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      translateToEnglish: _translateSpeechToEnglish, chargingOnly: chargingOnly, idleOnly: idleOnly,
      playheadMs: followPlayhead ? playhead : null, playbackBusy: playing,
    );
    }
    if (mounted) setState(() => _status = copy.queuedStatus);
  });

  Future<void> _manageTranscriptionJobs() => _run(() async {
    final service = SubtitleJobService.instance..bindProfile(context.read<ActiveProfileProvider>());
    await service.ready;
    if (!mounted) return;
    final player = widget.player;
    final session = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final job = await showDialog<SubtitleJob>(context: context, builder: (_) => SubtitleJobsDialog(
      identityKey: _operationRevisionIdentity?.storageKey,
      openSource: (job) => _openJobSource(job.audioOrdinal!),
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
    final offset = job.usesSourceDecoder ? job.timelineOffsetMs : 0;
    final cues = offset == 0 ? result.cues : [for (final cue in result.cues) SubtitleCue(
      index: cue.index, startMs: cue.startMs + offset, endMs: cue.endMs + offset, text: cue.text, cueId: cue.stableId)];
    final words = offset == 0 ? result.wordTimings : [for (final word in result.wordTimings) SubtitleWordTiming(
      startMs: word.startMs + offset, endMs: word.endMs + offset, text: word.text, confidence: word.confidence,
      unit: word.unit, cueIndex: word.cueIndex, cueId: word.cueId)];
    await _writeAndApply(cues,
      operationLabel: complete ? 'Queued transcription' : 'Partial queued transcription',
      operationLanguageCode: result.detectedLanguage,
      wordTimings: words, onItemTimeline: job.usesSourceDecoder,
      reviewWarnings: [
        if (!complete) 'Only ${job.completedChunks} of ${job.chunkCount} audio windows are included. Unprocessed ranges have no captions.',
        'Backend: ${result.runtimeProvider}. ${result.placementEvidence.displayLabel}.',
      ],
    );
  });

  Future<SubtitleAudioInterval?> _chooseAudioInterval(int durationMs) async {
    final copy = Translations.of(context).videoControls.subtitleAiControls;
    if (durationMs <= 0) throw FormatException(copy.audioDurationUnavailable);
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
            title: Text(copy.audioIntervalTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(copy.audioIntervalDescription),
                const SizedBox(height: 12),
                TextField(
                  controller: startController,
                  keyboardType: TextInputType.datetime,
                  decoration: InputDecoration(labelText: copy.start, hintText: 'HH:MM:SS'),
                ),
                TextField(
                  controller: endController,
                  keyboardType: TextInputType.datetime,
                  decoration: InputDecoration(labelText: copy.end, hintText: 'HH:MM:SS'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(Translations.of(dialogContext).common.cancel)),
              FilledButton(
                onPressed: () {
                  final interval = SubtitleAudioInterval.parse(
                    startController.text,
                    endController.text,
                    durationMs: durationMs,
                  );
                  if (interval == null) {
                    setDialogState(() => error = copy.invalidAudioInterval);
                    return;
                  }
                  Navigator.of(dialogContext).pop(interval);
                },
                child: Text(copy.useAudioInterval),
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
    final copy = Translations.of(context).videoControls.subtitleAiControls;
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
          title: Text(copy.transformPreviewTitle),
          content: SizedBox(width: 600, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(copy.transformPreviewDescription),
            SwitchListTile(title: Text(copy.reflowPlainText), value: reflow, onChanged: (v) => update(() => reflow = v)),
            Text(copy.lineLimit(count: width.round())),
            Slider(value: width, min: 24, max: 64, divisions: 40, label: '${width.round()}', onChanged: (v) => update(() => width = v)),
            Text(copy.readingSpeedWarning(count: speed.round())),
            Slider(value: speed, min: 8, max: 40, divisions: 32, label: '${speed.round()}', onChanged: (v) => update(() => speed = v)),
            SwitchListTile(title: Text(copy.normalizeSpacing), value: spacing, onChanged: (v) => update(() => spacing = v)),
            SwitchListTile(title: Text(copy.removeBracketedDescriptions),
              subtitle: Text(copy.removeBracketedDescriptionsHelp), value: descriptions,
              onChanged: (v) => update(() => descriptions = v)),
            SwitchListTile(title: Text(copy.removeMusicalLines), value: songs, onChanged: (v) => update(() => songs = v)),
            SwitchListTile(title: Text(copy.removeSubtitleCredits), subtitle: Text(copy.removeSubtitleCreditsHelp),
              value: credits, onChanged: (v) => update(() => credits = v)),
            DropdownButtonFormField<String>(
              initialValue: fps, decoration: InputDecoration(labelText: copy.explicitFpsConversion),
              items: [
                DropdownMenuItem(value: 'none', child: Text(copy.noFpsConversion)),
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
                decoration: InputDecoration(labelText: copy.explicitCorrectionsJson, hintText: '{"teh": "the"}')),
            if (validation != null) Text(validation!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
              child: Text(Translations.of(dialogContext).common.cancel)),
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
              } catch (_) { update(() => validation = copy.invalidCorrectionJson); }
            }, child: Text(copy.previewTransformations)),
          ],
        ),
      ));
    } finally { corrections.dispose(); }
    if (options == null || !mounted) return;
    final result = SubtitleEditingService.transform(selected.$1, options);
    final retainedIds = result.cues.map((cue) => cue.stableId).toSet();
    await _writeAndApply(result.cues,
      operationLabel: copy.transformOperationLabel,
      sourceCues: result.removed == 0 ? selected.$1 : null,
      reviewWarnings: [
        copy.transformationSummary(changed: result.changed, removed: result.removed, source: selected.$2),
        ...selected.$1.where((cue) => !retainedIds.contains(cue.stableId)).take(20)
            .map((cue) => copy.removedCue(index: cue.index, text: cue.text)),
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
    final translations = Translations.of(context);
    final aiCopy = translations.videoControls.subtitleAiControls;
    final profile = _activeProfileId;
    if (profile == null) throw StateError(aiCopy.pairingProfileRequired);
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
          title: Text(aiCopy.pairCompanion),
          content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(aiCopy.pairingSecurityDescription),
            TextField(controller: address, decoration: InputDecoration(labelText: aiCopy.pairingHostUrl), keyboardType: TextInputType.url),
            TextField(controller: token, obscureText: true, enableSuggestions: false, autocorrect: false,
                decoration: InputDecoration(labelText: aiCopy.pairingToken)),
            SwitchListTile(title: Text(aiCopy.pairingRememberTitle),
              subtitle: Text(aiCopy.pairingRememberDescription),
              value: remember, onChanged: saving ? null : (value) => update(() => remember = value)),
            if (saving) const LinearProgressIndicator(),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ])),
          actions: [
            TextButton(onPressed: saving ? null : () async {
              update(() => saving = true);
              try { await SubtitleCompanionService.forget(profile); if (dialogContext.mounted) Navigator.pop(dialogContext); }
              catch (_) { if (dialogContext.mounted) update(() { saving = false; error = aiCopy.pairingRemoveFailed; }); }
            }, child: Text(aiCopy.pairingForget)),
            TextButton(onPressed: saving ? null : () => Navigator.pop(dialogContext), child: Text(translations.common.cancel)),
            FilledButton(onPressed: saving ? null : () async {
              update(() { saving = true; error = null; });
              try {
                if (_activeProfileId != profile) throw StateError(aiCopy.pairingProfileChanged);
                await SubtitleCompanionService.configure(profile, address.text, token.text.trim(), remember: remember);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (failure) {
                if (dialogContext.mounted) update(() { saving = false; error = _readableError(failure); });
              }
            }, child: Text(aiCopy.pairingSave)),
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
    final aiCopy = Translations.of(context).videoControls.subtitleAiControls;
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
      if (task == 'align' || task == 'singing_align' || task == 'completeness' || task == 'dub_mix' || task == 'scene_review' || task == 'scene_track' || task == 'sound_localize' || task == 'vocal_notes' || textTask) {
        final selected = await _pickSubtitleCues();
        if (selected == null || !mounted) return;
        cues = selected.$1;
        if (task == 'scene_track' && cues.length > 5000) throw const FormatException('Whole-file tracking accepts at most 5000 cues.');
      }
      String? path;
      var timelineOffsetMs = 0;
      var useCurrentSource = false;
      if (!textTask && cues.isEmpty && widget.openAnalysisSource != null && capabilities['sourceTimelineOffsets'] == true && task != 'bitmap_ocr' && mounted) {
        final choice = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: Text(aiCopy.companionInputTitle),
          content: Text(aiCopy.companionInputDescription),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Translations.of(context).common.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(aiCopy.companionInputChooseMatchingFile)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(aiCopy.companionInputUseCurrentSource))]));
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
        final selected = await FilePickerService.instance.pickFiles(
          type: task == 'sound_localize' || task == 'vocal_notes' ? FileType.custom : FileType.any,
          allowedExtensions: task == 'sound_localize' || task == 'vocal_notes' ? const ['wav'] : null);
        if (selected == null || selected.files.isEmpty || !mounted) return;
        final file = selected.files.first;
        final maximumInputBytes = task == 'sound_localize'
            ? SubtitleCompanionService.maximumMicrophoneArrayBytes
            : task == 'vocal_notes' ? SubtitleCompanionService.maximumVocalNoteBytes : SubtitleCompanionService.maximumInputBytes;
        if (file.size <= 0 || file.size > maximumInputBytes) throw FormatException(task == 'sound_localize'
            ? aiCopy.microphoneArrayFileError
            : task == 'vocal_notes' ? aiCopy.vocalNoteFileError
            : 'Choose media up to 1 GiB and within the task duration limit.');
        path = file.path;
        if (path == null) {
          final bytes = file.bytes;
          if (bytes == null || bytes.length > maximumInputBytes) throw const FormatException('The picker did not expose a bounded local media file.');
          final temp = await getTemporaryDirectory();
          path = p.join(temp.path, 'subtitle_companion_${DateTime.now().microsecondsSinceEpoch}.media');
          await File(path).writeAsBytes(bytes, flush: true);
          _temporaryWavPaths.add(path);
        }
      }
      if (!mounted) return;
      final microphoneArray = task == 'sound_localize' ? await showSubtitleArrayCalibration(context) : null;
      if (!mounted || task == 'sound_localize' && microphoneArray == null) return;
      var preprocess = false;
      var soundStereoEvidence = false;
      var sceneTemporalRegions = false;
      var sceneAudioEvidence = false;
      var sceneMotionTracking = false;
      var sceneObjectTracking = false;
      var lyricSyllables = <String, List<String>>{};
      var lyricPitchEvidence = false;
      var isolatedLeadVocal = false;
      var duckRatio = .25;
      var track = 0;
      var subtitleTrack = 0, bitmapTail = 2000;
      var translationMode = 'faithful', scriptConversion = 's2t', readingMode = 'hiragana';
      var cropTop = 0.65;
      final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: Text(task == 'vocal_notes' ? aiCopy.sendVocalNotesTitle
            : task == 'sound_localize' ? aiCopy.sendArrayLocalizationTitle : aiCopy.companionSendJobTitle),
          content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              aiCopy.companionJobUploadDescription(
                destination: service.endpoint,
                input: path == null ? aiCopy.companionSubtitleTextInput : aiCopy.companionSelectedMediaInput,
              ) +
                  (useCurrentSource
                      ? aiCopy.companionOpenedPartOffset(offset: timelineOffsetMs)
                      : ''),
            ),
            if ({'ensemble', 'separate', 'sound_events', 'completeness', 'signs'}.contains(task))
              Text(aiCopy.companionExperimentalEvidence),
            if (task == 'align') Text(aiCopy.companionAlignGuidance(
              language: SubtitleTranslationService.languageLabel(_sourceLanguage))),
            if (task == 'scene_track') Text(aiCopy.companionSceneTrackGuidance),
            if (task == 'singing_align') Text(aiCopy.companionSingingAlignGuidance(
              language: SubtitleTranslationService.languageLabel(_sourceLanguage))),
            if (task == 'singing_align' && capabilities['lyricSyllables'] == true) ...[
              TextButton(onPressed: () async {
                try {
                  final selected = await showSubtitleLyricUnits(dialogContext, cues, lyricSyllables);
                  if (selected != null && dialogContext.mounted) update(() => lyricSyllables = selected);
                } catch (error) {
                  if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text(_readableError(error))));
                }
              }, child: Text(aiCopy.companionSupplySyllableGroups(cues: lyricSyllables.length))),
              if (lyricSyllables.isNotEmpty) TextButton(onPressed: () => update(() => lyricSyllables = {}), child: Text(aiCopy.companionKeepWordProposalsOnly)),
            ],
            if (task == 'singing_align' && capabilities['lyricPitchEvidence'] == true) SwitchListTile(
              title: Text(aiCopy.companionMixPitchTitle),
              subtitle: Text(aiCopy.companionMixPitchDescription),
              value: lyricPitchEvidence, onChanged: (value) => update(() => lyricPitchEvidence = value)),
            if (task == 'translate') Text(aiCopy.companionTranslatePair(
              source: SubtitleTranslationService.languageLabel(_sourceLanguage),
              target: SubtitleTranslationService.languageLabel(_targetLanguage))),
            if (task == 'translate_model') ...[
              Text(aiCopy.companionExternalModelForwarding(
                destination: (modelProvider as Map)['destination'], model: modelProvider['model'],
                revision: modelProvider['declaredRevision'])),
              Text(aiCopy.companionModelTranslatePair(
                source: SubtitleTranslationService.languageLabel(_sourceLanguage),
                target: SubtitleTranslationService.languageLabel(_targetLanguage))),
              DropdownButtonFormField<String>(initialValue: translationMode, decoration: InputDecoration(labelText: aiCopy.companionTranslationMode),
                items: [DropdownMenuItem(value: 'faithful', child: Text(aiCopy.companionTranslationFaithful)),
                  DropdownMenuItem(value: 'natural', child: Text(aiCopy.companionTranslationNatural)),
                  DropdownMenuItem(value: 'literal', child: Text(aiCopy.companionTranslationLiteral))],
                onChanged: (value) => update(() => translationMode = value ?? 'faithful')),
              TextField(controller: _glossaryController, maxLines: 4, maxLength: 65536,
                decoration: InputDecoration(labelText: aiCopy.companionProtectedGlossaryLabel,
                  helperText: aiCopy.companionProtectedGlossaryHelper)),
            ],
            if (task == 'script_convert') ...[
              Text(aiCopy.companionScriptConversionDescription),
              DropdownButtonFormField<String>(initialValue: scriptConversion, isExpanded: true,
                decoration: InputDecoration(labelText: aiCopy.companionScriptConversionLabel),
                items: <String, String>{'s2t': aiCopy.scriptSimplifiedTraditional, 't2s': aiCopy.scriptTraditionalSimplified,
                  's2tw': aiCopy.scriptSimplifiedTaiwan, 'tw2s': aiCopy.scriptTaiwanSimplified,
                  's2hk': aiCopy.scriptSimplifiedHongKong, 'hk2s': aiCopy.scriptHongKongSimplified,
                  't2tw': aiCopy.scriptTraditionalTaiwan, 't2hk': aiCopy.scriptTraditionalHongKong,
                  's2twp': aiCopy.scriptSimplifiedTaiwanPhrases, 'tw2sp': aiCopy.scriptTaiwanPhrasesSimplified}.entries
                    .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (value) => update(() => scriptConversion = value ?? 's2t')),
            ],
            if (task == 'reading') ...[
              Text(aiCopy.companionReadingDescription),
              DropdownButtonFormField<String>(initialValue: readingMode, decoration: InputDecoration(labelText: aiCopy.companionReadingDisplay),
                items: [DropdownMenuItem(value: 'hiragana', child: Text(aiCopy.companionReadingHiragana)),
                  DropdownMenuItem(value: 'hepburn', child: Text(aiCopy.companionReadingHepburn)),
                  if (capabilities['readingModes'] is List && (capabilities['readingModes'] as List).contains('ruby'))
                    DropdownMenuItem(value: 'ruby', child: Text(aiCopy.companionReadingRuby))],
                onChanged: (value) => update(() => readingMode = value ?? 'hiragana')),
            ],
            if (task == 'scene_review') Text('${aiCopy.companionSceneForwardingDescription(
              frames: sceneTemporalRegions ? 3 : 1, provider: capabilities['visionProvider'])} '
              '${sceneAudioEvidence ? aiCopy.companionSceneAudioForwarded : aiCopy.companionSceneImageOnly} '
              '${aiCopy.companionSceneAlternativeWarning}'),
            if (task == 'scene_review' && capabilities['sceneAudioEvidence'] == true)
              SwitchListTile(title: Text(aiCopy.companionSceneAudioTitle),
                subtitle: Text(aiCopy.companionSceneAudioDescription),
                value: sceneAudioEvidence, onChanged: (v) => update(() => sceneAudioEvidence = v)),
            if (task == 'scene_review' && capabilities['sceneTemporalRegions'] == true)
              SwitchListTile(title: Text(aiCopy.companionSceneMovementTitle),
                subtitle: Text(aiCopy.companionSceneMovementDescription),
                value: sceneTemporalRegions, onChanged: (v) => update(() => sceneTemporalRegions = v)),
            if (task == 'scene_review' && capabilities['sceneMotionTracking'] == true)
              SwitchListTile(title: Text(aiCopy.companionSceneMotionTitle),
                subtitle: Text(aiCopy.companionSceneMotionDescription),
                value: sceneMotionTracking, onChanged: (v) => update(() => sceneMotionTracking = v)),
            if (task == 'scene_review' && capabilities['sceneObjectTracking'] == true) SwitchListTile(
              title: Text(aiCopy.companionSceneObjectTitle),
              subtitle: Text(aiCopy.companionSceneObjectDescription),
              value: sceneObjectTracking, onChanged: (value) => update(() => sceneObjectTracking = value)),
            if (task == 'ocr_auto') Text(aiCopy.companionOcrAutoDescription),
            if (task == 'dubbing' || task == 'dub_mix') ...[
              Text(aiCopy.companionDubbingDescription(voice: capabilities['synthesisVoice'])),
              if (task == 'dub_mix') ...[
                Text(aiCopy.companionDuckRatio(percent: (duckRatio * 100).round())),
                Slider(value: duckRatio, min: 0, max: 1, onChanged: (v) => update(() => duckRatio = v)),
              ],
            ],
            if (task == 'sound_events' && capabilities['soundStereoEvidence'] == true) SwitchListTile(
              title: Text(aiCopy.companionStereoEvidenceTitle),
              subtitle: Text(aiCopy.companionStereoEvidenceDescription),
              value: soundStereoEvidence, onChanged: (v) => update(() => soundStereoEvidence = v)),
            if (task == 'diarize') Text(aiCopy.companionDiarizeDescription),
            if (task == 'sound_localize') Text(aiCopy.microphoneArrayTaskDescription),
            if (task == 'vocal_notes') CheckboxListTile(value: isolatedLeadVocal,
              onChanged: (v) => update(() => isolatedLeadVocal = v == true),
              title: Text(aiCopy.vocalNoteTaskDeclarationTitle),
              subtitle: Text(aiCopy.vocalNoteTaskDeclarationDescription)),
            if (path != null && task != 'ocr' && task != 'bitmap_ocr' && task != 'sound_localize' && task != 'vocal_notes') ...[
              DropdownButtonFormField<int>(initialValue: track, decoration: InputDecoration(labelText: aiCopy.companionAudioStreamLabel),
                items: List.generate(16, (i) => DropdownMenuItem(value: i, child: Text(aiCopy.companionAudioStreamItem(index: i)))),
                onChanged: (value) => update(() => track = value ?? 0)),
              SwitchListTile(title: Text(aiCopy.companionPreprocessTitle), subtitle: Text(aiCopy.companionPreprocessDescription),
                value: preprocess, onChanged: (value) => update(() => preprocess = value)),
            ],
            if (task == 'ocr' || task == 'signs') ...[
              Text(aiCopy.companionBurnedOcrDescription),
              Text(aiCopy.companionCropDescription(percent: (cropTop * 100).round())),
              Slider(value: cropTop, min: 0, max: 0.9, divisions: 18, label: '${(cropTop * 100).round()}%',
                onChanged: (value) => update(() => cropTop = value)),
            ],
            if (task == 'bitmap_ocr' || task == 'extract_text') ...[
              if (task == 'bitmap_ocr') Text(aiCopy.companionBitmapOcrDescription),
              DropdownButtonFormField<int>(initialValue: subtitleTrack, decoration: InputDecoration(labelText: aiCopy.companionSubtitleStreamLabel),
                items: List.generate(16, (i) => DropdownMenuItem(value: i, child: Text(aiCopy.companionSubtitleStreamItem(index: i)))),
                onChanged: (value) => update(() => subtitleTrack = value ?? 0)),
              if (task == 'bitmap_ocr') DropdownButtonFormField<int>(initialValue: bitmapTail, decoration: InputDecoration(labelText: aiCopy.companionBitmapTailLabel),
                items: [1000, 2000, 3000, 5000, 10000, 30000].map((ms) => DropdownMenuItem(value: ms, child: Text(aiCopy.companionDurationMilliseconds(duration: ms)))).toList(),
                onChanged: (value) => update(() => bitmapTail = value ?? 2000)),
              if (task == 'bitmap_ocr') Text(aiCopy.companionBitmapLanguage(
                language: SubtitleTranslationService.languageLabel(_sourceLanguage))),
              if (task == 'extract_text') Text(aiCopy.companionExtractTextDescription),
            ],
            Text(aiCopy.companionHostBackends(tasks: (capabilities['tasks'] as List).join(', '))),
          ]))),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(Translations.of(dialogContext).common.cancel)),
            FilledButton(onPressed: task == 'vocal_notes' && !isolatedLeadVocal ? null : () => Navigator.pop(dialogContext, true),
              child: Text(task == 'translate_model' ? aiCopy.companionForwardTextAndTranslate : aiCopy.companionSendAndProcess))],
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
        microphoneArray: microphoneArray,
        isolatedLeadVocal: isolatedLeadVocal,
        sceneObjectTracking: sceneObjectTracking,
        sceneDetectorFingerprint: sceneObjectTracking || task == 'scene_track'
            ? (capabilities['sceneObjectDetector'] as Map?)?['fingerprint'] as String? : null,
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
      if (result.artifacts.isNotEmpty && result.artifacts.single.name == 'scene-tracks.jsonl') {
        final artifact = result.artifacts.single;
        final export = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('Review whole-file scene paths'),
          content: const Text('Export the digest-checked frame observations for independent review, or continue to the caption and placement preview. '
            'Anonymous track IDs and detector scores are unverified proposals. Missing observations have no inferred position.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Continue to preview')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Export frame log and continue'))]));
        if (export == null || !mounted) return;
        if (export) {
          _requireCurrentOperationIdentity();
          final bytes = await service.artifactBytes(job['id'] as String, artifact);
          _requireCurrentOperationIdentity();
          await FilePickerService.instance.saveFile(dialogTitle: 'Export scene observations', fileName: artifact.name,
            bytes: bytes, type: FileType.custom, allowedExtensions: const ['jsonl']);
          _requireCurrentOperationIdentity();
        }
      } else if (result.artifacts.isNotEmpty) {
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
    final aiCopy = Translations.of(context).videoControls.subtitleAiControls;
    if (widget.isRevisionIdentityCurrent?.call() == false) {
      throw StateError(aiCopy.savedTranscriptPlaybackChanged);
    }
    final identity = _revisionIdentity;
    if (identity == null) throw StateError(aiCopy.savedTranscriptProfileRequired);
    final transcripts = await SubtitleRevisionService.loadSavedTranscripts(
      profileId: identity.profileId,
      currentIdentity: identity,
    );
    if (transcripts.isEmpty) {
      throw FormatException(aiCopy.savedTranscriptNoResults);
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
              title: Text(aiCopy.savedTranscriptPickerTitle),
              content: SizedBox(
                width: 560,
                height: 420,
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(aiCopy.savedTranscriptPickerDescription),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: aiCopy.savedTranscriptSearchLabel,
                        prefixIcon: AppIcon(Symbols.search_rounded),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(child: Text(aiCopy.savedTranscriptNoMatches))
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final transcript = visible[index];
                                final language = transcript.languageCode;
                                final sameItem = transcript.storageKey == identity.storageKey;
                                return ListTile(
                                  title: Text(transcript.mediaTitle),
                                  subtitle: Text(
                                    aiCopy.savedTranscriptSummary(
                                      source: transcript.sourceLabel,
                                      date: _formatRevisionDate(transcript.createdAt),
                                      count: transcript.cueCount,
                                    ) +
                                        (language == null
                                            ? ''
                                            : aiCopy.savedTranscriptLanguageSuffix(language: language)) +
                                        (sameItem ? aiCopy.savedTranscriptSameItem : ''),
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
    final translations = Translations.of(context);
    final liveCopy = translations.videoControls.subtitleLive;
    if (service.running) { await service.stop(); return; }
    final input = TextEditingController(text: '0');
    final rendition = TextEditingController(text: '0');
    final live = widget.player is SubtitlePcmCaptureSource && (widget.player as SubtitlePcmCaptureSource).isLivePlayback;
    var selectedRendition = 0;
    final ordinal = await showDialog<int>(context: context, builder: (context) => AlertDialog(
      title: Text(liveCopy.readAheadTitle),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(live ? liveCopy.readAheadLiveDescription : liveCopy.readAheadVodDescription),
        TextField(controller: input, keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: liveCopy.audioOrdinalLabel)),
        if (live) TextField(controller: rendition, keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: liveCopy.liveAudioOrdinalLabel,
            helperText: liveCopy.liveAudioOrdinalHelp)),
        if (live && widget.openReadAheadSource != null) Text(liveCopy.readAheadClockHelp),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(translations.common.cancel)),
        FilledButton(onPressed: () {
          final value = int.tryParse(input.text), variant = int.tryParse(rendition.text);
          if (value != null && value >= 0 && value <= 63 && variant != null && variant >= 0 && variant <= 63) {
            selectedRendition = variant; Navigator.pop(context, value);
          }
        },
          child: Text(liveCopy.startAnalysis))]));
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
    SubtitleAnalysisSource? prepared;
    final prepare = widget.openReadAheadSource;
    if (prepare != null) {
      prepared = await prepare();
      if (prepared == null) return;
      if (!mounted || !current()) { await prepared.close(); return; }
    }
    final ready = prepared;
    var claimed = false;
    try {
      await service.start(player, open: ready != null ? () async { claimed = true; return ready; }
          : widget.openAnalysisSource ?? () => SubtitleAnalysisSource.localPlayer(player, current),
        isCurrent: current, audioOrdinal: ordinal, profileId: profile, language: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
        provider: _liveProvider, hlsRendition: selectedRendition);
    } finally { if (ready != null && !claimed) await ready.close(); }
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
    final aiCopy = Translations.of(context).videoControls.subtitleAiControls;
    var reference = fixedReference ?? _targetLanguage;
    var source = fixedReference != null && _sourceLanguage == fixedReference
        ? SubtitleTranslationService.languages.firstWhere((language) => language != fixedReference)
        : _sourceLanguage;
    return showDialog<(TranslateLanguage, TranslateLanguage)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(aiCopy.syncLanguageMatchTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<TranslateLanguage>(
                initialValue: source,
                decoration: InputDecoration(
                  labelText: fixedReference == null ? aiCopy.syncSubtitleToSynchronize : aiCopy.syncTargetSubtitleLanguage,
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
                decoration: InputDecoration(
                  labelText: fixedReference == null ? aiCopy.syncReferenceSubtitle : aiCopy.syncTranscriptLanguage,
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
                  child: Text(aiCopy.syncDifferentLanguagesHint),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(Translations.of(dialogContext).common.cancel)),
            FilledButton(
              onPressed: source == reference ? null : () => Navigator.of(dialogContext).pop((source, reference)),
              child: Text(aiCopy.continueAction),
            ),
          ],
        ),
      ),
    );
  }

  Future<TranslateLanguage?> _chooseTranscriptTranslationTarget(TranslateLanguage sourceLanguage) async {
    final aiCopy = Translations.of(context).videoControls.subtitleAiControls;
    var targetLanguage = _targetLanguage == sourceLanguage
        ? SubtitleTranslationService.languages.firstWhere((language) => language != sourceLanguage)
        : _targetLanguage;
    return showDialog<TranslateLanguage>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(aiCopy.translateTranscriptTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(aiCopy.translateTranscriptSpeechIdentified(
                source: SubtitleTranslationService.languageLabel(sourceLanguage))),
              const SizedBox(height: 10),
              DropdownButtonFormField<TranslateLanguage>(
                initialValue: targetLanguage,
                decoration: InputDecoration(labelText: aiCopy.translateTranscriptSubtitleLabel, border: const OutlineInputBorder()),
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
              Text(aiCopy.translateTranscriptLocalDescription),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(targetLanguage), child: Text(aiCopy.continueAction)),
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
      audioOnly: widget.appOverlayOnly,
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
      if (mounted) setState(() => _revisionStatus = _t.videoControls.subtitleReviewFlow.revisionIdentityRequired);
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
          () => _revisionStatus = _t.videoControls.subtitleReviewFlow.revisionSaved(id: revision.id),
        );
      }
      return true;
    } catch (error) {
      if (mounted) setState(() => _revisionStatus = _t.videoControls.subtitleReviewFlow.revisionSaveFailed(error: error));
      return false;
    }
  }

  Future<bool?> _askToRecoverSubtitleDraft(SubtitleRevisionDraft draft) {
    final copy = _t.videoControls.subtitleReviewFlow;
    final undoSteps = draft.undoHistory.length == 1 ? copy.oneUndoStep : copy.undoSteps(count: draft.undoHistory.length);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.resumeDraftTitle),
        content: Text(copy.resumeDraftDescription(operation: draft.operation.toLowerCase(),
          date: _formatRevisionDate(draft.savedAt), steps: undoSteps)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(copy.discardDraft)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(copy.resumeReview)),
        ],
      ),
    );
  }

  Future<bool?> _askToReplaceSubtitleDraft(SubtitleRevisionDraft draft) {
    final copy = _t.videoControls.subtitleReviewFlow;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.keepDraftTitle),
        content: Text(copy.keepDraftDescription(operation: draft.operation.toLowerCase(),
          date: _formatRevisionDate(draft.savedAt))),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(copy.keepSavedDraft)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(copy.deleteAndContinue)),
        ],
      ),
    );
  }

  Future<void> _deleteSubtitleDraft(SubtitleRevisionIdentity? identity) async {
    if (identity == null) return;
    try {
      await SubtitleRevisionService.deleteDraft(identity);
    } catch (error) {
      if (mounted) setState(() => _revisionStatus = _t.videoControls.subtitleReviewFlow.draftDeleteFailed(error: error));
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
              _t.videoControls.subtitleReviewFlow.undoIdentityHelp,
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
      if (mounted) setState(() => _revisionStatus = _t.videoControls.subtitleReviewFlow.undoCheckpointSaved);
      return true;
    } catch (error) {
      if (mounted) {
        setState(
          () => _revisionStatus = _t.videoControls.subtitleReviewFlow.undoCheckpointSaveFailed(error: error),
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
        throw FormatException(t.videoControls.subtitleAiControls.historyItemClockRangeExceeded);
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
      if (!mounted) throw StateError(t.videoControls.subtitleAiControls.historyPlaybackClosed);
      final copy = _t.videoControls.subtitleReviewFlow;
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(copy.clipPartTitle),
        content: Text(copy.clipPartDescription(count: output.clipped)),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(copy.attachThisPart))]));
      if (accepted != true) throw StateError(copy.attachmentCancelled);
    }
    _requireCurrentOperationIdentity();
    if (widget.player.timelineOffset.inMilliseconds != offset) {
      throw StateError(t.videoControls.subtitleAiControls.historyOpenedMediaPartChanged);
    }
    return output.bytes;
  }

  Future<void> _restoreSubtitleRevision(SubtitleRevision revision, SubtitleRevisionIdentity expectedIdentity) async {
    if (_operationRevisionIdentity?.storageKey != expectedIdentity.storageKey) {
      throw StateError(t.videoControls.subtitleAiControls.historyWrongItemProfile);
    }
    if (widget.appOverlayOnly) {
      await _writeAndApply(revision.cues, operationLabel: revision.operation,
        operationLanguageCode: revision.languageCode, onItemTimeline: revision.onItemTimeline,
        wordTimings: revision.wordTimings);
      return;
    }
    final bytes = await _bytesForNativeTimeline(revision.cues, revision.onItemTimeline);
    final directory = await getTemporaryDirectory();
    final path = p.join(directory.path, 'plezyng_revision_${revision.id}.srt');
    await File(path).writeAsBytes(bytes, flush: true);
    _requireCurrentOperationIdentity();
    await widget.player.command(['sub-add', path, 'select']);
    if (mounted) {
      setState(
        () => _status = t.videoControls.subtitleAiControls.historyAttachedRevision(
          date: _formatRevisionDate(revision.createdAt),
        ),
      );
      OverlaySheetController.of(context).refocus();
    }
  }

  Future<void> _exportSubtitleRevision(SubtitleRevision revision) async {
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: t.videoControls.subtitleAiControls.historyRevisionSrtExportTitle,
      fileName: 'PlezyNG_revision_${revision.id}.srt',
      bytes: SubtitleSyncService.writeSrt(revision.cues),
      type: FileType.custom,
      allowedExtensions: const ['srt'],
    );
    if (mounted && result != null) {
      setState(() => _status = t.videoControls.subtitleAiControls.historyRevisionSrtExported);
    }
  }

  Future<void> _exportSubtitleRevisionJson(SubtitleRevision revision) async {
    final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(revision.toJson())));
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: t.videoControls.subtitleAiControls.historyRevisionJsonExportTitle,
      fileName: 'PlezyNG_revision_${revision.id}.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (mounted && result != null) {
      setState(() => _status = t.videoControls.subtitleAiControls.historyRevisionJsonExported);
    }
  }

  Future<List<SubtitleRevision>?> _importSubtitleRevisionJson(SubtitleRevisionIdentity identity,
      {required bool Function() isHistoryCurrent}) async {
    final copy = t.videoControls.subtitleAiControls;
    final player = widget.player;
    final snapshot = _SubtitleOperationSnapshot(player: player,
      mediaSessionGeneration: player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null,
      revisionIdentity: identity, profileId: _activeProfileId, audioId: player.state.track.audio?.id,
      timelineOffsetMs: player.timelineOffset.inMilliseconds);
    bool current() => mounted && isHistoryCurrent() && snapshot.isCurrent(currentPlayer: widget.player,
      currentRevisionIdentity: _revisionIdentity, currentProfileId: _activeProfileId,
      isRevisionIdentityCurrent: widget.isRevisionIdentityCurrent);
    void requireCurrent() {
      if (!current()) throw StateError(copy.historyImportContextChanged);
    }
    requireCurrent();
    final picked = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withReadStream: true,
    );
    requireCurrent();
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.first;
    if (p.extension(file.name).toLowerCase() != '.json' ||
        file.size <= 0 ||
        file.size > SubtitleRevisionService.maximumHistoryBundleBytes) {
      throw FormatException(copy.historyImportSizeLimit);
    }
    Stream<List<int>>? source = file.readStream;
    if (source == null && file.path != null) {
      final input = File(file.path!);
      final actualSize = await input.length();
      if (actualSize != file.size) {
        throw FormatException(copy.historyImportFileChanged);
      }
      source = input.openRead();
    }
    final pickedBytes = file.bytes;
    if (source == null && pickedBytes != null) source = Stream<List<int>>.value(pickedBytes);
    if (source == null) {
      throw FormatException(copy.historyImportStreamUnavailable);
    }
    final output = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in source) {
      requireCurrent();
      received += chunk.length;
      if (received > SubtitleRevisionService.maximumHistoryBundleBytes) {
        throw FormatException(copy.historyImportSizeLimit);
      }
      output.add(chunk);
    }
    if (received != file.size) {
      throw FormatException(copy.historyImportFileTruncated);
    }
    if (received <= 0 || received > SubtitleRevisionService.maximumHistoryBundleBytes) {
      throw FormatException(copy.historyImportSizeLimit);
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
      throw FormatException(copy.historyImportInvalidRevisionCount);
    }
    final importedRevisions = rawRevisions
        .map((record) => SubtitleRevision.fromJson(_normalizeSubtitleRevisionImport(record)))
        .toList(growable: false);
    if (importedRevisions.map((revision) => revision.id).toSet().length != importedRevisions.length) {
      throw FormatException(copy.historyImportDuplicateRevisions);
    }
    final saved = <SubtitleRevision>[];
    for (final imported in importedRevisions.reversed) {
      requireCurrent();
      saved.add(
        await SubtitleRevisionService.saveRevision(
          identity: identity,
          operation: _importedSubtitleOperation(imported.operation),
          languageCode: imported.languageCode,
          cues: imported.cues,
          wordTimings: imported.wordTimings,
          onItemTimeline: imported.onItemTimeline,
          isCurrent: current,
        ),
      );
    }
    return saved.reversed.toList(growable: false);
  }

  Future<void> _exportSubtitleHistoryJson(SubtitleRevisionIdentity identity) async {
    final copy = t.videoControls.subtitleAiControls;
    final revisions = await SubtitleRevisionService.loadRevisions(identity);
    if (revisions.isEmpty) {
      if (mounted) setState(() => _revisionStatus = copy.historyExportNoSavedHistory);
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
      throw FormatException(copy.historyExportSizeLimit);
    }
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: copy.historyExportDialogTitle,
      fileName: 'PlezyNG_subtitle_history_${DateTime.now().microsecondsSinceEpoch}.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (mounted && result != null) {
      setState(
        () => _revisionStatus = revisions.length == 1
            ? copy.historyExportedOne
            : copy.historyExportedMany(count: revisions.length),
      );
    }
  }

  Future<bool> _confirmSubtitleHistoryImport() async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(t.videoControls.subtitleAiControls.historyImportConfirmTitle),
          content: Text(t.videoControls.subtitleAiControls.historyImportConfirmDescription),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(t.common.cancel)),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(t.videoControls.subtitleAiControls.continueAction)),
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
      throw FormatException(t.videoControls.subtitleAiControls.historyCueMetadataInvalid);
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
    final copy = t.videoControls.subtitleAiControls;
    final identity = _revisionIdentity;
    if (identity == null) {
      setState(() => _revisionStatus = copy.historyIdentityRequired);
      return;
    }
    final historyPlayer = widget.player;
    final historySnapshot = _SubtitleOperationSnapshot(player: historyPlayer,
      mediaSessionGeneration: historyPlayer is PlayerMediaSessionIdentity ? historyPlayer.mediaSessionGeneration : null,
      revisionIdentity: identity, profileId: _activeProfileId, audioId: historyPlayer.state.track.audio?.id,
      timelineOffsetMs: historyPlayer.timelineOffset.inMilliseconds);
    bool historyCurrent() => mounted && historySnapshot.isCurrent(currentPlayer: widget.player,
      currentRevisionIdentity: _revisionIdentity, currentProfileId: _activeProfileId,
      isRevisionIdentityCurrent: widget.isRevisionIdentityCurrent);
    try {
      var revisions = await SubtitleRevisionService.loadRevisions(identity);
      var draft = await SubtitleRevisionService.loadDraftForIdentity(identity);
      if (!historyCurrent()) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final height = (MediaQuery.sizeOf(dialogContext).height - 220).clamp(240.0, 460.0).toDouble();
            return AlertDialog(
              title: Row(
                children: [
                  Expanded(child: Text(copy.revisionHistoryTitle)),
                  IconButton(
                    tooltip: t.videoControls.subtitleArchive.title,
                    onPressed: () {
                      if (!historyCurrent()) return;
                      Navigator.of(dialogContext).pop();
                      unawaited(_run(() => showSubtitleArchiveDialog(context,
                        identity: identity, isCurrent: () => historyCurrent() && _operationIdentityIsCurrent &&
                            _revisionIdentity?.storageKey == identity.storageKey)));
                    },
                    icon: const AppIcon(Symbols.folder_open_rounded),
                  ),
                  IconButton(
                    tooltip: copy.historyRevisionExportBundleTooltip,
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
                    ? Center(child: Text(copy.historyEmptyState))
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
                                      copy.historyDraftTitle(operation: pendingDraft.operation),
                                      style: Theme.of(context).textTheme.titleSmall,
                                    ),
                                    Text(
                                      copy.historyDraftSummary(
                                        date: _formatRevisionDate(pendingDraft.savedAt),
                                        cues: pendingDraft.cues.length,
                                        cueLabel: pendingDraft.cues.length == 1
                                            ? copy.historyCueUnitSingular
                                            : copy.historyCueUnitPlural,
                                        undoSteps: pendingDraft.undoHistory.length,
                                        undoStepLabel: pendingDraft.undoHistory.length == 1
                                            ? copy.historyUndoStepUnitSingular
                                            : copy.historyUndoStepUnitPlural,
                                      ),
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
                                          label: Text(copy.historyResumeReview),
                                        ),
                                        TextButton.icon(
                                          onPressed: () async {
                                            await SubtitleRevisionService.deleteDraft(identity);
                                            if (!mounted || !dialogContext.mounted) return;
                                            setDialogState(() => draft = null);
                                          },
                                          icon: const AppIcon(Symbols.delete_outline_rounded),
                                          label: Text(copy.historyDeleteDraft),
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
                          final language = revision.languageCode == null
                              ? ''
                              : copy.historyRevisionLanguageSuffix(
                                  language: revision.languageCode!,
                                );
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(revision.operation, style: Theme.of(context).textTheme.titleSmall),
                                Text(
                                  copy.historyRevisionSummary(
                                    date: _formatRevisionDate(revision.createdAt),
                                    cues: revision.cues.length,
                                    cueLabel: revision.cues.length == 1
                                        ? copy.historyCueUnitSingular
                                        : copy.historyCueUnitPlural,
                                    language: language,
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (revision.wordTimings.isNotEmpty)
                                  Text(
                                    copy.historyTimingSpanSummary(
                                      count: revision.wordTimings.length,
                                      spanLabel: revision.wordTimings.length == 1
                                          ? copy.historyTimingSpanUnitSingular
                                          : copy.historyTimingSpanUnitPlural,
                                    ),
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
                                            ? copy.historyRestoreCheckpoint
                                            : copy.historyAttachRevision,
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        unawaited(_run(() => _exportSubtitleRevision(revision)));
                                      },
                                      icon: const AppIcon(Symbols.save_alt_rounded),
                                      label: Text(copy.historyExportSrt),
                                    ),
                                    TextButton.icon(
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        unawaited(_run(() => _exportSubtitleRevisionJson(revision)));
                                      },
                                      icon: const AppIcon(Symbols.data_object_rounded),
                                      label: Text(copy.historyExportJson),
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
                                      label: Text(t.common.delete),
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
                      if (!historyCurrent() || !await _confirmSubtitleHistoryImport() ||
                          !historyCurrent() || !dialogContext.mounted) return;
                      final imported = await _importSubtitleRevisionJson(identity, isHistoryCurrent: historyCurrent);
                      if (imported != null && mounted && dialogContext.mounted) {
                        final refreshed = await SubtitleRevisionService.loadRevisions(identity);
                        if (!mounted || !dialogContext.mounted) return;
                        setDialogState(() => revisions = refreshed);
                        setState(
                          () => _revisionStatus = imported.length == 1
                              ? copy.historyImportOneSuccess
                              : copy.historyImportManySuccess(count: imported.length),
                        );
                      }
                    } catch (error) {
                      if (mounted) setState(() => _error = _readableError(error));
                    }
                  },
                  icon: const AppIcon(Symbols.file_upload),
                  label: Text(copy.historyImportJson),
                ),
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.close)),
              ],
            );
          },
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _revisionStatus = copy.historyOpenFailed(error: error));
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
      throw StateError(t.videoControls.subtitleAiControls.glossaryProfileRequired);
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
            ? t.videoControls.subtitleAiControls.glossarySavedSeries
            : t.videoControls.subtitleAiControls.glossarySavedProfile,
      );
    }
  }

  Future<void> _showGlossaryHistory() async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      if (mounted) setState(() => _status = t.videoControls.subtitleAiControls.glossaryHistoryProfileRequired);
      return;
    }
    final revisions = SubtitleTranslationService.loadGlossaryHistoryForProfile(
      profileId: profileId,
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      seriesId: _useSeriesGlossary ? widget.seriesKey : null,
    );
    if (revisions.isEmpty) {
      if (mounted) setState(() => _status = t.videoControls.subtitleAiControls.glossaryNoPreviousVersions);
      return;
    }
    final selected = await showDialog<SubtitleGlossaryRevision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.videoControls.subtitleAiControls.glossaryHistoryTitle),
        content: SizedBox(
          width: 520,
          height: 360,
          child: ListView.builder(
            itemCount: revisions.length,
            itemBuilder: (context, index) {
              final revision = revisions[index];
              return ListTile(
                title: Text(_formatRevisionDate(revision.createdAt)),
                subtitle: Text(
                  _useSeriesGlossary
                      ? t.videoControls.subtitleAiControls.glossaryHistorySeriesSummary(
                          count: revision.glossary.length,
                          termLabel: revision.glossary.length == 1
                              ? t.videoControls.subtitleAiControls.glossaryTermUnitSingular
                              : t.videoControls.subtitleAiControls.glossaryTermUnitPlural,
                        )
                      : t.videoControls.subtitleAiControls.glossaryHistoryProfileSummary(
                          count: revision.glossary.length,
                          termLabel: revision.glossary.length == 1
                              ? t.videoControls.subtitleAiControls.glossaryTermUnitSingular
                              : t.videoControls.subtitleAiControls.glossaryTermUnitPlural,
                        ),
                ),
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
      _status = t.videoControls.subtitleAiControls.glossaryLoadedFrom(
          date: _formatRevisionDate(selected.createdAt),
        );
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
    final copy = Translations.of(dialogContext).videoControls.subtitleReviewFlow;
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
            title: Text(copy.editCueTitle),
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
                      decoration: InputDecoration(labelText: copy.cueText, border: const OutlineInputBorder()),
                    ),
                    TextButton(onPressed: () => tagSubtitleSelection(editorContext, textController),
                      child: Text(Translations.of(editorContext).videoControls.subtitleLanguageAnnotateAction)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: copy.startMs, border: const OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: endController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: copy.endMs, border: const OutlineInputBorder()),
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
              TextButton(onPressed: () => Navigator.of(editorContext).pop(false), child: Text(Translations.of(editorContext).common.cancel)),
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
                      validationError = copy.invalidCue;
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
                child: Text(copy.saveCue),
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
    final copy = Translations.of(dialogContext).videoControls.subtitleReviewFlow;
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
              title: Text(copy.editAllCues(count: cues.length)),
              content: SizedBox(
                width: 720,
                height: (MediaQuery.sizeOf(editorContext).height - 220).clamp(280.0, 560.0).toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(copy.editAllDescription),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchController,
                      maxLength: 128,
                      decoration: InputDecoration(
                        labelText: copy.findCues,
                        prefixIcon: const AppIcon(Symbols.search_rounded),
                        border: const OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (value) => setEditorState(() => query = value),
                    ),
                    const SizedBox(height: 4),
                    Text(copy.showingCues(visible: visibleIndexes.length, total: cues.length)),
                    const SizedBox(height: 6),
                    Expanded(
                      child: visibleIndexes.isEmpty
                          ? Center(child: Text(copy.noMatchingCues))
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
                                    copy.cueSummary(index: cue.index, start: _formatCueTime(cue.startMs), end: _formatCueTime(cue.endMs)),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (original != null) ...[
                                        Text(copy.original, style: Theme.of(context).textTheme.labelSmall),
                                        SelectableText(original),
                                        const SizedBox(height: 4),
                                      ],
                                      Text(copy.output, style: Theme.of(context).textTheme.labelSmall),
                                      SelectableText(cue.text),
                                    ],
                                  ),
                                  trailing: IconButton(
                                    tooltip: copy.editCueTooltip,
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
                    label: Text(copy.undo(count: undoHistory.length)),
                  ),
                TextButton(onPressed: () => Navigator.of(editorContext).pop(), child: Text(Translations.of(editorContext).common.done)),
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
    final copy = _t.videoControls.subtitleReviewFlow;
    final serverId = widget.serverId;
    final ratingKey = widget.ratingKey;
    if (serverId == null || serverId.isEmpty || ratingKey == null || ratingKey.isEmpty) {
      throw StateError(copy.notServerItem);
    }
    final client = context.tryGetMediaClientForServer(ServerId(serverId));
    if (client == null) throw StateError(copy.serverOffline);
    final uploaded = await client.attachSubtitle(
      ratingKey,
      bytes: bytes,
      fileName: 'PlezyNG.$originToken.$languageCode.srt',
      format: 'srt',
      language: languageCode,
      mediaIndex: widget.mediaIndex,
    );
    if (!uploaded) {
      throw UnsupportedError(copy.serverRefusedUpload);
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
    if (!mounted) return false;
    final copy = _t.videoControls.subtitleReviewFlow;
    if (cues.isEmpty || cues.length > SubtitleRetimer.maximumCueCount) {
      throw FormatException(copy.resultCueLimit);
    }
    if (sourceCues != null && sourceCues.length != cues.length) {
      throw StateError(copy.cueCountsMismatch);
    }
    var reviewedCues = List<SubtitleCue>.from(cues);
    Future<void> rememberAcceptedReview() async {
      if (onAcceptedReview == null) return;
      try { await onAcceptedReview(List<SubtitleCue>.unmodifiable(reviewedCues)); }
      catch (_) {
        if (mounted) setState(() => _revisionStatus = copy.memoryUpdateFailed);
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
        throw StateError(copy.reviewDraftMismatch);
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
            setState(() => _revisionStatus = copy.savedDraftAvailable);
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
            setState(() => _revisionStatus = copy.earlierDraftKept);
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
        if (mounted) setState(() => _revisionStatus = copy.reviewDraftSaved);
      } catch (error) {
        if (mounted) setState(() => _revisionStatus = copy.reviewDraftSaveFailed(error: error));
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
        !widget.appOverlayOnly && !onItemTimeline && uploadLanguage != null && widget.serverId?.isNotEmpty == true && widget.ratingKey?.isNotEmpty == true;
    final canSaveToSource = !widget.appOverlayOnly && widget.onSaveToSource != null;
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
          title: Text(copy.reviewTitle(operation: operationLabel)),
          content: SizedBox(
            width: 560,
            height: (MediaQuery.sizeOf(dialogContext).height - 220).clamp(240.0, 420.0).toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(copy.readyCues(count: cues.length)),
                if (onItemTimeline) Text(copy.itemTimelineNote),
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
                          copy.translationWarnings(count: reviewWarnings.length),
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
                          Text(copy.warningMore(count: reviewWarnings.length - 3), style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                Text(
                  draftIdentity == null
                      ? copy.sessionEditHelp
                      : copy.persistentEditHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  reviewedWordTimings.isEmpty
                      ? copy.noTokenTimings
                      : copy.wordTimingHelp(count: reviewedWordTimings.length),
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
                  label: Text(copy.editAllCuesButton),
                ),
                if (widget.selectedSubtitleBurnedIn)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      copy.burnedInWarning,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (canUploadToServer)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      copy.serverUploadInfo,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else if (canSaveToSource)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      copy.sourceSaveInfo,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      uploadLanguage == null
                          ? copy.serverUnavailableLanguage
                          : copy.serverUnavailableItem,
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
                              copy.cueTime(start: _formatCueTime(cue.startMs), end: _formatCueTime(cue.endMs)),
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const SizedBox(height: 2),
                            if (sourceCues != null && cueIndex < sourceCues.length) ...[
                              Text(copy.original, style: Theme.of(context).textTheme.labelSmall),
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
                                label: Text(copy.editSampleCue),
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
                label: Text(copy.undo(count: undoHistory.length)),
              ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.exportSrt),
              icon: const AppIcon(Symbols.save_alt_rounded),
              label: Text(copy.saveSrt),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.exportJson),
              icon: const AppIcon(Symbols.data_object_rounded),
              label: Text(copy.saveJson),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.discard),
              child: Text(copy.discard),
            ),
            if (canUploadToServer)
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.serverAndPlayer),
                child: Text(copy.uploadAndAttach),
              ),
            if (canSaveToSource)
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.sourceAndPlayer),
                child: Text(copy.saveToSourceAndAttach),
              ),
            for (final lane in [_SubtitleReviewChoice.overlayPrimary, _SubtitleReviewChoice.overlaySecondary])
              OutlinedButton(onPressed: () => Navigator.of(dialogContext).pop(lane),
                child: Text(lane == _SubtitleReviewChoice.overlayPrimary ? copy.appOverlayOne : copy.appOverlayTwo)),
            if (!widget.appOverlayOnly) FilledButton(
              onPressed: widget.player.supportedLocalSubtitleExtensions.contains('srt')
                  ? () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.player) : null,
              child: Text(copy.attachToPlayer),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null || choice == _SubtitleReviewChoice.discard) {
      if (mounted) {
        setState(() => _status = copy.resultDiscarded);
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
          (original.startMs != cue.startMs || original.endMs != cue.endMs ||
            !SubtitleLanguageText.sameWordsWithLanguageEdits(original.text, cue.text))) {
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
        dialogTitle: copy.saveSrtTitle,
        fileName: 'PlezyNG_${originToken}_${DateTime.now().microsecondsSinceEpoch}.srt',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['srt'],
      );
      if (!mounted) return false;
      if (exportPath == null) {
        setState(() => _status = copy.srtExportCancelled);
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
      if (mounted) setState(() => _status = copy.srtExported);
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
        dialogTitle: copy.saveJsonTitle,
        fileName: 'PlezyNG_${originToken}_${DateTime.now().microsecondsSinceEpoch}.json',
        bytes: jsonBytes,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (!mounted) return false;
      if (exportPath == null) {
        setState(() => _status = copy.jsonExportCancelled);
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
      if (mounted) setState(() => _status = copy.jsonExported);
      return false;
    }
    final nativeBytes = choice == _SubtitleReviewChoice.overlayPrimary || choice == _SubtitleReviewChoice.overlaySecondary
        ? bytes : await _bytesForNativeTimeline(reviewedCues, onItemTimeline);
    if (choice == _SubtitleReviewChoice.serverAndPlayer) {
      final languageCode = uploadLanguage;
      if (languageCode == null) throw StateError(copy.serverLanguageUnknown);
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
        if (saveToSource == null) throw StateError(copy.noStandaloneSidecar);
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
        throw StateError(copy.uploadedButLocalAttachFailed(error: error));
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
    final copy = Translations.of(context).videoControls.subtitleJobs;
    if (error is UnsupportedError || error is FormatException || error is ArgumentError || error is StateError) {
      final message = error.toString().replaceFirst(
        RegExp(r'^(Unsupported operation|FormatException|Invalid argument|Bad state):\s*'),
        '',
      );
      return switch (message) {
        'Open a stable library item or local file to create a resumable job.' => copy.stableIdentityRequired,
        'Delete an old job before adding another (12-job limit).' => copy.jobLimit,
        'The source or profile changed, or another job is being created.' => copy.sourceChanged,
        'Reopen the same file, audio stream and clock before resuming this job.' => copy.resumeBindingMismatch,
        'This job uses its retained WAV.' => copy.wavJobNoSource,
        'Choose a complete VOD file up to eight hours and an explicit audio stream.' => copy.completeVodRequired,
        'A source job requires a local file or its owned loopback transport.' => copy.supportedTransportRequired,
        'The job was saved under its original profile; switch back to resume it.' => copy.originalProfileResume,
        _ => message,
      };
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
    final aiCopy = Translations.of(context).videoControls.subtitleAiControls;
    final supportsOverride =
        _provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu;
    final languages = _whisperLanguagesByCode();
    final selected = languages.containsKey(_speechLanguageCode) ? _speechLanguageCode : 'auto';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(labelText: aiCopy.speechLanguage, border: OutlineInputBorder()),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(aiCopy.autoDetect)),
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
              aiCopy.englishOnlyAccelerator,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final jobsCopy = Translations.of(context).videoControls.subtitleJobs;
    final aiCopy = Translations.of(context).videoControls.subtitleAiControls;
    final liveCopy = Translations.of(context).videoControls.subtitleLiveCapture;
    final resourceCopy = Translations.of(context).videoControls.subtitleResources;
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
      title: aiCopy.title,
      icon: Symbols.auto_awesome_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          Text(
            aiCopy.intro,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: InputDecoration(labelText: aiCopy.inferenceBackend, border: OutlineInputBorder()),
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
                ? aiCopy.desktopGpuAvailability
                : aiCopy.cpuProviderNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _speechLanguageSelector(),
          const SizedBox(height: 10),
          if (_busy) const LinearProgressIndicator(),
          if (_busy && _activeCompanion != null)
            TextButton(onPressed: _cancelCompanionUpload, child: Text(aiCopy.cancelCompanionUpload)),
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
              title: Text(aiCopy.revisionHistoryTitle),
              subtitle: Text(aiCopy.revisionHistoryDescription),
              onTap: _busy ? null : () => unawaited(_showRevisionHistory()),
            ),
          if (_revisionIdentity != null)
            FocusableListTile(leading: const Icon(Icons.cloud_sync), title: Text(aiCopy.syncReviewedTitle),
              subtitle: Text(aiCopy.syncReviewedDescription),
              onTap: _busy ? null : () => unawaited(_run(() async {
                final identity = _operationRevisionIdentity;
                if (identity == null) return;
                await showDialog<void>(context: context, builder: (_) => SubtitleCloudSyncDialog(identity: identity,
                  isCurrent: () => mounted && _operationIdentityIsCurrent && _operationRevisionIdentity?.storageKey == identity.storageKey));
              }))),
          const Divider(height: 24),
          Text(aiCopy.companionProcessing, style: Theme.of(context).textTheme.titleMedium),
          Text(aiCopy.companionProcessingDescription),
          FocusableListTile(leading: const AppIcon(Symbols.settings_rounded), title: Text(aiCopy.pairCompanion),
            onTap: _busy ? null : () => unawaited(_configureCompanion())),
          FocusableListTile(leading: const AppIcon(Symbols.history_rounded), title: Text(aiCopy.companionJobs),
            subtitle: Text(aiCopy.companionJobsDescription),
            onTap: _busy ? null : () => unawaited(_showCompanionJobs())),
          Row(children: [
            _languageSelector(label: aiCopy.companionSourceLanguage, value: _sourceLanguage,
              onChanged: (value) => _changeTranslationLanguage(source: true, value: value)),
            const SizedBox(width: 8),
            _languageSelector(label: aiCopy.companionTargetLanguage, value: _targetLanguage,
              onChanged: (value) => _changeTranslationLanguage(source: false, value: value)),
          ]),
          for (final entry in <(String, String)>[
            ('transcribe', aiCopy.companionTranscribe),
            ('ensemble', aiCopy.companionEnsemble),
            ('separate', aiCopy.companionSeparate),
            ('sound_events', aiCopy.companionSoundEvents),
            ('sound_localize', aiCopy.companionSoundLocalization),
            ('completeness', aiCopy.companionCompleteness),
            ('extract_text', aiCopy.companionExtractText),
            ('signs', aiCopy.companionSigns),
            ('align', aiCopy.companionAlign),
            ('singing_align', aiCopy.companionSingingAlign),
            ('vocal_notes', aiCopy.companionVocalNotes),
            ('diarize', aiCopy.companionDiarize),
            ('translate', aiCopy.companionTranslate),
            ('translate_model', aiCopy.companionTranslateModel),
            ('script_convert', aiCopy.companionScriptConvert),
            ('reading', aiCopy.companionReading),
            ('dubbing', aiCopy.companionDubbing),
            ('dub_mix', aiCopy.companionDubMix),
            ('scene_review', aiCopy.companionSceneReview),
            ('scene_track', aiCopy.companionSceneTrack),
            ('ocr_auto', aiCopy.companionOcrAuto),
            ('ocr', aiCopy.companionOcr),
            ('bitmap_ocr', aiCopy.companionBitmapOcr),
          ]) FocusableListTile(leading: const AppIcon(Symbols.auto_awesome_rounded), title: Text(entry.$2),
            onTap: _busy || _revisionIdentity == null ? null : () => unawaited(_submitCompanion(entry.$1))),
          TextButton(onPressed: () => unawaited(_run(_openOverlayControls)), child: Text(aiCopy.appOverlayAppearance)),
          if (localSpeech && SubtitleReadAheadService.available) AnimatedBuilder(
            animation: SubtitleReadAheadService.instance, builder: (context, _) {
              final service = SubtitleReadAheadService.instance;
              return FocusableListTile(leading: const AppIcon(Symbols.subtitles_rounded),
                title: Text(service.running ? aiCopy.stopPreparingPlaybackTitle : aiCopy.preparePlaybackTitle),
                subtitle: Text(service.status), onTap: _busy || service.busy && !service.running
                    ? null : () => unawaited(_preparePlaybackCaptions()));
            }),
          if (!localSpeech) Padding(padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(aiCopy.localSpeechUnavailable)),
          if (_playbackCaptureSupported) ...[
            const Divider(height: 24),
            Text(liveCopy.sectionTitle, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(liveCopy.description, style: Theme.of(context).textTheme.bodySmall),
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
                      })), child: Text(liveCopy.chooseManifest)),
                      if (_streamingModelManifest != null) ...[
                        Text(liveCopy.streamingModelDescription(model: p.basename(_streamingModelManifest!))),
                        TextButton(onPressed: _busy || service.isStarting || service.hasActiveSession ? null :
                          () => setState(() => _streamingModelManifest = null), child: Text(liveCopy.useWhisper)),
                      ],
                    ],
                    if (_streamingModelManifest == null && liveProviders.length > 1) ...[
                      InputDecorator(
                        decoration: InputDecoration(
                          labelText: liveCopy.backendLabel,
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
                          liveCopy.backendCpu,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (_streamingModelManifest == null) SwitchListTile(title: Text(liveCopy.stabilizePartials),
                      subtitle: Text(liveCopy.stabilizeDescription),
                      value: service.stableStreaming,
                      onChanged: service.isStarting || service.hasActiveSession ? null : service.setStableStreaming),
                    if (service.singlePassTails > 0) Text(liveCopy.singlePassTails(count: service.singlePassTails)),
                    SwitchListTile(
                      title: Text(liveCopy.showLateCaptions),
                      subtitle: Text(liveCopy.showLateCaptionsDescription),
                      value: service.showDelayedText,
                      onChanged: service.setShowDelayedText,
                    ),
                    if (service.droppedAudioMs > 0 || service.discontinuities > 0)
                      Text(liveCopy.droppedAudio(milliseconds: service.droppedAudioMs, discontinuities: service.discontinuities)),
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
                            ? liveCopy.preparing
                            : (service.isRunning || service.hasActiveSession)
                            ? liveCopy.stopCapture
                            : liveCopy.start,
                      ),
                      subtitle: Text(
                        service.isStarting
                            ? liveCopy.loadingModel
                            : (service.isRunning || service.hasActiveSession)
                            ? liveCopy.stopRetainTranscript
                            : _streamingModelManifest == null
                            ? liveCopy.whisperSessionDescription
                            : liveCopy.streamingSessionDescription,
                      ),
                      onTap: (_busy || service.isStarting) ? null : () => unawaited(_captureLivePlayback()),
                    ),
                    if (service.hasRecentTranscript)
                      FocusableListTile(
                        leading: const AppIcon(Symbols.search_rounded),
                        title: Text(liveCopy.browseTranscript),
                        subtitle: Text(liveCopy.browseTranscriptDescription),
                        onTap: () => unawaited(_showCapturedTranscript(service)),
                      ),
                    if (service.hasRecentTranscript &&
                        !service.isRunning &&
                        !service.isStarting &&
                        !service.hasActiveSession &&
                        _revisionIdentity != null)
                      FocusableListTile(
                        leading: const AppIcon(Symbols.save_rounded),
                        title: Text(liveCopy.saveTranscript),
                        subtitle: Text(liveCopy.saveTranscriptDescription),
                        onTap: _busy ? null : () => unawaited(_saveCapturedTranscript(service)),
                      ),
                    if (_revisionIdentity != null) ...[
                      FocusableListTile(
                        leading: const AppIcon(Symbols.sync_rounded),
                        title: Text(liveCopy.syncSaved),
                        subtitle: Text(liveCopy.syncSavedDescription),
                        onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscript(repairCuts: false)),
                      ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.content_cut_rounded),
                        title: Text(liveCopy.repairSaved),
                        subtitle: Text(liveCopy.repairSavedDescription),
                        onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscript(repairCuts: true)),
                      ),
                      if (_translationSupported) ...[
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: Text(liveCopy.translateSaved),
                          subtitle: Text(liveCopy.translateSavedDescription),
                          onTap: _busy ? null : () => unawaited(_translateSavedTranscript()),
                        ),
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: Text(liveCopy.syncSavedLanguages),
                          subtitle: Text(liveCopy.syncSavedLanguagesDescription),
                          onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscriptAcrossLanguages(repairCuts: false)),
                        ),
                        FocusableListTile(
                          leading: const AppIcon(Symbols.content_cut_rounded),
                          title: Text(liveCopy.repairSavedLanguages),
                          subtitle: Text(liveCopy.repairCapturedLanguagesDescription),
                          onTap: _busy ? null : () => unawaited(_synchronizeSavedTranscriptAcrossLanguages(repairCuts: true)),
                        ),
                      ],
                    ],
                    if (service.hasRecentTranscript && !service.isRunning) ...[
                      if (_translationSupported)
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: Text(liveCopy.translateCaptured),
                          subtitle: Text(liveCopy.translateCapturedDescription),
                          onTap: _busy ? null : () => unawaited(_translateCapturedTranscript()),
                        ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.sync_rounded),
                        title: Text(liveCopy.syncCaptured),
                        subtitle: Text(liveCopy.syncCapturedDescription),
                        onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlayback(repairCuts: false)),
                      ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.content_cut_rounded),
                        title: Text(liveCopy.repairCaptured),
                        subtitle: Text(liveCopy.repairCapturedDescription),
                        onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlayback(repairCuts: true)),
                      ),
                      if (_translationSupported) ...[
                        FocusableListTile(
                          leading: const AppIcon(Symbols.translate_rounded),
                          title: Text(liveCopy.syncCapturedLanguages),
                          subtitle: Text(liveCopy.syncCapturedLanguagesDescription),
                          onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlaybackAcrossLanguages(repairCuts: false)),
                        ),
                        FocusableListTile(
                          leading: const AppIcon(Symbols.content_cut_rounded),
                          title: Text(liveCopy.repairCapturedLanguages),
                          subtitle: Text(liveCopy.repairSavedLanguagesDescription),
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
              title: Text(aiCopy.translateDetectedSpeech),
              subtitle: Text(aiCopy.translationGenerationOnly),
              value: _translateSpeechToEnglish,
              onChanged: _busy ? null : (value) => setState(() => _translateSpeechToEnglish = value),
            ),
          FocusableListTile(
            leading: const AppIcon(Symbols.graphic_eq_rounded),
            title: Text(
              _translateSpeechToEnglish ? aiCopy.translateSpeechFromWav : aiCopy.generateSubtitlesFromWav,
            ),
            subtitle: Text(
              _provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu
                  ? aiCopy.downloadMultilingualModel
                  : aiCopy.downloadEnglishModel,
            ),
            onTap: _busy || !localSpeech ? null : () => unawaited(_transcribe()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.queue_music_rounded),
            title: Text(jobsCopy.queueWavTitle),
            subtitle: Text(jobsCopy.queueWavDescription),
            onTap: _busy || !localSpeech || _revisionIdentity == null ? null : () => unawaited(_queueTranscription()),
          ),
          if (SubtitleReadAheadService.available) FocusableListTile(
            leading: const AppIcon(Symbols.queue_music_rounded),
            title: Text(jobsCopy.queueSourceTitle),
            subtitle: Text(jobsCopy.queueSourceDescription),
            onTap: _busy || !localSpeech || _revisionIdentity == null ? null
                : () => unawaited(_queueTranscription(useSource: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.settings_rounded),
            title: Text(resourceCopy.title),
            subtitle: Text(resourceCopy.entryDescription),
            onTap: () => unawaited(showDialog<void>(context: context, builder: (_) => const SubtitleResourceDialog())),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.history_rounded),
            title: Text(jobsCopy.title),
            subtitle: Text(jobsCopy.openJobsHelp),
            onTap: _busy ? null : () => unawaited(_manageTranscriptionJobs()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.queue_music_rounded),
            title: Text(aiCopy.replaceIntervalTitle),
            subtitle: Text(aiCopy.replaceIntervalDescription),
            onTap: _busy || !localSpeech ? null : () => unawaited(_generateInterval(fillSpeechGaps: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.add_comment_rounded),
            title: Text(aiCopy.fillGapsTitle),
            subtitle: Text(aiCopy.fillGapsDescription),
            onTap: _busy || !localSpeech ? null : () => unawaited(_generateInterval(fillSpeechGaps: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.sync_rounded),
            title: Text(aiCopy.syncExistingTitle),
            subtitle: Text(aiCopy.syncExistingDescription),
            onTap: _busy || !localSpeech ? null : () => unawaited(_synchronize(repairCuts: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.edit_rounded),
            title: Text(aiCopy.reflowTitle),
            subtitle: Text(aiCopy.reflowDescription),
            onTap: _busy ? null : () => unawaited(_transformSubtitles()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.spellcheck_rounded),
            title: Text(aiCopy.spellingReviewTitle),
            subtitle: Text(aiCopy.spellingReviewDescription),
            onTap: _busy ? null : () => unawaited(_reviewDictionarySpelling()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.subtitles_rounded),
            title: Text(aiCopy.encodingTitle),
            subtitle: Text(aiCopy.encodingDescription),
            onTap: _busy ? null : () => unawaited(_importTextSubtitle()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.folder_open_rounded),
            title: Text(aiCopy.discoverSubtitlesTitle),
            subtitle: Text(aiCopy.discoverSubtitlesDescription),
            onTap: _busy ? null : () => unawaited(_discoverSubtitles()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.replay_rounded),
            title: Text(aiCopy.studySubtitleTitle),
            subtitle: Text(aiCopy.studySubtitleDescription),
            onTap: _busy ? null : () => unawaited(_studySubtitle()),
          ),
          if (_revisionIdentity != null) FocusableListTile(
            leading: const AppIcon(Symbols.history_rounded),
            title: Text(aiCopy.studySavedTranscriptTitle),
            subtitle: Text(aiCopy.studySavedTranscriptDescription),
            onTap: _busy ? null : () => unawaited(_studySubtitle(saved: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.graphic_eq_rounded),
            title: Text(aiCopy.waveformEditorTitle),
            subtitle: Text(aiCopy.waveformEditorDescription),
            onTap: _busy ? null : () => unawaited(_editWaveform()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: Text(aiCopy.repairCutsTitle),
            subtitle: Text(aiCopy.repairCutsDescription),
            onTap: _busy || !localSpeech ? null : () => unawaited(_synchronize(repairCuts: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.closed_caption_rounded),
            title: Text(aiCopy.syncReferenceTitle),
            subtitle: Text(aiCopy.syncReferenceDescription),
            onTap: _busy ? null : () => unawaited(_synchronizeToReference(repairCuts: false)),
          ),
          if (_translationSupported)
            FocusableListTile(
              leading: const AppIcon(Symbols.translate_rounded),
              title: Text(aiCopy.syncLanguagesTitle),
              subtitle: Text(aiCopy.syncLanguagesDescription),
              onTap: _busy ? null : () => unawaited(_synchronizeAcrossLanguages(repairCuts: false)),
            ),
          if (_translationSupported)
            FocusableListTile(
              leading: const AppIcon(Symbols.content_cut_rounded),
              title: Text(aiCopy.repairLanguagesTitle),
              subtitle: Text(aiCopy.repairLanguagesDescription),
              onTap: _busy ? null : () => unawaited(_synchronizeAcrossLanguages(repairCuts: true)),
            ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: Text(aiCopy.repairReferenceTitle),
            subtitle: Text(aiCopy.repairReferenceDescription),
            onTap: _busy ? null : () => unawaited(_synchronizeToReference(repairCuts: true)),
          ),
          if (_translationSupported) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(aiCopy.reuseTranslationMemory),
              subtitle: Text(aiCopy.translationMemoryDescription),
              value: _useTranslationMemory,
              onChanged: _busy ? null : (value) => setState(() => _useTranslationMemory = value),
            ),
            TextButton(onPressed: _busy ? null : () => _run(() async {
              final profile = _activeProfileId;
              if (profile == null) return;
              await SubtitleTranslationMemory.clear(profile);
              if (mounted) setState(() => _status = aiCopy.translationMemoryCleared);
            }), child: Text(aiCopy.clearTranslationMemory)),
            const Divider(height: 24),
            Text(aiCopy.localSubtitleTranslation, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              SubtitleTranslationService.desktopPlatformSupported
                  ? aiCopy.desktopArgosDescription
                  : aiCopy.mobileMlKitDescription,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _languageSelector(
                  label: aiCopy.sourceLanguage,
                  value: _sourceLanguage,
                  onChanged: (value) => _changeTranslationLanguage(source: true, value: value),
                ),
                const SizedBox(width: 8),
                _languageSelector(
                  label: aiCopy.targetLanguage,
                  value: _targetLanguage,
                  onChanged: (value) => _changeTranslationLanguage(source: false, value: value),
                ),
              ],
            ),
            if (widget.seriesKey?.isNotEmpty == true)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(aiCopy.seriesGlossary),
                subtitle: Text(aiCopy.seriesGlossaryDescription),
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
              title: Text(aiCopy.bilingualOutput),
              subtitle: Text(aiCopy.bilingualOutputDescription),
              value: _bilingualTranslation,
              onChanged: _busy ? null : (value) => setState(() => _bilingualTranslation = value),
            ),
            TextField(
              controller: _glossaryController,
              minLines: 2,
              maxLines: 4,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: aiCopy.glossaryLabel,
                hintText: aiCopy.glossaryHint,
                helperText: widget.seriesKey == null
                    ? aiCopy.glossaryProfileHelper
                    : aiCopy.glossarySeriesHelper,
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
                    label: Text(aiCopy.history),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => unawaited(_run(_saveGlossary)),
                    icon: const AppIcon(Symbols.save_rounded),
                    label: Text(aiCopy.saveGlossary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (SubtitleTranslationService.mobilePlatformSupported) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(aiCopy.allowMobileDownloads),
                value: _allowMobileData,
                onChanged: _busy ? null : (value) => setState(() => _allowMobileData = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_prepareTranslationModels()),
                  icon: const AppIcon(Symbols.download_for_offline_rounded),
                  label: Text(aiCopy.prepareOfflineModels),
                ),
              ),
            ],
            if (SubtitleTranslationService.desktopPlatformSupported && (Platform.isWindows || Platform.isLinux))
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(aiCopy.requestArgosCuda),
                subtitle: const Text(
                  aiCopy.requestArgosCudaDescription,
                ),
                value: _requestTranslationCuda,
                onChanged: _busy ? null : (value) => setState(() => _requestTranslationCuda = value),
              ),
            Text(
              SubtitleTranslationService.desktopPlatformSupported
                  ? aiCopy.desktopTranslationLocalNote
                  : aiCopy.mobileTranslationLocalNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            FocusableListTile(
              leading: const AppIcon(Symbols.translate_rounded),
              title: Text(aiCopy.translateExistingTitle),
              subtitle: Text(aiCopy.translateExistingDescription),
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
    final copy = Translations.of(context).videoControls.subtitleLiveCapture;
    try {
      await widget.player.seek(Duration(milliseconds: cue.startMs));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(copy.seekFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = Translations.of(context).videoControls.subtitleLiveCapture;
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
              title: Text(copy.dialogTitle),
              content: SizedBox(
                width: 620,
                height: height,
                child: Column(
                  children: [
                    Text(
                      copy.watchedPortionOnly,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const AppIcon(Symbols.search_rounded),
                        labelText: copy.searchTranscript,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: copy.clearSearch,
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
                      title: Text(copy.hideFuture),
                      subtitle: Text(copy.hideFutureDescription),
                      value: _hideFutureDialogue,
                      onChanged: (value) => setState(() => _hideFutureDialogue = value),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${copy.cueCountSummary(visible: filtered.length, total: cues.length)}${canSeek ? '' : ' · ${copy.seekingUnavailable}'}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                cues.isEmpty
                                    ? copy.noSpeechCues
                                    : copy.noMatchingCues,
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
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(copy.close))],
            );
          },
        );
      },
    );
  }
}
