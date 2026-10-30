import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:plezy_preparation/plezy_preparation.dart';

import 'subtitle_job_ownership.dart';
import 'subtitle_job_service.dart';
import 'subtitle_job_schedule.dart';

@pragma('vm:entry-point')
Future<void> subtitleBackgroundEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel('org.plezy/subtitle.worker');
  var stopped = false;
  channel.setMethodCallHandler((call) async {
    if (call.method == 'stop') stopped = true;
  });
  final success = await runSubtitleBackgroundWorker(() => !stopped);
  await channel.invokeMethod<void>('complete', success);
}

Future<bool> runSubtitleBackgroundWorker(bool Function() allowed) async {
  final clock = Stopwatch()..start();
  const budget = Duration(minutes: 5);
  var active = false, probing = false, retired = false;
  final authorizedProfile = await SubtitleJobActivity.authorizedProfile();
  if (authorizedProfile == null) {
    await SubtitleJobSchedule.cancelWhenIdle();
    return true;
  }
  Future<void> refreshActivity() async {
    if (probing) return;
    probing = true;
    try {
      final foreground = await SubtitleJobActivity.foregroundRequested().timeout(const Duration(seconds: 2));
      final mobileAllows = !Platform.isAndroid && !Platform.isIOS ||
          await PlezyPreparation.subtitlesMayRun().timeout(const Duration(seconds: 2));
      if (foreground || !mobileAllows || await SubtitleJobActivity.authorizedProfile() != authorizedProfile) {
        retired = true;
      }
      active = !retired;
    } on Object { active = false; retired = true; }
    finally { probing = false; }
  }
  bool mayRun() => active && allowed() && clock.elapsed < budget;
  Timer? activity;
  SubtitleJobOwnership? worker;
  try {
    await refreshActivity();
    if (!mayRun()) return false;
    final root = await SubtitleJobActivity.root();
    worker = await SubtitleJobOwnership.acquire(Directory(p.join(root.path, 'worker')));
    if (worker == null) return false;
    activity = Timer.periodic(const Duration(milliseconds: 500), (_) { unawaited(refreshActivity()); });
    final deadline = DateTime.now().add(budget - clock.elapsed);
    final finished = await SubtitleJobService.runBackgroundProfile(authorizedProfile, deadline, mayRun);
    if (mayRun()) await SubtitleJobSchedule.cancelWhenIdle();
    return finished;
  } on Object {
    return false;
  } finally {
    active = false;
    activity?.cancel();
    await worker?.release();
  }
}

Future<void> runDesktopSubtitleWorker() async {
  final success = await runSubtitleBackgroundWorker(() => true);
  exit(success ? 0 : 1);
}
