import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../i18n/strings.g.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../../../mpv/mpv.dart';
import '../../../media/ids.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../mpv/player/subtitle_pcm_capture_source.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_ai_service.dart';
import '../../../services/subtitle_placement_evidence.dart';
import '../../../services/subtitle_retimer.dart';
import '../../../services/subtitle_word_timing.dart';
import '../../../services/subtitle_sync_service.dart';
import '../../../services/subtitle_translation_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_playback_transcription_service.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../utils/provider_extensions.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import 'base_video_control_sheet.dart';

/// Reviewable local subtitle operations. The source file is never modified;
/// every generated, translated, or synchronized result is written to a new
/// SRT that viewers may export or attach as a separate external track.
enum _SubtitleReviewChoice { discard, exportSrt, exportJson, player, serverAndPlayer }

const _subtitleUndoCheckpointPrefix = 'Undo checkpoint: ';

class SubtitleAiSheet extends StatefulWidget {
  const SubtitleAiSheet({
    super.key,
    required this.player,
    this.serverId,
    this.ratingKey,
    this.mediaIndex = 0,
    this.revisionIdentity,
    this.seriesKey,
    this.selectedSubtitleBurnedIn = false,
  });

  final Player player;
  final String? serverId;
  final String? ratingKey;
  final int mediaIndex;

  /// Optional device-local identity for standalone source media. Server
  /// attachment still requires [serverId] and [ratingKey].
  final SubtitleRevisionIdentity? revisionIdentity;
  final String? seriesKey;
  final bool selectedSubtitleBurnedIn;

  @override
  State<SubtitleAiSheet> createState() => _SubtitleAiSheetState();
}

class _SubtitleAiSheetState extends State<SubtitleAiSheet> {
  bool _busy = false;
  bool _translateSpeechToEnglish = false;
  bool _translationSupported = false;
  bool _allowMobileData = false;
  bool _requestTranslationCuda = false;
  bool _bilingualTranslation = false;
  bool _useSeriesGlossary = false;
  final TextEditingController _glossaryController = TextEditingController();
  final Map<String, String> _glossaryDrafts = <String, String>{};
  bool _playbackCaptureSupported = false;
  bool _lastResultUploadedToServer = false;
  String? _status;
  String? _error;
  String? _revisionStatus;
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  String _speechLanguageCode = 'auto';
  TranslateLanguage _sourceLanguage = TranslateLanguage.english;
  TranslateLanguage _targetLanguage = TranslateLanguage.spanish;

  @override
  void dispose() {
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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ensureSpeechModel() async {
    if (_provider == SubtitleInferenceProvider.cpu || _provider == SubtitleInferenceProvider.desktopGpu) return;
    if (await SubtitleAiService.instance.isModelInstalled()) return;
    if (mounted) setState(() => _status = context.t.subtitleAiUi.downloadingTheEnglishSpeechModelAndS_d75c5cb7);
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
    return path;
  }

  Future<(List<SubtitleCue>, String)?> _pickSubtitleCues() async {
    final result = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ass', 'srt', 'ssa', 'vtt'],
      withData: true,
    );
    if (!mounted || result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final extension = p.extension(file.name).toLowerCase();
    if (!const {'.ass', '.srt', '.ssa', '.vtt'}.contains(extension)) {
      throw const FormatException('Choose an SRT, VTT, ASS, or SSA text subtitle.');
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
    return (SubtitleRetimer.parseCues(sourceBytes: bytes, extension: extension), file.name);
  }

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
      _status = context.t.subtitleAiUi.generatedCueCountAndDuration(
        cueCount: result.cues.length,
        durationMinutes: (result.durationMs / 60000).ceil(),
        speechStatus: result.translatedToEnglish
            ? context.t.subtitleAiUi.speechTranslatedToEnglish
            : context.t.subtitleAiUi.detectedSpeechLanguage(language: result.detectedLanguage),
        providerLabel: providerLabel,
        placementEvidence: result.placementEvidence.displayLabel,
        uploadedNote: _lastResultUploadedToServer ? context.t.subtitleAiUi.uploadedToServerLibraryNote : '',
      );
    });
    await _showApplied();
  });

  Future<void> _synchronize({required bool repairCuts}) => _run(() async {
    final wavPath = await _pickWav();
    if (wavPath == null || !mounted) return;
    final selected = await _pickSubtitleCues();
    if (selected == null || !mounted) return;
    await _ensureSpeechModel();
    setState(() => _status = context.t.subtitleAiUi.transcribingAudioAndAligningSubtitleText);
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
      operationLabel: repairCuts ? 'Cut repair' : 'Automatic sync',
      operationLanguageCode: transcription.detectedLanguage,
      wordTimings: transcription.wordTimings,
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status = context.t.subtitleAiUi.synchronizationOperationApplied(
        operation: repairCuts ? context.t.subtitleAiUi.cutRepair : context.t.subtitleAiUi.automaticSync,
        matchedCueCount: aligned.matchedCueCount,
        totalCueCount: aligned.totalCueCount,
        confidence: percent,
        discontinuityCount: aligned.discontinuityCount,
        rate: aligned.appliedRate.toStringAsFixed(4),
        baseOffset: aligned.globalOffsetMs,
        source: selected.$2,
        uploadedNote: _lastResultUploadedToServer ? context.t.subtitleAiUi.uploadedToServerLibraryNote : '',
      );
    });
    await _showApplied();
  });

  Future<void> _showCapturedTranscript(SubtitlePlaybackTranscriptionService service) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _CapturedTranscriptDialog(player: widget.player, service: service),
    );
  }

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
    await service.start(
      captureSource,
      languageCode: _speechLanguageCode == 'auto' ? null : _speechLanguageCode,
      onProgress: (phase, received, total) {
        if (!mounted) return;
        final percent = total == 0 ? '' : ' (${(received * 100 / total).round()}%)';
        setState(() => _status = phase + percent);
      },
    );
    if (!mounted) return;
    setState(() => _status = service.status);
  });

  Future<(TranslateLanguage, TranslateLanguage)?> _chooseCrossLanguagePair() async {
    var source = _sourceLanguage;
    var reference = _targetLanguage;
    return showDialog<(TranslateLanguage, TranslateLanguage)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(context.t.subtitleAiUi.subtitleLanguagesForMatching),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<TranslateLanguage>(
                initialValue: source,
                decoration: InputDecoration(
                  labelText: context.t.subtitleAiUi.subtitleToSynchronize,
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
                  labelText: context.t.subtitleAiUi.referenceSubtitle,
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
                onChanged: (value) => setDialogState(() => reference = value ?? reference),
              ),
              if (source == reference)
                Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(context.t.subtitleAiUi.chooseDifferentLanguagesToUseTransla_db4d6e3a),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(context.t.common.cancel)),
            FilledButton(
              onPressed: source == reference ? null : () => Navigator.of(dialogContext).pop((source, reference)),
              child: Text(context.t.subtitleAiUi.continueButton),
            ),
          ],
        ),
      ),
    );
  }

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
    setState(() => _status = context.t.subtitleAiUi.chooseTheSubtitleThatNeedsSynchronization);
    final target = await _pickSubtitleCues();
    if (target == null || !mounted) return;
    setState(() => _status = context.t.subtitleAiUi.chooseASynchronizedSubtitleInAnotherLanguage);
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

    setState(() => _status = context.t.subtitleAiUi.translatingTargetCuesLocallyForTextMatching);
    final translated = await SubtitleTranslationService.translateCues(
      cues: target.$1,
      sourceLanguage: sourceLanguage,
      targetLanguage: referenceLanguage,
      allowMobileData: _allowMobileData,
      requestDesktopCuda: _requestTranslationCuda,
      glossary: _glossaryForPair(sourceLanguage, referenceLanguage),
      onProgress: (completed, total) {
        if (!mounted) return;
        setState(
          () => _status = context.t.subtitleAiUi.translatingCuesForAlignment(completed: completed, total: total),
        );
      },
    );
    if (!mounted) return;
    if (translated.cues.length != target.$1.length) {
      throw StateError('Translation changed the cue count; no synchronization was applied.');
    }

    setState(() => _status = context.t.subtitleAiUi.aligningTranslatedTargetTextAgainstTheReference);
    final aligned = SubtitleSyncService.synchronizeAgainstReference(
      subtitleCues: translated.cues,
      referenceCues: reference.$1,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
    );
    if (aligned.cues.length != target.$1.length) {
      throw StateError('Cross-language alignment changed the target cue count.');
    }
    final retimedOriginal = List<SubtitleCue>.generate(
      target.$1.length,
      (index) => SubtitleCue(
        index: target.$1[index].index,
        startMs: aligned.cues[index].startMs,
        endMs: aligned.cues[index].endMs,
        text: target.$1[index].text,
      ),
      growable: false,
    );
    if (!await _writeAndApply(
      retimedOriginal,
      operationLabel: repairCuts ? 'Cross-language reference cut repair' : 'Cross-language subtitle sync',
      operationLanguageCode: sourceLanguage.bcpCode,
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    final warningCount = translated.qualityWarnings.length;
    setState(() {
      _status = context.t.subtitleAiUi.crossLanguageOperationApplied(
        operation: repairCuts ? context.t.subtitleAiUi.cutRepairLowercase : context.t.subtitleAiUi.syncLowercase,
        matchedCueCount: aligned.matchedCueCount,
        totalCueCount: aligned.totalCueCount,
        confidence: percent,
        sourceLanguage: SubtitleTranslationService.languageLabel(sourceLanguage),
        referenceLanguage: SubtitleTranslationService.languageLabel(referenceLanguage),
        warningNote: warningCount == 0 ? '' : context.t.subtitleAiUi.translationQualityWarnings(count: warningCount),
        uploadedNote: _lastResultUploadedToServer ? context.t.subtitleAiUi.uploadedToServerLibraryNote : '',
      );
    });
    await _showApplied();
  });

  Future<void> _synchronizeToReference({required bool repairCuts}) => _run(() async {
    setState(() => _status = context.t.subtitleAiUi.chooseTheSubtitleThatNeedsSynchronization);
    final target = await _pickSubtitleCues();
    if (target == null || !mounted) return;
    setState(() => _status = context.t.subtitleAiUi.chooseAnAlreadySynchronizedSubtitleI_83e183b5);
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
    setState(() => _status = context.t.subtitleAiUi.matchingBothSubtitlesAndAligningTiming);
    final aligned = SubtitleSyncService.synchronizeAgainstReference(
      subtitleCues: target.$1,
      referenceCues: reference.$1,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      operationLabel: repairCuts ? 'Reference cut repair' : 'Subtitle-reference sync',
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status = context.t.subtitleAiUi.referenceOperationApplied(
        operation: repairCuts ? context.t.subtitleAiUi.cutRepair : context.t.subtitleAiUi.subtitleReferenceSync,
        matchedCueCount: aligned.matchedCueCount,
        totalCueCount: aligned.totalCueCount,
        confidence: percent,
        discontinuityCount: aligned.discontinuityCount,
        referenceSource: reference.$2,
        originalSource: target.$2,
        uploadedNote: _lastResultUploadedToServer ? context.t.subtitleAiUi.uploadedToServerLibraryNote : '',
      );
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
    setState(() => _status = context.t.subtitleAiUi.matchingTheCapturedSpeechAgainstSubtitleText);
    final aligned = SubtitleSyncService.synchronize(
      subtitleCues: selected.$1,
      speechCues: transcript.cues,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
      preserveUnmatchedOutsideEvidence: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      operationLabel: repairCuts ? 'Captured-playback cut repair' : 'Captured-playback sync',
      operationLanguageCode: transcript.detectedLanguage,
      wordTimings: transcript.wordTimings,
    )) {
      return;
    }
    if (!mounted) return;
    final percent = (aligned.meanMatchConfidence * 100).round();
    setState(() {
      _status = context.t.subtitleAiUi.capturedPlaybackOperationApplied(
        operation: repairCuts ? context.t.subtitleAiUi.cutRepairLowercase : context.t.subtitleAiUi.syncLowercase,
        matchedCount: aligned.matchedCueCount,
        totalCount: aligned.totalCueCount,
        confidence: percent,
        discontinuityCount: aligned.discontinuityCount,
        evidenceNote: repairCuts ? context.t.subtitleAiUi.capturedEvidenceTimingNote : '',
        source: selected.$2,
        uploadedNote: _lastResultUploadedToServer ? context.t.subtitleAiUi.uploadedToServerLibraryNote : '',
      );
    });
    await _showApplied();
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
    );
  }

  Future<void> _storeReviewedRevision({
    required List<SubtitleCue> cues,
    required String operation,
    String? languageCode,
    required List<SubtitleWordTiming> wordTimings,
  }) async {
    final identity = _revisionIdentity;
    if (identity == null) {
      if (mounted) {
        setState(() => _revisionStatus = context.t.subtitleAiUi.revisionHistoryNeedsAnActiveProfileAndMediaItem);
      }
      return;
    }
    try {
      final revision = await SubtitleRevisionService.saveRevision(
        identity: identity,
        operation: operation,
        languageCode: languageCode,
        cues: cues,
        wordTimings: wordTimings,
      );
      if (mounted) {
        setState(
          () => _revisionStatus = context.t.subtitleAiUi.savedRevisionToThisDeviceForThisProf_12a75bb7(
            revisionId: revision.id,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _revisionStatus = context.t.subtitleAiUi.couldNotSaveThisRevisionLocally(error: error));
      }
    }
  }

  Future<bool> _storeUndoCheckpoint({
    required List<SubtitleCue> cues,
    required String operation,
    String? languageCode,
    required List<SubtitleWordTiming> wordTimings,
  }) async {
    final identity = _revisionIdentity;
    if (identity == null) {
      if (mounted) {
        setState(() => _revisionStatus = context.t.subtitleAiUi.persistentUndoCheckpointsNeedAStable_cca05e18);
      }
      return true;
    }
    try {
      final checkpointOperation = '$_subtitleUndoCheckpointPrefix${operation.trim()}';
      await SubtitleRevisionService.saveRevision(
        identity: identity,
        operation: checkpointOperation.length <= 120 ? checkpointOperation : checkpointOperation.substring(0, 120),
        languageCode: languageCode,
        cues: cues,
        wordTimings: wordTimings,
      );
      if (mounted) {
        setState(() => _revisionStatus = context.t.subtitleAiUi.savedAnUndoCheckpointToThisDeviceForThisItem);
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(
          () => _revisionStatus = context.t.subtitleAiUi.couldNotSaveAnUndoCheckpointTheAccep_6f1c79d5(error: error),
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
  }) async {
    final identity = _revisionIdentity;
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
      );
      if (!persisted) return;
      saved++;
    }
  }

  Future<void> _restoreSubtitleRevision(SubtitleRevision revision) async {
    final bytes = SubtitleSyncService.writeSrt(revision.cues);
    final directory = await getTemporaryDirectory();
    final path = p.join(directory.path, 'plezyng_revision_${revision.id}.srt');
    await File(path).writeAsBytes(bytes, flush: true);
    await widget.player.command(['sub-add', path, 'select']);
    if (mounted) {
      setState(
        () => _status = context.t.subtitleAiUi.attachedReviewedRevisionFrom(
          revisionDate: _formatRevisionDate(revision.createdAt),
        ),
      );
      OverlaySheetController.of(context).refocus();
    }
  }

  Future<void> _exportSubtitleRevision(SubtitleRevision revision) async {
    final result = await FilePickerService.instance.saveFile(
      dialogTitle: context.t.subtitleAiUi.exportReviewedSubtitleRevision,
      fileName: 'PlezyNG_revision_${revision.id}.srt',
      bytes: SubtitleSyncService.writeSrt(revision.cues),
      type: FileType.custom,
      allowedExtensions: const ['srt'],
    );
    if (mounted && result != null) {
      setState(() => _status = context.t.subtitleAiUi.reviewedSubtitleRevisionExportedAsSRT);
    }
  }

  String _formatRevisionDate(DateTime value) {
    final local = value.toLocal();
    String pad(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
  }

  Future<void> _showRevisionHistory() async {
    final identity = _revisionIdentity;
    if (identity == null) {
      setState(() => _revisionStatus = context.t.subtitleAiUi.revisionHistoryNeedsAStableProfileAndMediaItem);
      return;
    }
    try {
      var revisions = await SubtitleRevisionService.loadRevisions(identity);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final height = (MediaQuery.sizeOf(dialogContext).height - 220).clamp(240.0, 460.0).toDouble();
            return AlertDialog(
              title: Text(context.t.subtitleAiUi.subtitleRevisionHistory),
              content: SizedBox(
                width: 620,
                height: height,
                child: revisions.isEmpty
                    ? Center(child: Text(context.t.subtitleAiUi.noReviewedRevisionsHaveBeenSavedForThisItemYet))
                    : ListView.separated(
                        itemCount: revisions.length,
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, index) {
                          final revision = revisions[index];
                          final language = revision.languageCode == null ? '' : ' · ${revision.languageCode}';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(revision.operation, style: Theme.of(context).textTheme.titleSmall),
                                Text(
                                  context.t.subtitleAiUi.cues(
                                    revisionDate: _formatRevisionDate(revision.createdAt),
                                    revisionCueCount: revision.cues.length,
                                    language: language,
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (revision.wordTimings.isNotEmpty)
                                  Text(
                                    context.t.subtitleAiUi.tokenDerivedTimingSpansRetained(
                                      revisionWordtimingCount: revision.wordTimings.length,
                                    ),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        unawaited(_run(() => _restoreSubtitleRevision(revision)));
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
                                      label: Text(context.t.subtitleAiUi.export),
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
                                      label: Text(context.t.common.delete),
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
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(context.t.common.close)),
              ],
            );
          },
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _revisionStatus = context.t.subtitleAiUi.couldNotOpenSubtitleRevisionHistory(error: error));
      }
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
      if (mounted) setState(() => _status = context.t.subtitleAiUi.couldNotSaveTheSpeechLanguagePrefere_41ee943c);
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

  Future<void> _prepareTranslationModels() => _run(() async {
    await SubtitleTranslationService.prepareMobileModels(
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      allowMobileData: _allowMobileData,
      onStatus: (status) {
        if (mounted) setState(() => _status = status);
      },
    );
    if (mounted) setState(() => _status = context.t.subtitleAiUi.selectedLanguageModelsAreReadyForOff_eda629c6);
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
    final result = await SubtitleTranslationService.translateCues(
      cues: selected.$1,
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      allowMobileData: _allowMobileData,
      requestDesktopCuda: _requestTranslationCuda,
      bilingual: _bilingualTranslation,
      glossary: glossary,
      onProgress: (completed, total) {
        if (mounted) {
          setState(
            () => _status = context.t.subtitleAiUi.translatingCueOfOnThisDevice(completed: completed, total: total),
          );
        }
      },
    );
    if (result.cues.length != selected.$1.length) {
      throw StateError('Translation changed the cue count. No output was attached.');
    }
    for (var index = 0; index < result.cues.length; index++) {
      final sourceCue = selected.$1[index];
      final translatedCue = result.cues[index];
      if (translatedCue.startMs != sourceCue.startMs || translatedCue.endMs != sourceCue.endMs) {
        throw StateError('Translation changed cue timing at cue ${sourceCue.index}. No output was attached.');
      }
    }
    if (!await _writeAndApply(
      result.cues,
      operationLabel: 'Translated subtitles',
      operationLanguageCode: _targetLanguage.bcpCode,
      sourceCues: selected.$1,
      reviewWarnings: result.qualityWarnings,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _status = context.t.subtitleAiUi.translatedCuesFrom(
        cueCount: result.cues.length,
        sourceLanguage: SubtitleTranslationService.languageLabel(_sourceLanguage),
        targetLanguage: SubtitleTranslationService.languageLabel(_targetLanguage),
        backendLabel: result.backendLabel,
        uploadedNote: _lastResultUploadedToServer ? context.t.subtitleAiUi.uploadedToServerLibraryNote : '',
      );
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
            title: Text(context.t.subtitleAiUi.editSubtitleCue),
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
                      decoration: InputDecoration(
                        labelText: context.t.subtitleAiUi.cueText,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: context.t.subtitleAiUi.startMs,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: endController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: context.t.subtitleAiUi.endMs,
                              border: OutlineInputBorder(),
                            ),
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
              TextButton(onPressed: () => Navigator.of(editorContext).pop(false), child: Text(context.t.common.cancel)),
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
                      validationError = context.t.subtitleAiUi.useNonEmptyTextUpTo4000CharactersAnd_98f9f3ab;
                    });
                    return;
                  }
                  edited = SubtitleCue(index: cue.index, startMs: startMs, endMs: endMs, text: text);
                  Navigator.of(editorContext).pop(true);
                },
                child: Text(context.t.subtitleAiUi.saveCue),
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
              title: Text(context.t.subtitleAiUi.editAllCues(cuesCueCount: cues.length)),
              content: SizedBox(
                width: 720,
                height: (MediaQuery.sizeOf(editorContext).height - 220).clamp(280.0, 560.0).toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(context.t.subtitleAiUi.reviewOrEditAnyOutputCueChangesStayI_26d3610b),
                    const SizedBox(height: 8),
                    TextField(
                      controller: searchController,
                      maxLength: 128,
                      decoration: InputDecoration(
                        labelText: context.t.subtitleAiUi.findInSourceOrOutputCues,
                        prefixIcon: AppIcon(Symbols.search_rounded),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (value) => setEditorState(() => query = value),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.t.subtitleAiUi.showingOfCues(
                        visibleIndexesVisibleindexCount: visibleIndexes.length,
                        cuesCueCount: cues.length,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: visibleIndexes.isEmpty
                          ? Center(child: Text(context.t.subtitleAiUi.noCuesMatchThisSearch))
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
                                    context.t.subtitleAiUi.cue(
                                      cueIndex: cue.index,
                                      startTime: _formatCueTime(cue.startMs),
                                      endTime: _formatCueTime(cue.endMs),
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (original != null) ...[
                                        Text(
                                          context.t.subtitleAiUi.original,
                                          style: Theme.of(context).textTheme.labelSmall,
                                        ),
                                        SelectableText(original),
                                        const SizedBox(height: 4),
                                      ],
                                      Text(
                                        context.t.subtitleAiUi.output,
                                        style: Theme.of(context).textTheme.labelSmall,
                                      ),
                                      SelectableText(cue.text),
                                    ],
                                  ),
                                  trailing: IconButton(
                                    tooltip: context.t.subtitleAiUi.editCue,
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
                    label: Text(context.t.subtitleAiUi.undo(undoHistoryUndohistoryCount: undoHistory.length)),
                  ),
                TextButton(onPressed: () => Navigator.of(editorContext).pop(), child: Text(context.t.iptv.done)),
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
    if (normalized.contains('sync') || normalized.contains('repair')) return 'synchronized';
    return 'generated';
  }

  Future<bool> _writeAndApply(
    List<SubtitleCue> cues, {
    required String operationLabel,
    String? operationLanguageCode,
    List<SubtitleCue>? sourceCues,
    List<String> reviewWarnings = const [],
    List<SubtitleWordTiming> wordTimings = const <SubtitleWordTiming>[],
  }) async {
    if (cues.isEmpty || cues.length > SubtitleRetimer.maximumCueCount) {
      throw const FormatException('Subtitle result has no cues or exceeds the 50000 cue processing bound.');
    }
    if (sourceCues != null && sourceCues.length != cues.length) {
      throw StateError('Source and output cue counts do not match; no subtitle was attached.');
    }
    final reviewedCues = List<SubtitleCue>.from(cues);
    final reviewedWordTimings = SubtitleWordTimingBuilder.attachCueIndices(wordTimings, reviewedCues);
    final undoHistory = <(int, SubtitleCue)>[];
    _lastResultUploadedToServer = false;
    final uploadLanguage = _normalizedUploadLanguage(operationLanguageCode);
    final canUploadToServer =
        uploadLanguage != null && widget.serverId?.isNotEmpty == true && widget.ratingKey?.isNotEmpty == true;
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
          title: Text(context.t.subtitleAiUi.review(operationLabel: operationLabel)),
          content: SizedBox(
            width: 560,
            height: (MediaQuery.sizeOf(dialogContext).height - 220).clamp(240.0, 420.0).toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.t.subtitleAiUi.cuesAreReadyReviewThisSampleBeforeAt_2851cf04(cuesCueCount: cues.length)),
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
                          reviewWarnings.length == 1
                              ? context.t.subtitleAiUi.glossaryMismatchOne(count: reviewWarnings.length)
                              : context.t.subtitleAiUi.glossaryMismatchMany(count: reviewWarnings.length),
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
                          Text(
                            context.t.subtitleAiUi.andMore(count: reviewWarnings.length - 3),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                Text(
                  context.t.subtitleAiUi.saveSRTOrJSONExportsTheReviewedResul_b960b84b,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  reviewedWordTimings.isEmpty
                      ? 'This backend did not return token timestamps; cue timing remains available.'
                      : 'JSON includes ${reviewedWordTimings.length} token-derived word timings. Whisper token confidence is not calibrated.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton.icon(
                  onPressed: () => unawaited(
                    _showFullCueEditor(
                      dialogContext,
                      reviewedCues,
                      sourceCues: sourceCues,
                      undoHistory: undoHistory,
                      onChanged: () => setDialogState(() {}),
                    ),
                  ),
                  icon: const AppIcon(Symbols.edit_rounded),
                  label: Text(context.t.subtitleAiUi.editAllCues_8771718b),
                ),
                if (widget.selectedSubtitleBurnedIn)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      context.t.subtitleAiUi.theCurrentlySelectedCaptionsAreBurne_9904ad02,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (canUploadToServer)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      context.t.subtitleAiUi.uploadAttachStoresThisSRTOnTheActive_3e49fa27,
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
                              Text(context.t.subtitleAiUi.original, style: Theme.of(context).textTheme.labelSmall),
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
                                  }
                                },
                                icon: const AppIcon(Symbols.edit_rounded),
                                label: Text(context.t.subtitleAiUi.editSampleCue),
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
                },
                icon: const AppIcon(Symbols.undo_rounded),
                label: Text(context.t.subtitleAiUi.undo(undoHistoryUndohistoryCount: undoHistory.length)),
              ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.exportSrt),
              icon: const AppIcon(Symbols.save_alt_rounded),
              label: Text(context.t.subtitleAiUi.saveSRT),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.exportJson),
              icon: const AppIcon(Symbols.data_object_rounded),
              label: Text(context.t.subtitleAiUi.saveJSON),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.discard),
              child: Text(context.t.subtitleAiUi.discard),
            ),
            if (canUploadToServer)
              OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.serverAndPlayer),
                child: Text(context.t.subtitleAiUi.uploadAttach),
              ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.player),
              child: Text(context.t.subtitleAiUi.attachToPlayer),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null || choice == _SubtitleReviewChoice.discard) {
      if (mounted) {
        setState(() => _status = context.t.subtitleAiUi.subtitleResultDiscardedTheCurrentTra_a846b389);
      }
      return false;
    }
    final bytes = SubtitleSyncService.writeSrt(reviewedCues);
    final originToken = _originTokenForOperation(operationLabel);
    if (choice == _SubtitleReviewChoice.exportSrt) {
      final exportPath = await FilePickerService.instance.saveFile(
        dialogTitle: context.t.subtitleAiUi.saveReviewedSubtitle,
        fileName: 'PlezyNG_${originToken}_${DateTime.now().microsecondsSinceEpoch}.srt',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['srt'],
      );
      if (!mounted) return false;
      if (exportPath == null) {
        setState(() => _status = context.t.subtitleAiUi.sRTExportWasCancelledTheActiveTrackA_62f0bcfe);
        return false;
      }
      await _storeReviewedRevision(
        cues: reviewedCues,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
      );
      await _storeUndoHistory(
        cues: reviewedCues,
        undoHistory: undoHistory,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
      );
      if (mounted) setState(() => _status = context.t.subtitleAiUi.reviewedSubtitleExportedAsSRT);
      return false;
    }
    if (choice == _SubtitleReviewChoice.exportJson) {
      final jsonBytes = Uint8List.fromList(
        utf8.encode(
          JsonEncoder.withIndent('  ').convert({
            'schema': 'plezyng.subtitle-cues.v2',
            'generatedBy': 'PlezyNG',
            'operation': operationLabel,
            'language': operationLanguageCode,
            'timebase': 'milliseconds',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'cues': reviewedCues
                .map((cue) => {'index': cue.index, 'startMs': cue.startMs, 'endMs': cue.endMs, 'text': cue.text})
                .toList(growable: false),
            'wordTimingAvailability': reviewedWordTimings.isEmpty
                ? 'not-returned-by-backend'
                : 'whisper-token-timestamps',
            'wordTimings': reviewedWordTimings
                .map(
                  (word) => {
                    'startMs': word.startMs,
                    'endMs': word.endMs,
                    'text': word.text,
                    'unit': word.unit.name,
                    'probability': word.confidence,
                    'cueIndex': word.cueIndex,
                  },
                )
                .toList(growable: false),
          }),
        ),
      );
      final exportPath = await FilePickerService.instance.saveFile(
        dialogTitle: context.t.subtitleAiUi.saveReviewedSubtitleCueJSON,
        fileName: 'PlezyNG_${originToken}_${DateTime.now().microsecondsSinceEpoch}.json',
        bytes: jsonBytes,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (!mounted) return false;
      if (exportPath == null) {
        setState(() => _status = context.t.subtitleAiUi.jSONExportWasCancelledTheActiveTrack_9ae1948d);
        return false;
      }
      await _storeReviewedRevision(
        cues: reviewedCues,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
      );
      await _storeUndoHistory(
        cues: reviewedCues,
        undoHistory: undoHistory,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
      );
      if (mounted) setState(() => _status = context.t.subtitleAiUi.reviewedSubtitleExportedAsVersionedCueJSON);
      return false;
    }
    if (choice == _SubtitleReviewChoice.serverAndPlayer) {
      final languageCode = uploadLanguage;
      if (languageCode == null) throw StateError('The result language could not be identified for server upload.');
      await _uploadSubtitleToServer(bytes, languageCode, originToken);
      _lastResultUploadedToServer = true;
    }
    final directory = await getTemporaryDirectory();
    final path = p.join(directory.path, 'plezyng_ai_${originToken}_${DateTime.now().microsecondsSinceEpoch}.srt');
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      await widget.player.command(['sub-add', path, 'select']);
    } catch (error) {
      if (_lastResultUploadedToServer) {
        await _storeReviewedRevision(
          cues: reviewedCues,
          operation: operationLabel,
          languageCode: operationLanguageCode,
          wordTimings: reviewedWordTimings,
        );
        await _storeUndoHistory(
          cues: reviewedCues,
          undoHistory: undoHistory,
          operation: operationLabel,
          languageCode: operationLanguageCode,
          wordTimings: reviewedWordTimings,
        );
        throw StateError('Uploaded to the server library, but could not attach the local copy: $error');
      }
      rethrow;
    }
    await _storeReviewedRevision(
      cues: reviewedCues,
      operation: operationLabel,
      languageCode: operationLanguageCode,
      wordTimings: reviewedWordTimings,
    );
    await _storeUndoHistory(
      cues: reviewedCues,
      undoHistory: undoHistory,
      operation: operationLabel,
      languageCode: operationLanguageCode,
      wordTimings: reviewedWordTimings,
    );
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
    return context.t.subtitleAiUi.subtitleOperationFailed(error: error);
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
          decoration: InputDecoration(labelText: context.t.subtitleAiUi.speechLanguage, border: OutlineInputBorder()),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(context.t.subtitleAiUi.autoDetect)),
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
              context.t.subtitleAiUi.theSelectedAcceleratorUsesAnEnglishO_8735cf91,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final providers = SubtitleAiService.availableProviderRequests;
    if (!providers.contains(_provider)) _provider = SubtitleInferenceProvider.cpu;
    return BaseVideoControlSheet(
      title: 'AI subtitles',
      icon: Symbols.auto_awesome_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          Text(
            context.t.subtitleAiUi.wAVTranscriptionAndAudioSyncUseA16Bi_31205915,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: InputDecoration(
              labelText: context.t.subtitleAiUi.inferenceBackend,
              border: OutlineInputBorder(),
            ),
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
              title: Text(context.t.subtitleAiUi.subtitleRevisionHistory),
              subtitle: Text(context.t.subtitleAiUi.restoreExportOrDeleteReviewedVersion_e84dffb9),
              onTap: _busy ? null : () => unawaited(_showRevisionHistory()),
            ),
          if (_playbackCaptureSupported) ...[
            const Divider(height: 24),
            Text(context.t.subtitleAiUi.liveCaptionsFromPlayback, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              context.t.subtitleAiUi.theActivePlayerCopiesBoundedDecodedP_1bef0371,
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
                            ? 'Loading the local Whisper model'
                            : (service.isRunning || service.hasActiveSession)
                            ? 'Stop capture and retain the transcript for sync'
                            : 'This player session; downloads the local Whisper model on first use',
                      ),
                      onTap: (_busy || service.isStarting) ? null : () => unawaited(_captureLivePlayback()),
                    ),
                    if (service.hasRecentTranscript)
                      FocusableListTile(
                        leading: const AppIcon(Symbols.search_rounded),
                        title: Text(context.t.subtitleAiUi.browseCapturedTranscript),
                        subtitle: Text(context.t.subtitleAiUi.searchCuesSeekToTheirStartOrHideFutureDialogue),
                        onTap: () => unawaited(_showCapturedTranscript(service)),
                      ),
                    if (service.hasRecentTranscript && !service.isRunning) ...[
                      FocusableListTile(
                        leading: const AppIcon(Symbols.sync_rounded),
                        title: Text(context.t.subtitleAiUi.syncFromCapturedPlayback),
                        subtitle: Text(context.t.subtitleAiUi.alignsTheWatchedPortionAgainstAnExistingSubtitle),
                        onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlayback(repairCuts: false)),
                      ),
                      FocusableListTile(
                        leading: const AppIcon(Symbols.content_cut_rounded),
                        title: Text(context.t.subtitleAiUi.repairCutsFromCapturedPlayback),
                        subtitle: Text(context.t.subtitleAiUi.preservesCueTimingOutsideSpeechMatchedEvidence),
                        onTap: _busy ? null : () => unawaited(_synchronizeCapturedPlayback(repairCuts: true)),
                      ),
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
              title: Text(context.t.subtitleAiUi.translateDetectedSpeechToEnglish),
              subtitle: Text(context.t.subtitleAiUi.usedOnlyForGenerationSyncAlwaysTrans_5a1e6651),
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
            onTap: _busy ? null : () => unawaited(_transcribe()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.sync_rounded),
            title: Text(context.t.subtitleAiUi.automaticallySyncAnExistingSubtitle),
            subtitle: Text(context.t.subtitleAiUi.alignsSRTVTTASSOrSSATextAgainstLocal_6c0ca7b3),
            onTap: _busy ? null : () => unawaited(_synchronize(repairCuts: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: Text(context.t.subtitleAiUi.repairCutsAndSync),
            subtitle: Text(context.t.subtitleAiUi.usesPiecewiseTimingWhereSubtitleAudi_a09bdd2c),
            onTap: _busy ? null : () => unawaited(_synchronize(repairCuts: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.closed_caption_rounded),
            title: Text(context.t.subtitleAiUi.syncToAnotherSubtitle),
            subtitle: Text(context.t.subtitleAiUi.useASameLanguageSRTVTTASSOrSSASubtit_4f603312),
            onTap: _busy ? null : () => unawaited(_synchronizeToReference(repairCuts: false)),
          ),
          if (_translationSupported)
            FocusableListTile(
              leading: const AppIcon(Symbols.translate_rounded),
              title: Text(context.t.subtitleAiUi.syncAcrossSubtitleLanguages),
              subtitle: Text(context.t.subtitleAiUi.translateTargetTextLocallyForMatchin_8e05d8e7),
              onTap: _busy ? null : () => unawaited(_synchronizeAcrossLanguages(repairCuts: false)),
            ),
          if (_translationSupported)
            FocusableListTile(
              leading: const AppIcon(Symbols.content_cut_rounded),
              title: Text(context.t.subtitleAiUi.repairCutsAcrossSubtitleLanguages),
              subtitle: Text(context.t.subtitleAiUi.usesTranslatedTextForAnchorsAndKeeps_3fd7071f),
              onTap: _busy ? null : () => unawaited(_synchronizeAcrossLanguages(repairCuts: true)),
            ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: Text(context.t.subtitleAiUi.repairCutsUsingAnotherSubtitle),
            subtitle: Text(context.t.subtitleAiUi.applyPiecewiseOffsetsWhereDialogueAn_cfd3013c),
            onTap: _busy ? null : () => unawaited(_synchronizeToReference(repairCuts: true)),
          ),
          if (_translationSupported) ...[
            const Divider(height: 24),
            Text(context.t.subtitleAiUi.localSubtitleTranslation, style: Theme.of(context).textTheme.titleMedium),
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
                title: Text(context.t.subtitleAiUi.useASeriesSpecificGlossary),
                subtitle: Text(context.t.subtitleAiUi.startsWithTheProfileGlossarySavedEdi_5ab98347),
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
              title: Text(context.t.subtitleAiUi.bilingualSubtitleOutput),
              subtitle: Text(context.t.subtitleAiUi.showTheOriginalLineFollowedByItsTran_912a8201),
              value: _bilingualTranslation,
              onChanged: _busy ? null : (value) => setState(() => _bilingualTranslation = value),
            ),
            TextField(
              controller: _glossaryController,
              minLines: 2,
              maxLines: 4,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: context.t.subtitleAiUi.translationGlossaryJSON,
                hintText: context.t.subtitleAiUi.tARDISTARDISTheDoctorElDoctor,
                helperText: widget.seriesKey == null
                    ? 'Protects up to 200 whole terms. Saved for this profile and language pair.'
                    : 'Protects up to 200 terms. Choose profile or series scope above.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => _glossaryDrafts[_currentGlossaryDraftKey()] = value,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : () => unawaited(_run(_saveGlossary)),
                icon: const AppIcon(Symbols.save_rounded),
                label: Text(context.t.subtitleAiUi.saveGlossary),
              ),
            ),
            const SizedBox(height: 8),
            if (SubtitleTranslationService.mobilePlatformSupported) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.t.subtitleAiUi.allowLanguageModelDownloadsOverMobileData),
                value: _allowMobileData,
                onChanged: _busy ? null : (value) => setState(() => _allowMobileData = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_prepareTranslationModels()),
                  icon: const AppIcon(Symbols.download_for_offline_rounded),
                  label: Text(context.t.subtitleAiUi.prepareOfflineLanguageModels),
                ),
              ),
            ],
            if (SubtitleTranslationService.desktopPlatformSupported && (Platform.isWindows || Platform.isLinux))
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.t.subtitleAiUi.requestArgosCUDA),
                subtitle: Text(context.t.subtitleAiUi.requiresACUDAEnabledArgosCTranslate2_25eb4fab),
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
              title: Text(context.t.subtitleAiUi.translateAnExistingSubtitle),
              subtitle: Text(context.t.subtitleAiUi.timingAndSourceFileRemainUnchanged),
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
      )?.showSnackBar(SnackBar(content: Text(context.t.subtitleAiUi.couldNotSeekToThisTranscriptCue)));
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
              title: Text(context.t.subtitleAiUi.capturedTranscript),
              content: SizedBox(
                width: 620,
                height: height,
                child: Column(
                  children: [
                    Text(
                      context.t.subtitleAiUi.onlyWatchedPortionsAreIncludedSelect_bb56a271,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const AppIcon(Symbols.search_rounded),
                        labelText: context.t.subtitleAiUi.searchTranscript,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: context.t.subtitleAiUi.clearSearch,
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
                      title: Text(context.t.subtitleAiUi.hideFutureDialogue),
                      subtitle: Text(context.t.subtitleAiUi.showCuesFromTheCurrentPlayheadAndEarlier),
                      value: _hideFutureDialogue,
                      onChanged: (value) => setState(() => _hideFutureDialogue = value),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.t.subtitleAiUi.cueCountSummary(
                          visibleCount: filtered.length,
                          totalCount: cues.length,
                          seekingNote: canSeek ? '' : context.t.subtitleAiUi.seekingUnavailableNote,
                        ),
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
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.common.close))],
            );
          },
        );
      },
    );
  }
}
