import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:plezy_preparation/plezy_preparation.dart';

/// Installs per-user OS work. No credentials, provider URLs or profile data go
/// into task definitions; the worker reads the encrypted journal at execution.
class PreparationScheduler {
  static Future<bool>? _scheduling;
  static Future<bool>? _subtitleScheduling;
  static Future<bool> scheduleSubtitles() async {
    final pending = _subtitleScheduling ??= _schedule(subtitles: true);
    try { return await pending; }
    finally { if (identical(_subtitleScheduling, pending)) _subtitleScheduling = null; }
  }

  static Future<void> cancelSubtitles() => cancel(subtitles: true);
  static Future<bool> schedule() async {
    // Another engine can remove completed work. Share concurrent requests,
    // never cache installation across later jobs in this foreground engine.
    final pending = _scheduling ??= _schedule();
    try {
      return await pending;
    } finally {
      if (identical(_scheduling, pending)) _scheduling = null;
    }
  }

  static Future<void> cancel({bool subtitles = false}) async {
    final taskName = subtitles ? 'PlezyNG Subtitle Jobs' : 'PlezyNG Preparation';
    final identifier = subtitles ? 'org.plezy.subtitle.jobs' : 'org.plezy.preparation';
    final unit = subtitles ? 'plezy-subtitle-jobs' : 'plezy-preparation';
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await PlezyPreparation.cancel(subtitles: subtitles);
        return;
      }
      if (Platform.isWindows) {
        await Process.run('schtasks', ['/Delete', '/F', '/TN', taskName]);
        return;
      }
      final home = Platform.environment['HOME'];
      if (home == null) return;
      if (Platform.isMacOS) {
        final file = File(p.join(home, 'Library', 'LaunchAgents', '$identifier.plist'));
        final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
        if (await file.exists()) await file.delete();
        // Removing the job may terminate this worker; remove its login
        // definition first so completed work cannot be relaunched at login.
        await Process.run('launchctl', ['bootout', 'gui/$uid/$identifier']);
      } else if (Platform.isLinux) {
        await Process.run('systemctl', ['--user', 'disable', '--now', '$unit.timer']);
      }
    } on Object {
      /* journal remains authoritative if OS removal is unavailable */
    }
  }

  static Future<bool> _schedule({bool subtitles = false}) async {
    final taskName = subtitles ? 'PlezyNG Subtitle Jobs' : 'PlezyNG Preparation';
    final identifier = subtitles ? 'org.plezy.subtitle.jobs' : 'org.plezy.preparation';
    final unit = subtitles ? 'plezy-subtitle-jobs' : 'plezy-preparation';
    final argument = subtitles ? '--plezy-subtitle-worker' : '--plezy-preparation-worker';
    try {
      if (const bool.fromEnvironment('TVOS_BUILD') ||
          const bool.fromEnvironment('PLEZY_WEBOS') ||
          const bool.fromEnvironment('PLEZY_TIZEN')) {
        return false;
      }
      if (Platform.isAndroid || Platform.isIOS) {
        await PlezyPreparation.schedule(subtitles: subtitles);
        return true;
      }
      final executable = Platform.resolvedExecutable;
      if (executable.contains('\n') || executable.contains('"')) return false;
      if (Platform.isWindows) {
        final result = await Process.run('schtasks', [
          '/Create',
          '/F',
          '/TN',
          taskName,
          '/SC',
          'MINUTE',
          '/MO',
          '15',
          '/IT',
          '/RL',
          'LIMITED',
          '/TR',
          '"$executable" $argument',
        ]);
        return result.exitCode == 0;
      }
      final home = Platform.environment['HOME'];
      if (home == null) return false;
      if (Platform.isMacOS) {
        final file = File(p.join(home, 'Library', 'LaunchAgents', '$identifier.plist'));
        await file.parent.create(recursive: true);
        final xmlPath = executable.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
        final definition =
            '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$identifier</string>
<key>ProgramArguments</key><array><string>$xmlPath</string><string>$argument</string></array>
<key>StartInterval</key><integer>900</integer><key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Background</string><key>LowPriorityIO</key><true/>
</dict></plist>''';
        final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
        if (await file.exists() &&
            await file.readAsString() == definition &&
            (await Process.run('launchctl', ['print', 'gui/$uid/$identifier'])).exitCode == 0) {
          return true;
        }
        await file.writeAsString(definition, flush: true);
        await Process.run('launchctl', ['bootout', 'gui/$uid', file.path]);
        return (await Process.run('launchctl', ['bootstrap', 'gui/$uid', file.path])).exitCode == 0;
      }
      if (Platform.isLinux) {
        final directory = Directory(
          p.join(Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config'), 'systemd', 'user'),
        );
        await directory.create(recursive: true);
        final command = executable.replaceAll('\\', '\\\\').replaceAll('%', '%%');
        await File(p.join(directory.path, '$unit.service')).writeAsString('''[Unit]
Description=$taskName
[Service]
Type=oneshot
ExecStart="$command" $argument
TimeoutStartSec=8min
''', flush: true);
        await File(p.join(directory.path, '$unit.timer')).writeAsString('''[Unit]
Description=Resume $taskName
[Timer]
OnStartupSec=1min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
''', flush: true);
        await Process.run('systemctl', [
          '--user',
          'import-environment',
          'DISPLAY',
          'WAYLAND_DISPLAY',
          'XDG_RUNTIME_DIR',
          'DBUS_SESSION_BUS_ADDRESS',
        ]);
        if ((await Process.run('systemctl', ['--user', 'daemon-reload'])).exitCode != 0) return false;
        return (await Process.run('systemctl', ['--user', 'enable', '--now', '$unit.timer'])).exitCode == 0;
      }
    } on MissingPluginException {
      return false;
    } on Object {
      return false;
    }
    return false;
  }
}
