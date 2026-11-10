import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../navigation/profile_navigation_scope.dart';
import '../screens/sources/publication_reader_screen.dart';
import '../screens/sources/source_player_screen.dart';
import '../sources/source_controller.dart';
import '../sources/source_models.dart';
import '../sources/source_playback.dart';
import '../providers/multi_server_provider.dart';
import '../utils/video_player_navigation.dart';
import 'workspace_controller.dart';
import 'workspace_models.dart';

/// An explicit user action resolves identity through the current profile.
/// Snapshot data is never used as a URL, header, token, or playback capability.
Future<bool> resumeWorkspaceSession(
  BuildContext context,
  MultiviewWorkspaceController workspace,
  WorkspaceSessionDescriptor descriptor,
  bool Function() operationCurrent,
) async {
  // The session tray sits beside the nested Navigator, not beneath it.
  // Resolve its profile's route context explicitly to avoid pushing a player
  // above the profile boundary onto the root authentication navigator.
  final routeContext = ProfileNavigationScope.maybeOf(context)?.navigatorKey.currentState?.overlay?.context;
  if (routeContext == null || !routeContext.mounted || !workspace.active || !operationCurrent()) return false;
  if (routeContext.read<MultiviewWorkspaceController>() != workspace) return false;
  final target = descriptor.resume;
  if (target?.kind == WorkspaceResumeKind.source) {
    return _resumeSource(routeContext, workspace, descriptor, operationCurrent);
  }
  if (target == null || target.kind != WorkspaceResumeKind.library || descriptor.kind != MultiviewMediaKind.video) {
    return false;
  }
  final provider = context.read<MultiServerProvider>();
  final client = provider.getClientForServer(ServerId(target.providerId));
  if (client == null) return false;
  final item = await client.fetchItem(target.itemId).timeout(const Duration(seconds: 20));
  if (!context.mounted ||
      !routeContext.mounted ||
      !workspace.active ||
      !operationCurrent() ||
      provider.getClientForServer(ServerId(target.providerId)) != client ||
      item == null ||
      item.id != target.itemId ||
      (item.serverId != null && item.serverId != target.providerId)) {
    return false;
  }
  final opened = Completer<bool>();
  var handedOff = false;
  var expired = false;
  // A profile change fences both resolution and the eventual route. Closing
  // the recovery tray after a successful handoff must not invalidate playback.
  bool current() => workspace.active && !expired && (handedOff || operationCurrent());
  final deadline = Timer(const Duration(seconds: 45), () {
    expired = true;
    if (!opened.isCompleted) opened.complete(false);
  });
  unawaited(
    navigateToVideoPlayer(
      routeContext,
      metadata: item.copyWith(serverId: target.providerId),
      initialPosition: Duration(milliseconds: target.positionMs),
      explicitStartPolicy: true,
      resolveWatchState: false,
      skipCinemaExtras: true,
      skipPreroll: true,
      isLaunchCurrent: current,
      onLaunched: () {
        if (!current()) return;
        handedOff = true;
        if (!opened.isCompleted) opened.complete(true);
      },
    ).then<void>(
      (_) {
        if (!opened.isCompleted) opened.complete(false);
      },
      onError: (Object _, StackTrace _) {
        if (!opened.isCompleted) opened.complete(false);
      },
    ),
  );
  try {
    return await opened.future;
  } finally {
    deadline.cancel();
  }
}

/// Reconstruct the exact selected edition after reauthentication. Reordering,
/// replacement or disappearance must never silently select a different file.
List<PublicationFile>? recoverySourceFiles(SourceEntry entry, WorkspaceResumeTarget target) {
  final identities = target.fileIds.isNotEmpty ? target.fileIds : [if (target.fileId != null) target.fileId!];
  if (identities.isEmpty || identities.length > 256 || identities.toSet().length != identities.length) return null;
  final selected = <PublicationFile>[];
  for (final identity in identities) {
    final matches = entry.files.where((file) => file.fingerprint == identity && !file.sampleOnly).toList();
    if (matches.length != 1) return null;
    selected.add(matches.single);
  }
  return selected;
}

/// Downloaded editions can resume without reaching the provider. Each selected
/// file must pass the existing profile-scoped local-content verification.
Future<SourceEntry?> resolveRecoverySourceEntry({
  required SourceController sources,
  required SourceEntry cached,
  required WorkspaceResumeTarget target,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return null;
  final selected = recoverySourceFiles(cached, target);
  if (selected != null) {
    var offline = true;
    for (final file in selected) {
      if (!isCurrent()) return null;
      try {
        offline = await sources.hasOfflineContent(cached, file);
      } on Object {
        offline = false;
      }
      if (!isCurrent()) return null;
      if (!offline) break;
    }
    if (offline) return cached;
  }
  if (!isCurrent()) return null;
  final fresh = await sources.hydrate(cached).timeout(const Duration(seconds: 20));
  if (!isCurrent() || fresh.key != cached.key) return null;
  return fresh;
}

Future<bool> _resumeSource(
  BuildContext context,
  MultiviewWorkspaceController workspace,
  WorkspaceSessionDescriptor descriptor,
  bool Function() operationCurrent,
) async {
  final target = descriptor.resume!;
  final sources = context.read<SourceController>();
  final playback = context.read<SourcePlayback>();
  final profile = sources.profileId;
  final generation = sources.generation;
  var expired = false;
  bool current() =>
      !expired &&
      context.mounted &&
      workspace.active &&
      operationCurrent() &&
      profile != null &&
      sources.profileId == profile &&
      sources.current(generation) &&
      !sources.blocked;
  if (!current()) return false;
  final deadline = Timer(const Duration(seconds: 45), () => expired = true);
  try {
    await sources.ready;
    if (!current() || !sources.sources.any((source) => source.id == target.providerId && source.profileId == profile)) {
      return false;
    }
    final cached = await sources.repository.entryForRecovery(profile!, target.providerId, target.itemId);
    if (!current() || cached == null) return false;
    final entry = await resolveRecoverySourceEntry(
      sources: sources,
      cached: cached,
      target: target,
      isCurrent: current,
    );
    if (!current() || entry == null) return false;
    final files = recoverySourceFiles(entry, target);
    if (files == null) return false;
    if (descriptor.kind == MultiviewMediaKind.publication || descriptor.kind == MultiviewMediaKind.comic) {
      if (files.length != 1 || !const {SourceItemKind.ebook, SourceItemKind.comic}.contains(files.single.kind)) {
        return false;
      }
      if (!context.mounted) return false;
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => PublicationReaderScreen(entry: entry, file: files.single),
          ),
        ),
      );
      return true;
    }
    final video = descriptor.kind == MultiviewMediaKind.video;
    if ((!video && descriptor.kind != MultiviewMediaKind.music && descriptor.kind != MultiviewMediaKind.audiobook) ||
        files.any(
          (file) => video
              ? file.kind != SourceItemKind.video
              : !const {SourceItemKind.audiobook, SourceItemKind.music}.contains(file.kind),
        ) ||
        playback.active) {
      return false;
    }
    await playback
        .start(
          entry,
          files,
          playbackMode: video ? PublicationMode.watching : PublicationMode.listening,
          onlyIfIdle: true,
          isStartCurrent: current,
        )
        .timeout(const Duration(seconds: 40));
    if (!context.mounted || !current() || playback.entry?.key != entry.key || playback.failure != null) return false;
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const SourcePlayerScreen())));
    return true;
  } finally {
    deadline.cancel();
    expired = true;
  }
}
