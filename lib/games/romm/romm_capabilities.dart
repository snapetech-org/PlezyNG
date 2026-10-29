import 'romm_core_catalog.dart';
import 'romm_models.dart';

class RommCapabilities {
  const RommCapabilities({this.version = '', this.emulation = const {}, this.config = const {},
    this.streams = const [], this.platforms = const [], this.observedAt});
  final String version;
  final Map<String, dynamic> emulation, config;
  final List<Map<String, dynamic>> streams, platforms;
  final DateTime? observedAt;
  bool get fresh => observedAt != null && DateTime.now().difference(observedAt!) < const Duration(minutes: 5);
  String slug(RommGame game) => rommString(rommMap(config['PLATFORMS_VERSIONS'])[game.platform], 128).isEmpty
      ? game.platform : rommString(rommMap(config['PLATFORMS_VERSIONS'])[game.platform], 128);
  List<RommRoute> routes(RommGame game, {required bool browserAvailable, Set<String> nativeCores = const {}}) {
    if (!game.hasBytes) return const [];
    final platform = slug(game);
    final result = <RommRoute>[];
    void web(RommEngine engine, String flag, bool eligible, {String core = ''}) {
      if (eligible && emulation[flag] == false) result.add(RommRoute(engine, core: core,
        available: browserAvailable && fresh, reason: !browserAvailable ? 'romm.browserUnavailable'
          : !fresh ? 'romm.refreshBeforePlay' : ''));
    }
    final cores = rommBrowserCores[platform] ?? const <String>[];
    final preferred = rommString(rommMap(config['EJS_DEFAULT_CORES'])[platform], 128);
    web(RommEngine.emulatorJs, 'DISABLE_EMULATOR_JS', cores.isNotEmpty,
      core: cores.contains(preferred) ? preferred : cores.firstOrNull ?? '');
    web(RommEngine.ruffle, 'DISABLE_RUFFLE_RS', {'flash', 'browser'}.contains(platform) && game.extension == 'swf');
    web(RommEngine.jsDos, 'DISABLE_JSDOS', {'win3x', 'win9x'}.contains(platform) && game.extension == 'jsdos');
    web(RommEngine.pico8, 'DISABLE_PICO8', platform == 'pico' &&
        (game.fileName.toLowerCase().endsWith('.p8') || game.fileName.toLowerCase().endsWith('.p8.png')));
    web(RommEngine.easyRpg, 'DISABLE_EASYRPG', platform == 'rpg-maker' && game.easyRpg);
    for (final stream in streams.where((s) => s['platform'] == platform)) {
      result.add(RommRoute(RommEngine.stream, core: rommString(stream['emulator'], 128),
        available: browserAvailable && fresh, reason: !browserAvailable ? 'romm.browserUnavailable'
          : !fresh ? 'romm.refreshBeforePlay' : ''));
    }
    for (final core in nativeCores) {
      if ((rommNativeCorePlatforms[core] ?? const []).contains(platform)) result.add(RommRoute(RommEngine.native, core: core));
    }
    return result;
  }
  Map<String, dynamic> toJson() => {'version': version, 'emulation': emulation, 'config': config,
    'streams': streams, 'platforms': platforms}; // Cached capabilities never claim freshness.
  factory RommCapabilities.cached(Map<String, dynamic> j) => RommCapabilities(
    version: rommString(j['version'], 64), emulation: rommMap(j['emulation']), config: rommMap(j['config']),
    streams: rommList(j['streams']).take(500).map(rommMap).toList(),
    platforms: rommList(j['platforms']).take(1000).map(rommMap).toList());
}

/// Initially packaged software-rendered cores. The runtime reports the cores
/// actually present; this mapping alone never enables a native Play action.
const rommNativeCorePlatforms = <String, List<String>>{
  'snes9x': ['snes', 'sfam'], 'gambatte': ['gb', 'gbc'], 'mgba': ['gba', 'gb', 'gbc'],
  'fceumm': ['nes', 'famicom', 'fds'], 'genesis_plus_gx': ['genesis', 'sms', 'gamegear', 'segacd'],
};
