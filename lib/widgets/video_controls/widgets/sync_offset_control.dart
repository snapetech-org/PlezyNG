import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_slider.dart';
import '../../../i18n/presentation_formats.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../mpv/mpv.dart';
import '../../../mpv/player/player_media_session_identity.dart';
import '../../../services/player_sync_offsets.dart';
import '../../../services/scoped_player_prefs.dart';
import '../../../services/subtitle_sync_calibration.dart';
import '../../../services/subtitle_cue_document.dart';
import '../../../services/subtitle_calibration_history.dart';
import '../../../services/library_sync_correction.dart';
import '../../subtitle_calibration_dialog.dart';
import '../sheets/subtitle_timing_transfer_dialog.dart';
import '../../../services/subtitle_retimer.dart';
import '../../../services/file_picker_service.dart';
import '../../subtitle_cue_picker_sheet.dart';
import '../../../utils/dialogs.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../services/subtitle_selection_rules.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/formatters.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/latest_async_write.dart';

/// Reusable widget for adjusting sync offsets (audio or subtitle)
class SyncOffsetControl extends StatefulWidget {
  final Player player;
  final String propertyName; // 'audio-delay' or 'sub-delay'
  final String? contentIdentity;
  final bool allowFileTools;
  final bool Function()? isCurrent;
  final int initialOffset;
  final double initialSubtitleRate;
  final Future<void> Function(double rate)? onSubtitleRateChanged;
  final Future<void> Function(int offset) onOffsetChanged;

  /// Focus node for the reset button. When provided from the parent, allows
  /// the close button's left-press to focus the reset button.
  final FocusNode? resetFocusNode;

  /// Focus node for the close button. When provided, pressing select/enter
  /// on the slider moves focus here.
  final FocusNode? closeFocusNode;

  /// Focus node for the slider. When provided, allows the parent to
  /// auto-focus the slider when the bar opens.
  final FocusNode? sliderFocusNode;

  const SyncOffsetControl({
    super.key,
    required this.player,
    required this.propertyName,
    this.contentIdentity,
    this.allowFileTools = true,
    this.isCurrent,
    required this.initialOffset,
    this.initialSubtitleRate = 1.0,
    this.onSubtitleRateChanged,
    required this.onOffsetChanged,
    this.resetFocusNode,
    this.closeFocusNode,
    this.sliderFocusNode,
  });

  @override
  State<SyncOffsetControl> createState() => _SyncOffsetControlState();
}

class _SyncOffsetControlState extends State<SyncOffsetControl> {
  // Range constants
  static const double _sliderMin = -10_000; // ±10s slider range for fine control
  static const double _sliderMax = 10_000;
  static const double _absoluteMin = ScopedPlayerPrefs.minimumSyncOffsetMs * 1.0;
  static const double _absoluteMax = ScopedPlayerPrefs.maximumSyncOffsetMs * 1.0;
  // Audio gets 10ms steps, the lip-sync granularity other players offer
  // (#2620); subtitle corrections run to seconds, so they keep 50ms. The
  // slider step is also the D-pad step on TV, where the slider holds focus
  // and owns left/right; long-press keeps a 1s stride for large corrections.
  static const double _longPressStep = 1000;

  double get _step => widget.propertyName == PlayerSyncOffsets.audioProperty ? 10 : 50;
  int get _sliderDivisions => (_sliderMax - _sliderMin) ~/ _step;

  late double _currentOffset;
  late double _confirmedOffset;
  late double _currentSubtitleRate;
  late double _confirmedSubtitleRate;
  SubtitleSyncCalibration? _undoSubtitleCalibration;
  int _writeGeneration = 0;
  int _bindingGeneration = 0;
  Timer? _longPressTimer;
  bool _fileToolBusy = false;
  late bool Function() _sourceCurrent;

  void _bindSource() {
    final player = widget.player, property = widget.propertyName;
    final media = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    final profile = SubtitleSelectionRules.activeProfileId;
    final audio = player.state.track.audio;
    final timeline = player.timelineOffset;
    final subtitle = property == PlayerSyncOffsets.secondarySubtitleProperty
        ? player.state.track.secondarySubtitle : player.state.track.subtitle;
    final check = widget.isCurrent;
    _sourceCurrent = () => !player.disposed && SubtitleSelectionRules.activeProfileId == profile &&
        (media == null || (player is PlayerMediaSessionIdentity && player.mediaSessionGeneration == media)) &&
        player.timelineOffset == timeline && player.state.track.audio == audio && (property == PlayerSyncOffsets.audioProperty ||
        (property == PlayerSyncOffsets.secondarySubtitleProperty
          ? player.state.track.secondarySubtitle : player.state.track.subtitle) == subtitle) &&
        (check?.call() ?? true);
  }

  void _checkBinding(int generation, Player player) {
    if (!mounted || generation != _bindingGeneration || player != widget.player || !_sourceCurrent()) {
      throw StateError('Playback or selected tracks changed. Reopen the timing control.');
    }
  }

  Future<void> _setFor(int generation, Player player, String property, String value) async {
    _checkBinding(generation, player);
    await player.setProperty(property, value);
    _checkBinding(generation, player);
  }

  Future<String?> _getFor(int generation, Player player, String property) async {
    _checkBinding(generation, player);
    final value = await player.getProperty(property);
    _checkBinding(generation, player);
    return value;
  }

  Future<void> _commandFor(int generation, Player player, List<String> command) async {
    _checkBinding(generation, player);
    await player.command(command);
    _checkBinding(generation, player);
  }

  @override
  void initState() {
    super.initState();
    _bindSource();
    _currentOffset = widget.initialOffset.toDouble();
    _confirmedOffset = _currentOffset;
    _currentSubtitleRate = widget.initialSubtitleRate;
    _confirmedSubtitleRate = _currentSubtitleRate;
  }

  @override
  void didUpdateWidget(SyncOffsetControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bindingChanged =
        widget.player != oldWidget.player ||
        widget.propertyName != oldWidget.propertyName ||
        widget.contentIdentity != oldWidget.contentIdentity;
    final valuesChanged =
        widget.initialOffset != oldWidget.initialOffset || widget.initialSubtitleRate != oldWidget.initialSubtitleRate;
    if (bindingChanged || valuesChanged) {
      final offsetMatchesCurrentIntent = widget.initialOffset == _currentOffset.round();
      final offsetIsUnchanged = widget.initialOffset == oldWidget.initialOffset;
      final rateMatchesCurrentIntent = (widget.initialSubtitleRate - _currentSubtitleRate).abs() <= 0.001;
      final rateIsUnchanged = widget.initialSubtitleRate == oldWidget.initialSubtitleRate;
      final valuesMatchCurrentIntent =
          (offsetMatchesCurrentIntent || offsetIsUnchanged) && (rateMatchesCurrentIntent || rateIsUnchanged);
      ++_writeGeneration;
      ++_bindingGeneration;
      if (bindingChanged) _bindSource();
      _currentOffset = widget.initialOffset.toDouble();
      _confirmedOffset = _currentOffset;
      _currentSubtitleRate = widget.initialSubtitleRate;
      _confirmedSubtitleRate = _currentSubtitleRate;
      if (bindingChanged || !valuesMatchCurrentIntent) {
        _undoSubtitleCalibration = null;
      }
    }
  }

  @override
  void dispose() {
    ++_writeGeneration;
    ++_bindingGeneration;
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _applyOffset(double offsetMs) {
    final targetPlayer = widget.player;
    final propertyName = widget.propertyName;
    final persistOffset = widget.onOffsetChanged;
    final coordinator = playerSyncWrites[targetPlayer] ??= LatestAsyncWrite<String>();
    final writeToken = coordinator.begin(propertyName);
    final generation = ++_writeGeneration;
    final bindingGeneration = _bindingGeneration;
    unawaited(() async {
      try {
        final committed = await coordinator.commitIfLatest(propertyName, writeToken, () async {
          // Convert milliseconds to seconds for mpv. Keep the native write and
          // persistence on the same per-player/property queue so an older
          // native write can never complete after a newer one.
          final offsetSeconds = offsetMs / 1000.0;
          await _setFor(bindingGeneration, targetPlayer, propertyName, offsetSeconds.toString());
          PlayerSyncOffsets.of(targetPlayer).recordApplied(propertyName, offsetMs.round());
          _checkBinding(bindingGeneration, targetPlayer);
          await persistOffset(offsetMs.round());
          if (mounted &&
              bindingGeneration == _bindingGeneration &&
              targetPlayer == widget.player &&
              propertyName == widget.propertyName) {
            // A write may finish successfully after a newer intent was queued.
            // Keep it as the rollback baseline without replacing the newer
            // optimistic value currently shown by the control.
            setState(() {
              _confirmedOffset = offsetMs;
              if (propertyName == PlayerSyncOffsets.subtitleProperty) {
                _undoSubtitleCalibration = null;
              }
            });
          }
        });
        if (!committed ||
            !mounted ||
            generation != _writeGeneration ||
            targetPlayer != widget.player ||
            propertyName != widget.propertyName) {
          return;
        }
      } catch (error, stackTrace) {
        appLogger.w('Failed to update playback sync offset', error: error, stackTrace: stackTrace);
        if (!mounted ||
            generation != _writeGeneration ||
            targetPlayer != widget.player ||
            propertyName != widget.propertyName) {
          return;
        }
        final rollbackOffset = _confirmedOffset.round();
        try {
          await _setFor(bindingGeneration, targetPlayer, propertyName, (rollbackOffset / 1000.0).toString());
          PlayerSyncOffsets.of(targetPlayer).recordApplied(propertyName, rollbackOffset);
          _checkBinding(bindingGeneration, targetPlayer);
          await persistOffset(rollbackOffset);
        } on Object catch (rollbackError, rollbackStackTrace) {
          appLogger.w(
            'Could not restore subtitle timing after sync save failed',
            error: rollbackError,
            stackTrace: rollbackStackTrace,
          );
        }
        if (mounted &&
            generation == _writeGeneration &&
            targetPlayer == widget.player &&
            propertyName == widget.propertyName) {
          setState(() {
            _currentOffset = _confirmedOffset;
          });
        }
      }
    }());
  }

  Future<void> _stepSubtitleToNow({required bool previous}) async {
    final targetPlayer = widget.player;
    final propertyName = widget.propertyName;
    if (!targetPlayer.supportsSubtitleStepSync ||
        (propertyName != PlayerSyncOffsets.subtitleProperty &&
            propertyName != PlayerSyncOffsets.secondarySubtitleProperty)) {
      return;
    }

    final persistOffset = widget.onOffsetChanged;
    final coordinator = playerSyncWrites[targetPlayer] ??= LatestAsyncWrite<String>();
    final writeToken = coordinator.begin(propertyName);
    final generation = ++_writeGeneration;
    final bindingGeneration = _bindingGeneration;
    var rollbackOffset = _confirmedOffset.round();

    unawaited(() async {
      try {
        final committed = await coordinator.commitIfLatest(propertyName, writeToken, () async {
          rollbackOffset = _confirmedOffset.round();
          try {
            final skip = previous ? '-1' : '1';
            final track = propertyName == PlayerSyncOffsets.secondarySubtitleProperty ? 'secondary' : 'primary';
            await _commandFor(bindingGeneration, targetPlayer, ['sub-step', skip, track]);

            final rawDelay = await _getFor(bindingGeneration, targetPlayer, propertyName);
            final seconds = double.tryParse(rawDelay ?? '');
            if (seconds == null || !seconds.isFinite) {
              throw StateError('The player did not return a subtitle delay after stepping the cue.');
            }
            final offsetMs = (seconds * 1000).round();
            if (offsetMs < _absoluteMin || offsetMs > _absoluteMax) {
              throw RangeError.range(offsetMs, _absoluteMin.toInt(), _absoluteMax.toInt(), 'subtitleOffsetMs');
            }

            PlayerSyncOffsets.of(targetPlayer).recordApplied(propertyName, offsetMs);
            _checkBinding(bindingGeneration, targetPlayer);
            await persistOffset(offsetMs);
            _confirmedOffset = offsetMs.toDouble();
            if (propertyName == PlayerSyncOffsets.subtitleProperty) {
              _undoSubtitleCalibration = null;
            }
          } catch (_) {
            try {
              await _setFor(bindingGeneration, targetPlayer, propertyName, (rollbackOffset / 1000.0).toString());
              PlayerSyncOffsets.of(targetPlayer).recordApplied(propertyName, rollbackOffset);
            } catch (rollbackError, rollbackStackTrace) {
              appLogger.w(
                'Could not restore subtitle timing after sync failed',
                error: rollbackError,
                stackTrace: rollbackStackTrace,
              );
            }
            rethrow;
          }
        });
        if (!committed ||
            !mounted ||
            generation != _writeGeneration ||
            bindingGeneration != _bindingGeneration ||
            targetPlayer != widget.player ||
            propertyName != widget.propertyName) {
          return;
        }
        setState(() => _currentOffset = _confirmedOffset);
      } catch (error, stackTrace) {
        appLogger.w('Could not sync subtitle to the current playback time', error: error, stackTrace: stackTrace);
        if (!mounted ||
            generation != _writeGeneration ||
            bindingGeneration != _bindingGeneration ||
            targetPlayer != widget.player ||
            propertyName != widget.propertyName) {
          return;
        }
        setState(() => _currentOffset = _confirmedOffset);
      }
    }());
  }

  SubtitleTrack? get _selectedSubtitle => widget.propertyName == PlayerSyncOffsets.secondarySubtitleProperty
      ? widget.player.state.track.secondarySubtitle : widget.player.state.track.subtitle;

  bool get _canInspectSubtitle => widget.allowFileTools && widget.player.supportsSubtitleStepSync &&
      widget.propertyName != PlayerSyncOffsets.audioProperty && SubtitleCueDocument.format(_selectedSubtitle) != null;

  Future<void> _openSelectedSubtitle({bool export = false}) async {
    if (!_canInspectSubtitle || _fileToolBusy) return;
    final player = widget.player, generation = _bindingGeneration;
    final property = widget.propertyName;
    final track = _selectedSubtitle!;
    void check() => _checkBinding(generation, player);
    setState(() => _fileToolBusy = true);
    try {
      await playerSyncWrites[player]?.settled(property);
      check();
      final document = await SubtitleCueDocument.read(track, checkCurrent: check);
      check();
      final rate = _confirmedSubtitleRate, delay = _confirmedOffset.round();
      if (export) {
        final result = SubtitleRetimer.retime(sourceBytes: document.bytes,
          extension: document.extension, delayMs: delay, rate: rate);
        if (result.clippedCueCount > 0) {
          final accepted = await showConfirmDialog(context, title: t.videoSettings.subtitleExport,
            message: t.videoSettings.subtitleExportClipped, confirmText: t.common.confirm);
          check();
          if (!accepted) return;
        }
        final bytes = document.exportBundle(result, delayMs: delay, rate: rate,
          itemOffsetMs: player.timelineOffset.inMilliseconds,
          lane: property == PlayerSyncOffsets.secondarySubtitleProperty ? 'secondary' : 'primary');
        check();
        final saved = await FilePickerService.instance.saveFile(dialogTitle: t.videoSettings.subtitleExport,
          fileName: 'PlezyNG_synchronized_subtitle.zip', bytes: bytes,
          type: FileType.custom, allowedExtensions: const ['zip']);
        if (saved != null) await SubtitleCueDocument.finishExport(saved, bytes);
        if (mounted && saved != null) showSnackBar(context, t.videoSettings.subtitleExportSuccess);
        return;
      }
      final selection = await showModalBottomSheet<({SubtitleCue cue, int playbackPositionMs})>(
        context: context, isScrollControlled: true, useSafeArea: true,
        builder: (_) => SubtitleCuePickerSheet(cues: document.cues, positions: player.streams.position,
          currentPositionMs: () => (player.currentPosition - player.timelineOffset).inMilliseconds,
          isCurrent: () => mounted && generation == _bindingGeneration && _sourceCurrent(),
          initialDelayMs: delay, initialRate: rate));
      if (selection == null) return;
      check();
      final offset = selection.playbackPositionMs - (selection.cue.startMs * rate).round();
      if (offset < _absoluteMin || offset > _absoluteMax) throw const FormatException('Cue correction exceeds the timing limit.');
      if (_canUseSubtitleDriftCorrection) {
        await _saveSubtitleCalibrationWithUndo(SubtitleSyncCalibration(timestampMultiplier: rate, delayMs: offset),
          anchors: [SubtitleSyncAnchor(selection.cue.startMs / 1000, selection.playbackPositionMs / 1000)]);
      } else {
        setState(() => _currentOffset = offset.toDouble());
        _applyOffset(offset.toDouble());
      }
    } catch (_) {
      // Transport exceptions can contain signed URLs. Show only bounded, generic
      // feedback, never the remote location or its credentials.
      if (mounted) showErrorSnackBar(context,
        export ? t.videoSettings.subtitleExportFailed : t.videoSettings.subtitleCueUnavailable);
    } finally { if (mounted) setState(() => _fileToolBusy = false); }
  }

  LibrarySyncBinding? get _transferBinding => widget.propertyName == PlayerSyncOffsets.audioProperty || !_sourceCurrent()
      ? null : PlayerSyncOffsets.of(widget.player).binding(widget.propertyName);

  Future<void> _openTimingTransfer() async {
    final binding = _transferBinding;
    if (binding == null || _fileToolBusy) return;
    final player = widget.player, generation = _bindingGeneration;
    setState(() => _fileToolBusy = true);
    try {
      await playerSyncWrites[player]?.settled(widget.propertyName);
      _checkBinding(generation, player); binding.checkCurrent();
      await showDialog<void>(context: context, builder: (_) => SubtitleTimingTransferDialog(binding: binding,
        currentValue: LibrarySyncValue(delayMs: _confirmedOffset.round(),
          rate: widget.propertyName == PlayerSyncOffsets.subtitleProperty ? _confirmedSubtitleRate : 1),
        isCurrent: () => mounted && generation == _bindingGeneration && _sourceCurrent()));
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.videoSettings.subtitleTimingTransferFailed);
    } finally { if (mounted) setState(() => _fileToolBusy = false); }
  }

  Widget _fileToolButton({required bool export}) {
    final label = export ? t.videoSettings.subtitleExport : t.videoSettings.subtitleUsePlaybackTime;
    return IconButton(tooltip: label, onPressed: _fileToolBusy ? null : () => _openSelectedSubtitle(export: export),
      icon: Icon(export ? Icons.file_download_outlined : Icons.playlist_add_check));
  }

  bool get _canUseSubtitleDriftCorrection =>
      widget.player.supportsSubtitleStepSync &&
      widget.propertyName == PlayerSyncOffsets.subtitleProperty &&
      widget.onSubtitleRateChanged != null;

  bool get _supportsSubtitleDriftCalibration {
    if (!_canUseSubtitleDriftCorrection) return false;
    final subtitle = widget.player.state.track.subtitle;
    if (subtitle == null || subtitle.id == SubtitleTrack.off.id) return false;
    final codec = subtitle.codec?.toLowerCase() ?? '';
    final imageSubtitle =
        codec.contains('pgs') ||
        codec.contains('dvd_subtitle') ||
        codec.contains('vobsub') ||
        codec.contains('dvb_subtitle') ||
        codec.contains('dvb_teletext') ||
        codec == 'xsub';
    return !imageSubtitle;
  }

  ({String profile, String key})? get _historyScope {
    final profile = SubtitleSelectionRules.activeProfileId, identity = widget.contentIdentity;
    if (profile == null || identity == null || identity.isEmpty || !_sourceCurrent()) return null;
    final player = widget.player;
    return (profile: profile, key: LibrarySyncSource.digestOf([
      'native-calibration-v1', identity, player.playerType, widget.propertyName,
      player.timelineOffset.inMilliseconds, LibrarySyncSource.audio(player.state.track.audio),
      LibrarySyncSource.subtitle(_selectedSubtitle),
    ]));
  }

  Future<void> _openSubtitleDriftCalibration() async {
    if (!_supportsSubtitleDriftCalibration || !_sourceCurrent()) return;
    final target = widget.player, generation = _bindingGeneration;
    final scope = _historyScope;
    var previewApplied = false, rollbackStarted = false, closed = false;
    Future<void> rollbackOnce() async {
      if (!previewApplied || rollbackStarted) return;
      rollbackStarted = true;
      await _rollbackSubtitlePreview();
    }
    final choice = await showDialog<SubtitleCalibrationChoice>(context: context,
      barrierDismissible: false,
      builder: (_) => SubtitleCalibrationDialog(
        history: scope == null ? const [] : SubtitleCalibrationHistory.read(scope.profile, scope.key),
        currentPositionSeconds: () => (target.currentPosition - target.timelineOffset).inMicroseconds / Duration.microsecondsPerSecond,
        isCurrent: () => mounted && generation == _bindingGeneration && target == widget.player && _sourceCurrent(),
        preview: (candidate) async {
          if (!mounted || generation != _bindingGeneration || target != widget.player || !_sourceCurrent()) return false;
          final applied = await _previewSubtitleCalibration(candidate);
          previewApplied = applied;
          rollbackStarted = false;
          if (closed) await rollbackOnce();
          return applied;
        }, rollback: rollbackOnce));
    closed = true;
    if (choice == null) { await rollbackOnce(); return; }
    if (!mounted || generation != _bindingGeneration || target != widget.player || !_sourceCurrent()) return;
    setState(() { _currentOffset = choice.value.delayMs.toDouble(); _currentSubtitleRate = choice.value.timestampMultiplier; });
    await _saveSubtitleCalibrationWithUndo(choice.value, anchors: choice.anchors);
  }

  Future<void> _saveSubtitleCalibrationWithUndo(SubtitleSyncCalibration calibration,
      {List<SubtitleSyncAnchor> anchors = const []}) async {
    final scope = _historyScope;
    final sourceCurrent = _sourceCurrent;
    final target = widget.player;
    final identity = widget.contentIdentity;
    void checkHistory() {
      if (!mounted || target != widget.player || identity != widget.contentIdentity || !sourceCurrent() ||
          scope != _historyScope) throw StateError('Calibration history context changed.');
    }
    final previous = SubtitleSyncCalibration(
      timestampMultiplier: _confirmedSubtitleRate,
      delayMs: _confirmedOffset.round(),
    );
    final changed =
        previous.delayMs != calibration.delayMs ||
        (previous.timestampMultiplier - calibration.timestampMultiplier).abs() > 0.001;
    await _applySubtitleCalibration(calibration);
    if (!mounted) return;
    final applied =
        _confirmedOffset.round() == calibration.delayMs &&
        (_confirmedSubtitleRate - calibration.timestampMultiplier).abs() <= 0.001;
    setState(() => _undoSubtitleCalibration = changed && applied ? previous : null);
    if (scope != null && applied && (changed || anchors.isNotEmpty)) {
      try {
        await SubtitleCalibrationHistory.append(scope.profile, scope.key, previous, calibration, anchors,
          checkCurrent: checkHistory);
      } catch (_) {
        if (mounted && sourceCurrent()) showErrorSnackBar(context, t.videoSettings.subtitleCalibrationHistoryFailed);
      }
    }
  }

  Future<void> _undoLastSubtitleCalibration() async {
    final previous = _undoSubtitleCalibration;
    if (previous == null) return;
    setState(() {
      _currentOffset = previous.delayMs.toDouble();
      _currentSubtitleRate = previous.timestampMultiplier;
    });
    await _applySubtitleCalibration(previous);
    if (!mounted) return;
    final restored =
        _confirmedOffset.round() == previous.delayMs &&
        (_confirmedSubtitleRate - previous.timestampMultiplier).abs() <= 0.001;
    if (restored) setState(() => _undoSubtitleCalibration = null);
  }

  Future<bool> _previewSubtitleCalibration(SubtitleSyncCalibration calibration) async {
    if (!_canUseSubtitleDriftCorrection) return false;

    final targetPlayer = widget.player;
    final propertyName = widget.propertyName;
    final coordinator = playerSyncWrites[targetPlayer] ??= LatestAsyncWrite<String>();
    final writeToken = coordinator.begin(propertyName);
    final generation = ++_writeGeneration;
    final bindingGeneration = _bindingGeneration;
    var rollbackOffset = _confirmedOffset.round();
    var rollbackRate = _confirmedSubtitleRate;

    try {
      final committed = await coordinator.commitIfLatest(propertyName, writeToken, () async {
        rollbackOffset = _confirmedOffset.round();
        rollbackRate = _confirmedSubtitleRate;
        final offsets = PlayerSyncOffsets.of(targetPlayer);
        try {
          await _setFor(
            bindingGeneration, targetPlayer,
            PlayerSyncOffsets.subtitleRateProperty,
            calibration.timestampMultiplier.toStringAsFixed(6),
          );
          await _setFor(bindingGeneration, targetPlayer, propertyName, (calibration.delayMs / 1000.0).toString());

          final appliedRate = double.tryParse(
            await _getFor(bindingGeneration, targetPlayer, PlayerSyncOffsets.subtitleRateProperty) ?? '',
          );
          final appliedDelay = double.tryParse(await _getFor(bindingGeneration, targetPlayer, propertyName) ?? '');
          if (appliedRate == null ||
              !appliedRate.isFinite ||
              appliedDelay == null ||
              !appliedDelay.isFinite ||
              (appliedRate - calibration.timestampMultiplier).abs() > 0.001 ||
              (appliedDelay * 1000 - calibration.delayMs).abs() > 2) {
            throw StateError('The player did not apply the subtitle preview.');
          }

          offsets.recordSubtitleRate(appliedRate);
          offsets.recordApplied(propertyName, (appliedDelay * 1000).round());
        } catch (_) {
          try {
            await _setFor(bindingGeneration, targetPlayer, PlayerSyncOffsets.subtitleRateProperty, rollbackRate.toStringAsFixed(6));
            await _setFor(bindingGeneration, targetPlayer, propertyName, (rollbackOffset / 1000.0).toString());
            offsets.recordSubtitleRate(rollbackRate);
            offsets.recordApplied(propertyName, rollbackOffset);
          } catch (rollbackError, rollbackStackTrace) {
            appLogger.w(
              'Could not restore subtitle timing after drift preview failed',
              error: rollbackError,
              stackTrace: rollbackStackTrace,
            );
          }
          rethrow;
        }
      });
      if (!committed ||
          !mounted ||
          generation != _writeGeneration ||
          bindingGeneration != _bindingGeneration ||
          targetPlayer != widget.player ||
          propertyName != widget.propertyName) {
        return false;
      }
      setState(() {
        _currentOffset = calibration.delayMs.toDouble();
        _currentSubtitleRate = calibration.timestampMultiplier;
      });
      return true;
    } catch (error, stackTrace) {
      appLogger.w('Failed to preview subtitle drift correction', error: error, stackTrace: stackTrace);
      if (mounted &&
          generation == _writeGeneration &&
          bindingGeneration == _bindingGeneration &&
          targetPlayer == widget.player &&
          propertyName == widget.propertyName) {
        setState(() {
          _currentOffset = _confirmedOffset;
          _currentSubtitleRate = _confirmedSubtitleRate;
        });
      }
      return false;
    }
  }

  Future<void> _rollbackSubtitlePreview() async {
    if (!_canUseSubtitleDriftCorrection) return;

    final targetPlayer = widget.player;
    final propertyName = widget.propertyName;
    final coordinator = playerSyncWrites[targetPlayer] ??= LatestAsyncWrite<String>();
    final writeToken = coordinator.begin(propertyName);
    final generation = ++_writeGeneration;
    final bindingGeneration = _bindingGeneration;
    final offset = _confirmedOffset.round();
    final rate = _confirmedSubtitleRate;

    try {
      final committed = await coordinator.commitIfLatest(propertyName, writeToken, () async {
        await _setFor(bindingGeneration, targetPlayer, PlayerSyncOffsets.subtitleRateProperty, rate.toStringAsFixed(6));
        await _setFor(bindingGeneration, targetPlayer, propertyName, (offset / 1000.0).toString());
        final offsets = PlayerSyncOffsets.of(targetPlayer);
        offsets.recordSubtitleRate(rate);
        offsets.recordApplied(propertyName, offset);
      });
      if (!committed ||
          !mounted ||
          generation != _writeGeneration ||
          bindingGeneration != _bindingGeneration ||
          targetPlayer != widget.player ||
          propertyName != widget.propertyName) {
        return;
      }
      setState(() {
        _currentOffset = offset.toDouble();
        _currentSubtitleRate = rate;
      });
    } catch (error, stackTrace) {
      appLogger.w('Failed to undo subtitle drift preview', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _applySubtitleCalibration(SubtitleSyncCalibration calibration) async {
    if (!_canUseSubtitleDriftCorrection) return;

    final targetPlayer = widget.player;
    final propertyName = widget.propertyName;
    final persistOffset = widget.onOffsetChanged;
    final persistRate = widget.onSubtitleRateChanged!;
    final coordinator = playerSyncWrites[targetPlayer] ??= LatestAsyncWrite<String>();
    final writeToken = coordinator.begin(propertyName);
    final generation = ++_writeGeneration;
    final bindingGeneration = _bindingGeneration;
    var rollbackOffset = _confirmedOffset.round();
    var rollbackRate = _confirmedSubtitleRate;

    try {
      final committed = await coordinator.commitIfLatest(propertyName, writeToken, () async {
        rollbackOffset = _confirmedOffset.round();
        rollbackRate = _confirmedSubtitleRate;
        final offsets = PlayerSyncOffsets.of(targetPlayer);
        try {
          await _setFor(
            bindingGeneration, targetPlayer,
            PlayerSyncOffsets.subtitleRateProperty,
            calibration.timestampMultiplier.toStringAsFixed(6),
          );
          await _setFor(bindingGeneration, targetPlayer, propertyName, (calibration.delayMs / 1000.0).toString());

          final appliedRate = double.tryParse(
            await _getFor(bindingGeneration, targetPlayer, PlayerSyncOffsets.subtitleRateProperty) ?? '',
          );
          final appliedDelay = double.tryParse(await _getFor(bindingGeneration, targetPlayer, propertyName) ?? '');
          if (appliedRate == null ||
              !appliedRate.isFinite ||
              appliedDelay == null ||
              !appliedDelay.isFinite ||
              (appliedRate - calibration.timestampMultiplier).abs() > 0.001 ||
              (appliedDelay * 1000 - calibration.delayMs).abs() > 2) {
            throw StateError('The player did not apply the subtitle drift correction.');
          }

          final appliedOffsetMs = (appliedDelay * 1000).round();
          offsets.recordSubtitleRate(appliedRate);
          offsets.recordApplied(propertyName, appliedOffsetMs);
          _checkBinding(bindingGeneration, targetPlayer);
          await persistRate(appliedRate);
          _checkBinding(bindingGeneration, targetPlayer);
          await persistOffset(appliedOffsetMs);
          _confirmedOffset = appliedOffsetMs.toDouble();
          _confirmedSubtitleRate = appliedRate;
        } catch (_) {
          try {
            await _setFor(bindingGeneration, targetPlayer, PlayerSyncOffsets.subtitleRateProperty, rollbackRate.toStringAsFixed(6));
            await _setFor(bindingGeneration, targetPlayer, propertyName, (rollbackOffset / 1000.0).toString());
            offsets.recordSubtitleRate(rollbackRate);
            offsets.recordApplied(propertyName, rollbackOffset);
          } catch (rollbackError, rollbackStackTrace) {
            appLogger.w(
              'Could not restore subtitle timing after drift calibration failed',
              error: rollbackError,
              stackTrace: rollbackStackTrace,
            );
          }
          try {
            _checkBinding(bindingGeneration, targetPlayer);
            await persistRate(rollbackRate);
            _checkBinding(bindingGeneration, targetPlayer);
            await persistOffset(rollbackOffset);
          } catch (rollbackError, rollbackStackTrace) {
            appLogger.w(
              'Could not restore saved subtitle timing after drift calibration failed',
              error: rollbackError,
              stackTrace: rollbackStackTrace,
            );
          }
          rethrow;
        }
      });

      if (!committed ||
          !mounted ||
          generation != _writeGeneration ||
          bindingGeneration != _bindingGeneration ||
          targetPlayer != widget.player ||
          propertyName != widget.propertyName) {
        return;
      }
      setState(() {
        _currentOffset = _confirmedOffset;
        _currentSubtitleRate = _confirmedSubtitleRate;
      });
    } catch (error, stackTrace) {
      appLogger.w('Could not calibrate subtitle drift', error: error, stackTrace: stackTrace);
      if (!mounted ||
          generation != _writeGeneration ||
          bindingGeneration != _bindingGeneration ||
          targetPlayer != widget.player ||
          propertyName != widget.propertyName) {
        return;
      }
      setState(() {
        _currentOffset = _confirmedOffset;
        _currentSubtitleRate = _confirmedSubtitleRate;
      });
    }
  }

  Widget _buildSubtitleDriftButton() {
    final label = t.videoSettings.subtitleDriftCalibration;
    final value = formatPercent(_currentSubtitleRate);
    return FocusableWrapper(
      onSelect: _openSubtitleDriftCalibration,
      borderRadius: 8,
      autoScroll: false,
      useBackgroundFocus: true,
      child: Tooltip(
        message: '$label · $value',
        child: Semantics(
          button: true,
          label: label,
          value: value,
          child: GestureDetector(
            onTap: _openSubtitleDriftCalibration,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: AppIcon(Symbols.speed_rounded, color: tokens(context).text, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUndoSubtitleDriftButton() {
    final label = t.videoSettings.subtitleDriftUndo;
    return FocusableWrapper(
      onSelect: _undoLastSubtitleCalibration,
      borderRadius: 8,
      autoScroll: false,
      useBackgroundFocus: true,
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            onTap: _undoLastSubtitleCalibration,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: AppIcon(Symbols.undo_rounded, color: tokens(context).text, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitleStepButton({required bool previous}) {
    final label = previous ? t.videoSettings.subtitlePreviousCue : t.videoSettings.subtitleNextCue;
    return FocusableWrapper(
      onSelect: () => _stepSubtitleToNow(previous: previous),
      borderRadius: 18,
      autoScroll: false,
      useBackgroundFocus: true,
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            onTap: () => _stepSubtitleToNow(previous: previous),
            child: Container(
              width: 148,
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(
                    previous ? Symbols.keyboard_arrow_left_rounded : Symbols.keyboard_arrow_right_rounded,
                    color: tokens(context).text,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _resetOffset() {
    if (_canUseSubtitleDriftCorrection) {
      final reset = const SubtitleSyncCalibration(timestampMultiplier: 1.0, delayMs: 0);
      setState(() {
        _currentOffset = 0;
        _currentSubtitleRate = 1.0;
      });
      unawaited(_saveSubtitleCalibrationWithUndo(reset));
      return;
    }
    setState(() {
      _currentOffset = 0;
    });
    _applyOffset(0);
  }

  void _incrementOffset() {
    final newOffset = (_currentOffset + _step).clamp(_absoluteMin, _absoluteMax);
    setState(() {
      _currentOffset = newOffset;
    });
    _applyOffset(newOffset);
  }

  void _decrementOffset() {
    final newOffset = (_currentOffset - _step).clamp(_absoluteMin, _absoluteMax);
    setState(() {
      _currentOffset = newOffset;
    });
    _applyOffset(newOffset);
  }

  void _startLongPressIncrement() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final newOffset = (_currentOffset + _longPressStep).clamp(_absoluteMin, _absoluteMax);
      setState(() {
        _currentOffset = newOffset;
      });
      _applyOffset(newOffset);
    });
  }

  void _startLongPressDecrement() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final newOffset = (_currentOffset - _longPressStep).clamp(_absoluteMin, _absoluteMax);
      setState(() {
        _currentOffset = newOffset;
      });
      _applyOffset(newOffset);
    });
  }

  void _stopLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  String get _syncTitle => widget.propertyName != PlayerSyncOffsets.audioProperty
      ? t.videoSettings.subtitleSync
      : t.videoSettings.audioSync;

  Future<void> _editExactOffset() async {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController(text: _currentOffset.round().toString());
    final offset = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        void submit() {
          if (!(formKey.currentState?.validate() ?? false)) return;
          Navigator.of(dialogContext).pop(int.parse(controller.text.trim()));
        }

        return AlertDialog(
          title: Text(_syncTitle),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: _syncTitle,
                hintText: formatSyncOffset(_currentOffset),
                helperText: t.settings.validationErrorDuration(
                  min: ScopedPlayerPrefs.minimumSyncOffsetMs,
                  max: ScopedPlayerPrefs.maximumSyncOffsetMs,
                  unit: 'ms',
                ),
                suffixText: 'ms',
              ),
              validator: (value) {
                final parsed = int.tryParse(value?.trim() ?? '');
                if (parsed == null) return t.settings.validationErrorEnterNumber;
                if (parsed < ScopedPlayerPrefs.minimumSyncOffsetMs || parsed > ScopedPlayerPrefs.maximumSyncOffsetMs) {
                  return t.settings.validationErrorDuration(
                    min: ScopedPlayerPrefs.minimumSyncOffsetMs,
                    max: ScopedPlayerPrefs.maximumSyncOffsetMs,
                    unit: 'ms',
                  );
                }
                return null;
              },
              onFieldSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.cancel)),
            TextButton(onPressed: submit, child: Text(t.common.save)),
          ],
        );
      },
    );
    controller.dispose();
    if (!mounted || offset == null) return;
    setState(() => _currentOffset = offset.toDouble());
    _applyOffset(offset.toDouble());
  }

  Widget _buildExactOffsetButton() {
    return FocusableWrapper(
      onSelect: _editExactOffset,
      borderRadius: 8,
      autoScroll: false,
      useBackgroundFocus: true,
      child: Semantics(
        button: true,
        label: _syncTitle,
        value: formatSyncOffset(_currentOffset),
        child: GestureDetector(
          onTap: _editExactOffset,
          child: Container(
            width: 80,
            height: 36,
            alignment: Alignment.center,
            child: Text(
              formatSyncOffset(_currentOffset),
              style: TextStyle(fontSize: 16, fontWeight: .bold, color: Theme.of(context).colorScheme.primary),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required VoidCallback onLongPressStart,
  }) {
    return FocusableWrapper(
      onSelect: onTap,
      semanticLabel: label,
      semanticValue: formatSyncOffset(_currentOffset),
      borderRadius: 18,
      autoScroll: false,
      useBackgroundFocus: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPressStart: (_) => onLongPressStart(),
        onLongPressEnd: (_) => _stopLongPress(),
        onLongPressCancel: _stopLongPress,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: AppIcon(icon, color: tokens(context).text, size: 22),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sliderValue = _currentOffset.clamp(_sliderMin, _sliderMax);
    final canReset = _currentOffset != 0 ||
        (_canUseSubtitleDriftCorrection && (_currentSubtitleRate - 1).abs() > 0.000000001);
    final supportsCueSync =
        widget.player.supportsSubtitleStepSync &&
        (widget.propertyName == PlayerSyncOffsets.subtitleProperty ||
            widget.propertyName == PlayerSyncOffsets.secondarySubtitleProperty);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _buildStepButton(
                icon: Symbols.remove_rounded,
                label: t.accessibility.decreaseValue(label: _syncTitle),
                onTap: _decrementOffset,
                onLongPressStart: _startLongPressDecrement,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(tickMarkShape: SliderTickMarkShape.noTickMark),
                  child: FocusableSlider(
                    focusNode: widget.sliderFocusNode,
                    semanticLabel: _syncTitle,
                    semanticFormatterCallback: formatSyncOffset,
                    value: sliderValue,
                    min: _sliderMin,
                    max: _sliderMax,
                    divisions: _sliderDivisions,
                    activeColor: Theme.of(context).colorScheme.primary,
                    inactiveColor: Theme.of(context).colorScheme.outlineVariant,
                    onSelect: widget.closeFocusNode?.requestFocus,
                    onChanged: (value) => setState(() => _currentOffset = value),
                    onChangeEnd: _applyOffset,
                  ),
                ),
              ),
              _buildStepButton(
                icon: Symbols.add_rounded,
                label: t.accessibility.increaseValue(label: _syncTitle),
                onTap: _incrementOffset,
                onLongPressStart: _startLongPressIncrement,
              ),
              const SizedBox(width: 12),
              _buildExactOffsetButton(),
              const SizedBox(width: 8),
              FocusableWrapper(
                focusNode: widget.resetFocusNode,
                onSelect: canReset ? _resetOffset : null,
                semanticLabel: '${t.common.reset} · $_syncTitle',
                semanticValue: _canUseSubtitleDriftCorrection
                    ? '${formatSyncOffset(_currentOffset)} · ${formatPercent(_currentSubtitleRate)}'
                    : formatSyncOffset(_currentOffset),
                borderRadius: 18,
                autoScroll: false,
                useBackgroundFocus: true,
                child: Tooltip(
                  message: t.common.reset,
                  child: GestureDetector(
                    onTap: canReset ? _resetOffset : null,
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: .center,
                      child: AppIcon(
                        Symbols.restart_alt_rounded,
                        fill: 1,
                        color: canReset ? tokens(context).text : tokens(context).textMuted,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (supportsCueSync || _transferBinding != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (supportsCueSync) _buildSubtitleStepButton(previous: true),
                  if (supportsCueSync) _buildSubtitleStepButton(previous: false),
                  if (_transferBinding != null) IconButton(tooltip: t.videoSettings.subtitleTimingTransfer,
                    onPressed: _fileToolBusy ? null : _openTimingTransfer, icon: const Icon(Icons.swap_horiz)),
                  if (_canInspectSubtitle) _fileToolButton(export: false),
                  if (_canInspectSubtitle) _fileToolButton(export: true),
                  if (_supportsSubtitleDriftCalibration) _buildSubtitleDriftButton(),
                  if (_undoSubtitleCalibration != null) _buildUndoSubtitleDriftButton(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
