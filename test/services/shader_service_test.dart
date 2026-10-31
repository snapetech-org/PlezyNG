import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/models/shader_preset.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/ambient_lighting_service.dart';
import 'package:plezy/services/shader_asset_loader.dart';
import 'package:plezy/services/shader_service.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late Directory root;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('plezy_shader_service_test_');
    PathProviderPlatform.instance = FakePathProvider(root);
    ShaderAssetLoader.clearCache();
    // The suite exercises mpv's GLSL chain, which the Apple hosts' avfoundation
    // VO does not have.
    ShaderService.debugPlatformSupported = true;
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    ShaderAssetLoader.clearCache();
    ShaderService.debugPlatformSupported = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Iterable<List<String>> replacements(_RecordingPlayer player) =>
      player.commands.where((command) => command.length > 2 && command[2] == 'set');

  test('an escaped custom preset never reaches the MPV shader append command', () async {
    final supportDirectory = Directory(path.join(root.path, 'support'))..createSync(recursive: true);
    final sentinel = File(path.join(supportDirectory.path, 'sentinel.glsl'))..writeAsStringSync('sentinel');
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    const preset = ShaderPreset(
      id: 'custom_traversal',
      name: 'Traversal',
      type: ShaderPresetType.custom,
      fileName: '../sentinel.glsl',
    );

    await service.applyPreset(preset);

    expect(player.commands.where((command) => command.length > 2 && command[2] == 'append'), isEmpty);
    expect(player.commands.single, ['change-list', 'glsl-shaders', 'clr', '']);
    expect(await sentinel.readAsString(), 'sentinel');
  });

  test('replaces a shader preset with one chain update and no empty intermediate chain', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);

    await service.applyPreset(ShaderPreset.nvscalerDefault);
    player.commands.clear();
    final preset = ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeB);

    await service.applyPreset(preset);

    expect(player.commands, hasLength(1));
    expect(player.commands.single, hasLength(4));
    expect(player.commands.single.take(3), ['change-list', 'glsl-shaders', 'set']);
    expect(player.commands.single.last, contains('Anime4K_Clamp_Highlights.glsl'));
    expect(player.commands.single.last, contains('Anime4K_Restore_CNN_M.glsl'));
    expect(player.commands.single.last, contains('Anime4K_Upscale_CNN_x2_M.glsl'));
    expect(service.currentPreset, preset);
  });

  test('retains ambient lighting as the final shader in a replacement chain', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    final ambient = AmbientLightingService(player);
    service.ambientLightingService = ambient;

    await ambient.enable(16 / 9);
    final ambientPath = player.commands.singleWhere((command) => command[2] == 'append').last;
    player.commands.clear();

    await service.applyPreset(ShaderPreset.anime4kPreset(Anime4KQuality.fast, Anime4KMode.modeA));

    expect(player.commands, hasLength(1));
    expect(player.commands.single[2], 'set');
    expect(player.commands.single.last.endsWith(':$ambientPath'), isTrue);
  });

  group('reapplyForContent', () {
    test('drops an NVScaler applied before decode once the frame proves HDR content', () async {
      final player = _RecordingPlayer();
      final service = ShaderService(player);

      // Nothing decoded yet: mpv answers no colour params, so the HDR skip
      // cannot fire and the chain gets NVScaler.
      await service.applyPreset(ShaderPreset.nvscalerDefault);
      expect(replacements(player), hasLength(1));
      expect(service.currentPreset, ShaderPreset.nvscalerDefault);

      player.properties['video-params/colormatrix'] = 'bt.2020-ncl';
      player.commands.clear();

      expect(await service.reapplyForContent(), isTrue);
      expect(player.commands, [
        ['change-list', 'glsl-shaders', 'clr', ''],
      ]);
      expect(service.currentPreset, ShaderPreset.none);
    });

    test('brings a skipped NVScaler back when the next item is SDR', () async {
      final player = _RecordingPlayer()..properties['video-params/primaries'] = 'bt.2020';
      final service = ShaderService(player);

      await service.applyPreset(ShaderPreset.nvscalerDefault);
      expect(replacements(player), isEmpty);
      expect(service.currentPreset, ShaderPreset.none);

      player.properties['video-params/primaries'] = 'bt.709';
      player.commands.clear();

      expect(await service.reapplyForContent(), isTrue);
      expect(replacements(player), hasLength(1));
      expect(service.currentPreset, ShaderPreset.nvscalerDefault);
    });

    test('leaves the chain alone when the decision stands', () async {
      final player = _RecordingPlayer();
      final service = ShaderService(player);

      await service.applyPreset(ShaderPreset.nvscalerDefault);
      player.commands.clear();

      expect(await service.reapplyForContent(), isFalse);
      expect(player.commands, isEmpty);
    });

    test('does not resurrect a preset the viewer switched off', () async {
      final player = _RecordingPlayer()..properties['video-params/primaries'] = 'bt.2020';
      final service = ShaderService(player);

      await service.applyPreset(ShaderPreset.nvscalerDefault);
      await service.applyPreset(ShaderPreset.none);
      player.properties['video-params/primaries'] = 'bt.709';
      player.commands.clear();

      expect(await service.reapplyForContent(), isFalse);
      expect(player.commands, isEmpty);
      expect(service.currentPreset, ShaderPreset.none);
    });
  });
}

class _RecordingPlayer implements Player {
  final commands = <List<String>>[];

  /// mpv property answers; anything absent is unavailable (null), which is
  /// what a core answers before it has decoded a frame.
  final properties = <String, String>{};

  @override
  String get playerType => 'mpv';

  @override
  Future<void> command(List<String> args) async {
    commands.add(List.unmodifiable(args));
  }

  @override
  Future<void> setProperty(String name, String value) async {
    properties[name] = value;
  }

  @override
  Future<String?> getProperty(String name) async => properties[name];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
