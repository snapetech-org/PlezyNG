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
import '../../../mpv/player/subtitle_pcm_capture_source.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_ai_service.dart';
import '../../../services/subtitle_placement_evidence.dart';
import '../../../services/subtitle_retimer.dart';
import '../../../services/subtitle_word_timing.dart';
import '../../../services/subtitle_sync_service.dart';
import '../../../services/subtitle_interval_service.dart';
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
enum _SubtitleReviewChoice { discard, exportSrt, exportJson, player, serverAndPlayer, sourceAndPlayer }

typedef SubtitleSourceSubtitleSaver = Future<void> Function(String name, Uint8List bytes, String languageCode);

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
    throw const StateError('Translation changed the cue count; no output was attached.');
  }
  final sourceById = _subtitleCuesByStableId(source);
  final translatedById = _subtitleCuesByStableId(translated);
  if (sourceById.length != translatedById.length) {
    throw const StateError('Translation changed cue identities; no output was attached.');
  }
  for (final entry in sourceById.entries) {
    final translatedCue = translatedById[entry.key];
    if (translatedCue == null ||
        translatedCue.startMs != entry.value.startMs ||
        translatedCue.endMs != entry.value.endMs) {
      throw const StateError('Translation changed cue identity or timing; no output was attached.');
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
  final Set<String> _temporaryWavPaths = <String>{};
  bool _playbackCaptureSupported = false;
  bool _lastResultUploadedToServer = false;
  bool _lastResultSavedToSource = false;
  String? _status;
  String? _error;
  String? _revisionStatus;
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  SubtitleInferenceProvider _liveProvider = SubtitleInferenceProvider.cpu;
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
      await _deleteTemporaryWavCopies();
      if (mounted) setState(() => _busy = false);
    }
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
      _status =
          'Generated ${result.cues.length} cues from ${(result.durationMs / 60000).ceil()} minutes of audio. '
          '${result.translatedToEnglish ? 'Speech translated to English' : 'Detected language: ${result.detectedLanguage}'}. '
          'Requested/initialized backend: $providerLabel. Placement evidence: ${result.placementEvidence.displayLabel}. '
          'Original audio remains unchanged.'
          '$_resultPersistenceSuffix';
    });
    await _showApplied();
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
            title: const Text('Choose transcription interval'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Audio outside this range is not transcribed. Existing subtitle cues outside it are preserved.'),
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
                child: const Text('Transcribe interval'),
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
      provider: _liveProvider,
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
      throw const StateError('Translation changed the transcript cue count; no subtitle was attached.');
    }
    for (var index = 0; index < translated.cues.length; index++) {
      if (translated.cues[index].startMs != transcriptCues[index].startMs ||
          translated.cues[index].endMs != transcriptCues[index].endMs) {
        throw const StateError('Translation changed transcript timing; no subtitle was attached.');
      }
    }
    if (!await _writeAndApply(
      translated.cues,
      operationLabel: 'Translated speech transcript',
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
      subtitleCues: selected.$1,
      speechCues: revision.cues,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
      preserveUnmatchedOutsideEvidence: repairCuts,
    );
    if (!await _writeAndApply(
      aligned.cues,
      operationLabel: repairCuts ? 'Saved-transcript cut repair' : 'Saved-transcript sync',
      operationLanguageCode: revision.languageCode,
      wordTimings: revision.wordTimings,
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
      subtitleCues: translated.cues,
      speechCues: transcriptCues,
      mediaDurationMs: durationMs,
      repairCuts: repairCuts,
      preserveUnmatchedOutsideEvidence: repairCuts,
    );
    final retimedOriginal = _restoreOriginalCueTextWithAlignedTimes(selected.$1, aligned.cues);
    if (!await _writeAndApply(
      retimedOriginal,
      operationLabel: repairCuts ? 'Cross-language transcript cut repair' : 'Cross-language transcript sync',
      operationLanguageCode: sourceLanguage.bcpCode,
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
  }) async {
    final identity = _revisionIdentity;
    if (identity == null) {
      if (mounted) setState(() => _revisionStatus = 'Revision history needs an active profile and media item.');
      return false;
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
  }) async {
    final identity = _revisionIdentity;
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
      if (!mounted) return;
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
    final result = await SubtitleTranslationService.translateCues(
      cues: selected.$1,
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
    _requireSubtitleCueIdentityPreserved(selected.$1, result.cues);
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
    SubtitleRevisionDraft? resumeDraft,
    SubtitleRevisionIdentity? resumeIdentity,
  }) async {
    if (cues.isEmpty || cues.length > SubtitleRetimer.maximumCueCount) {
      throw const FormatException('Subtitle result has no cues or exceeds the 50000 cue processing bound.');
    }
    if (sourceCues != null && sourceCues.length != cues.length) {
      throw StateError('Source and output cue counts do not match; no subtitle was attached.');
    }
    var reviewedCues = List<SubtitleCue>.from(cues);
    final originalCuesById = <String, SubtitleCue>{for (final cue in cues) cue.stableId: cue};
    var reviewedWordTimings = SubtitleWordTimingBuilder.attachCueIndices(wordTimings, reviewedCues).toList();
    var invalidatedWordTimingCount = 0;
    final undoHistory = <(int, SubtitleCue)>[];
    final draftIdentity = _revisionIdentity;
    final sourceFingerprint = SubtitleRevisionService.reviewFingerprint(cues, sourceCues: sourceCues);
    if (resumeDraft != null) {
      if (draftIdentity == null ||
          resumeIdentity == null ||
          draftIdentity.storageKey != resumeIdentity.storageKey ||
          resumeDraft.sourceFingerprint != sourceFingerprint ||
          resumeDraft.operation != operationLabel) {
        throw StateError('This subtitle review draft no longer matches the active item or cue set.');
      }
      reviewedCues = List<SubtitleCue>.from(resumeDraft.cues);
      reviewedWordTimings = List<SubtitleWordTiming>.from(resumeDraft.wordTimings);
      undoHistory.addAll(resumeDraft.undoHistory);
    } else if (draftIdentity != null) {
      final draft = await SubtitleRevisionService.loadDraftForIdentity(draftIdentity);
      if (draft != null && mounted) {
        if (draft.sourceFingerprint == sourceFingerprint && draft.operation == operationLabel) {
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
        uploadLanguage != null && widget.serverId?.isNotEmpty == true && widget.ratingKey?.isNotEmpty == true;
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
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(_SubtitleReviewChoice.player),
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
    if (choice != _SubtitleReviewChoice.exportSrt &&
        choice != _SubtitleReviewChoice.exportJson &&
        widget.isRevisionIdentityCurrent?.call() == false) {
      throw StateError('Playback changed while the subtitle was being reviewed. Reopen subtitle tools for the current item.');
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
      );
      final revisionSaved = await _storeReviewedRevision(
        cues: reviewedCues,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
      );
      if (revisionSaved) await clearReviewDraft();
      if (mounted) setState(() => _status = 'Reviewed subtitle exported as SRT.');
      return false;
    }
    if (choice == _SubtitleReviewChoice.exportJson) {
      final jsonBytes = Uint8List.fromList(
        utf8.encode(
          JsonEncoder.withIndent('  ').convert({
            'schema': 'plezyng.subtitle-cues.v3',
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
                : (invalidatedWordTimingCount > 0 ? 'partial-after-cue-edits' : 'whisper-token-timestamps'),
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
      );
      final revisionSaved = await _storeReviewedRevision(
        cues: reviewedCues,
        operation: operationLabel,
        languageCode: operationLanguageCode,
        wordTimings: reviewedWordTimings,
      );
      if (revisionSaved) await clearReviewDraft();
      if (mounted) setState(() => _status = 'Reviewed subtitle exported as versioned cue JSON.');
      return false;
    }
    if (choice == _SubtitleReviewChoice.serverAndPlayer) {
      final languageCode = uploadLanguage;
      if (languageCode == null) throw StateError('The result language could not be identified for server upload.');
      await _uploadSubtitleToServer(bytes, languageCode, originToken);
      _lastResultUploadedToServer = true;
    }
    try {
      if (choice == _SubtitleReviewChoice.sourceAndPlayer) {
        final saveToSource = widget.onSaveToSource;
        if (saveToSource == null) throw StateError('This item cannot store a standalone subtitle sidecar.');
        await saveToSource('PlezyNG.$originToken.srt', bytes, operationLanguageCode?.trim() ?? '');
        _lastResultSavedToSource = true;
      } else {
        final directory = await getTemporaryDirectory();
        final path = p.join(
          directory.path,
          'plezyng_ai_${originToken}_${DateTime.now().microsecondsSinceEpoch}.srt',
        );
        await File(path).writeAsBytes(bytes, flush: true);
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
        );
        await _storeReviewedRevision(
          cues: reviewedCues,
          operation: operationLabel,
          languageCode: operationLanguageCode,
          wordTimings: reviewedWordTimings,
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
    );
    final revisionSaved = await _storeReviewedRevision(
      cues: reviewedCues,
      operation: operationLabel,
      languageCode: operationLanguageCode,
      wordTimings: reviewedWordTimings,
    );
    if (revisionSaved) await clearReviewDraft();
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
                    if (liveProviders.length > 1) ...[
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
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Live captions backend: CPU (multilingual Whisper)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
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
            onTap: _busy ? null : () => unawaited(_transcribe()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.queue_music_rounded),
            title: const Text('Replace captions in an interval'),
            subtitle: const Text('Transcribe a selected WAV range; keep source cues outside it'),
            onTap: _busy ? null : () => unawaited(_generateInterval(fillSpeechGaps: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.add_comment_rounded),
            title: const Text('Fill speech-detected caption gaps'),
            subtitle: const Text('Add recognized speech only in long uncovered ranges; review before attaching'),
            onTap: _busy ? null : () => unawaited(_generateInterval(fillSpeechGaps: true)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.sync_rounded),
            title: const Text('Automatically sync an existing subtitle'),
            subtitle: const Text('Aligns SRT, VTT, ASS, or SSA text against local speech recognition'),
            onTap: _busy ? null : () => unawaited(_synchronize(repairCuts: false)),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.content_cut_rounded),
            title: const Text('Repair cuts and sync'),
            subtitle: const Text('Uses piecewise timing where subtitle/audio text anchors suggest a cut offset change'),
            onTap: _busy ? null : () => unawaited(_synchronize(repairCuts: true)),
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
