import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
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
  final target = descriptor.resume;
  if (target == null || target.kind != WorkspaceResumeKind.library || descriptor.kind != MultiviewMediaKind.video) {
    return false;
  }
  final provider = context.read<MultiServerProvider>();
  final client = provider.getClientForServer(ServerId(target.providerId));
  if (client == null) return false;
  final item = await client.fetchItem(target.itemId).timeout(const Duration(seconds: 20));
  if (!context.mounted ||
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
      context,
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
