import 'romm_core_catalog.dart';
import 'romm_models.dart';

class RommCapabilities {
  const RommCapabilities({this.version = '', this.emulation = const {}, this.config = const {},
    this.streams = const [], this.platforms = const [], this.scopes = const [], this.observedAt});
  final String version;
  final Map<String, dynamic> emulation, config;
  final List<Map<String, dynamic>> streams, platforms;
  final List<String> scopes;
  final DateTime? observedAt;
  bool get fresh {
    if (observedAt == null) return false;
    final age = DateTime.now().difference(observedAt!);
    return !age.isNegative && age < const Duration(minutes: 5);
  }
  String slug(RommGame game) => rommString(rommMap(config['PLATFORMS_VERSIONS'])[game.platform], 128).isEmpty
      ? game.platform : rommString(rommMap(config['PLATFORMS_VERSIONS'])[game.platform], 128);
  List<RommRoute> routes(RommGame game, {required bool browserAvailable, Set<String> nativeCores = const {}, bool offlineAvailable = false, String offlineFileName = ''}) {
    if (!game.hasBytes && !offlineAvailable) return const [];
    final platform = slug(game);
    final result = <RommRoute>[];
    void web(RommEngine engine, String flag, bool eligible, {String core = '', bool permitted = true}) {
      if (game.hasBytes && eligible && emulation[flag] == false) result.add(RommRoute(engine, core: core,
        available: browserAvailable && fresh && permitted, reason: !browserAvailable ? 'romm.browserUnavailable'
          : !permitted ? 'romm.permissionDenied'
          : !fresh ? 'romm.refreshBeforePlay' : ''));
    }
    final cores = (config['EJS_NETPLAY_ENABLED'] == true ? rommNightlyBrowserCores[platform] : null) ?? rommBrowserCores[platform] ?? const <String>[];
    final preferred = rommString(rommMap(config['EJS_DEFAULT_CORES'])[platform], 128);
    web(RommEngine.emulatorJs, 'DISABLE_EMULATOR_JS', cores.isNotEmpty,
      core: cores.contains(preferred) ? preferred : cores.firstOrNull ?? '', permitted: scopes.contains('firmware.read'));
    web(RommEngine.ruffle, 'DISABLE_RUFFLE_RS', {'flash', 'browser'}.contains(platform) && game.extension == 'swf');
    web(RommEngine.jsDos, 'DISABLE_JSDOS', {'win3x', 'win9x'}.contains(platform) && game.extension == 'jsdos');
    web(RommEngine.pico8, 'DISABLE_PICO8', platform == 'pico' &&
        (game.fileName.toLowerCase().endsWith('.p8') || game.fileName.toLowerCase().endsWith('.p8.png')));
    web(RommEngine.easyRpg, 'DISABLE_EASYRPG', platform == 'rpg-maker' && game.easyRpg);
    for (final stream in streams.where((s) => game.hasBytes && s['platform'] == platform)) {
      result.add(RommRoute(RommEngine.stream, core: rommString(stream['emulator'], 128),
        available: browserAvailable && fresh, reason: !browserAvailable ? 'romm.browserUnavailable'
          : !fresh ? 'romm.refreshBeforePlay' : ''));
    }
    for (final core in nativeCores) {
      if (!(rommNativeCorePlatforms[core] ?? const []).contains(platform)) continue;
      final name = offlineAvailable && offlineFileName.isNotEmpty ? offlineFileName : game.fileName;
      final eligible = rommNativeCartridge(core, name) &&
        (offlineAvailable || game.files.length <= 1);
      result.add(RommRoute(RommEngine.native, core: core, available: eligible, reason: eligible ? '' : 'romm.unsupportedArchive'));
    }
    return result;
  }
  Map<String, dynamic> toJson() => {'version': version, 'emulation': emulation, 'config': config,
    'streams': streams, 'platforms': platforms, 'scopes': scopes}; // Cached capabilities never claim freshness.
  factory RommCapabilities.cached(Map<String, dynamic> j) => RommCapabilities(
    version: rommString(j['version'], 64), emulation: rommMap(j['emulation']), config: rommMap(j['config']),
    streams: rommList(j['streams']).take(500).map(rommMap).toList(),
    platforms: rommList(j['platforms']).take(1000).map(rommMap).toList(), scopes: rommStrings(j['scopes']));
}

/// Initially packaged software-rendered cores. The runtime reports the cores
/// actually present; this mapping alone never enables a native Play action.
const rommNativeCorePlatforms = <String, List<String>>{
  'snes9x': ['snes', 'sfam', 'super-nintendo-original-european-version', 'super-famicom-shvc-001',
    'super-famicom-jr-model-shvc-101', 'new-style-super-nes-model-sns-101'],
  'gambatte': ['gb', 'gbc', 'game-boy-pocket', 'game-boy-light'],
  'mgba': ['gba', 'gb', 'gbc', 'game-boy-pocket', 'game-boy-light', 'game-boy-adavance-sp', 'game-boy-micro'],
  'fceumm': ['nes', 'famicom', 'game-televisison', 'new-style-nes'],
  'genesis_plus_gx': ['genesis', 'sms', 'gamegear', 'sega-mark-iii', 'sega-game-box-9', 'sega-master-system-ii',
    'master-system-super-compact', 'master-system-girl', 'sega-mega-drive-2-slash-genesis', 'sega-mega-jet', 'mega-pc', 'tera-drive', 'sega-nomad'],
};

bool rommNativeCartridge(String core, String name) {
  const extensions = <String, Set<String>>{
    'snes9x': {'sfc', 'smc'}, 'gambatte': {'gb', 'gbc'}, 'mgba': {'gba', 'gb', 'gbc'},
    'fceumm': {'nes'}, 'genesis_plus_gx': {'bin', 'md', 'gen', 'sms', 'gg'},
  };
  return name.contains('.') && (extensions[core]?.contains(name.split('.').last.toLowerCase()) ?? false);
}
