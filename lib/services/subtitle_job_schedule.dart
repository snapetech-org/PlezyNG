import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'remote_streams/preparation_scheduler.dart';
import 'subtitle_job_ownership.dart';

/// Serialize OS installation/removal across engines. A producer saves first,
/// then schedules under this gate, so an idle scan cannot cancel newer work.
final class SubtitleJobSchedule {
  static Future<bool> schedule() async {
    final directory = Directory(p.join((await SubtitleJobActivity.root()).path, 'scheduling'));
    for (var attempt = 0; attempt < 20; attempt++) {
      final gate = await SubtitleJobOwnership.acquire(directory);
      if (gate == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      try { return await PreparationScheduler.scheduleSubtitles(); }
      finally { await gate.release(); }
    }
    return false;
  }

  static Future<void> cancelWhenIdle() async {
    final root = await SubtitleJobActivity.root();
    final gate = await SubtitleJobOwnership.acquire(Directory(p.join(root.path, 'scheduling')));
    if (gate == null) return;
    try {
      final authorized = await SubtitleJobActivity.authorizedProfile();
      if (authorized == null) {
        await PreparationScheduler.cancelSubtitles();
        return;
      }
      var profiles = 0;
      await for (final directory in root.list(followLinks: false)) {
        if (directory is! Directory || !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(directory.path))) continue;
        if (p.basename(directory.path) != authorized) continue;
        if (++profiles > 64) return;
        if (await SubtitleJobActivity.isRevoked(p.basename(directory.path))) continue;
        final owner = await SubtitleJobOwnership.acquire(directory);
        if (owner == null) return; // A foreground writer may be adding work.
        try {
          var jobs = 0;
          await for (final job in directory.list(followLinks: false)) {
            if (job is! Directory || !RegExp(r'^\d+_[0-9a-f]{16}$').hasMatch(p.basename(job.path))) continue;
            if (++jobs > 12) return;
            Map<String, dynamic>? record;
            for (final suffix in ['job.json', 'job.json.bak']) {
              final file = File(p.join(job.path, suffix));
              if (!await file.exists() || await file.length() > 65536) continue;
              try { record = jsonDecode(await file.readAsString()) as Map<String, dynamic>; break; } on Object { }
            }
            if (record == null) return;
            if (record['backgroundAllowed'] == true && const {'queued', 'running'}.contains(record['state'])) return;
          }
        } finally { await owner.release(); }
      }
      await PreparationScheduler.cancelSubtitles();
    } on Object {
      // Unreadable state is not proof that no jobs remain.
    } finally { await gate.release(); }
  }
}
