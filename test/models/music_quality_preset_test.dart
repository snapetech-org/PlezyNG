import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/audio_quality_preset.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('music quality uses cellular, remote, then general precedence', () {
    for (final cellular in [false, true]) {
      for (final remote in [false, true]) {
        expect(
          AudioQualityPreset.resolveStreamingDefault(
            generalDefault: AudioQualityPreset.original,
            cellularDefault: AudioQualityPreset.low,
            remoteDefault: AudioQualityPreset.medium,
            onCellularOnly: cellular,
            onRemoteConnection: remote,
          ),
          cellular
              ? AudioQualityPreset.low
              : remote
              ? AudioQualityPreset.medium
              : AudioQualityPreset.original,
        );
      }
    }
    expect(
      AudioQualityPreset.resolveStreamingDefault(
        generalDefault: AudioQualityPreset.high,
        onCellularOnly: true,
        onRemoteConnection: true,
      ),
      AudioQualityPreset.high,
    );
    expect(
      AudioQualityPreset.resolveStreamingDefault(
        generalDefault: AudioQualityPreset.high,
        remoteDefault: AudioQualityPreset.original,
        onCellularOnly: true,
        onRemoteConnection: true,
      ),
      AudioQualityPreset.original,
    );
  });
  test('music network overrides persist independently and default to general', () async {
    resetSharedPreferencesForTest();
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.musicCellularQualityPreset), isNull);
    expect(settings.read(SettingsService.musicRemoteQualityPreset), isNull);
    await settings.write(SettingsService.musicCellularQualityPreset, AudioQualityPreset.low);
    await settings.write(SettingsService.musicRemoteQualityPreset, AudioQualityPreset.original);
    expect(settings.read(SettingsService.musicCellularQualityPreset), AudioQualityPreset.low);
    expect(settings.read(SettingsService.musicRemoteQualityPreset), AudioQualityPreset.original);
    expect(settings.read(SettingsService.musicQualityPreset), AudioQualityPreset.original);
  });
}
