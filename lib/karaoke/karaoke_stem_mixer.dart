import '../mpv/player/player.dart';
import 'karaoke_models.dart';
import 'karaoke_store.dart';

/// Stems feed one native filter graph and one output clock. No independent
/// players, Dart timers, inferred track IDs, or file-controlled filter strings.
class KaraokeStemMixer {
  KaraokeStemMixer(this.player,this.track,this.store);
  final Player player;
  final KaraokeTrack track;
  final KaraokeStore store;
  final Map<String,String> _ids={};
  final Map<String,double> levels={};
  String? _graph;
  bool get available=>_ids.length>1;
  Future<void> initialize() async {
    if(player.playerType!='mpv')throw UnsupportedError('Stem mixing requires MPV');
    final stems=track.assets.where((a)=>{KaraokeAssetKind.instrumental,KaraokeAssetKind.leadVocal,KaraokeAssetKind.backingVocal,KaraokeAssetKind.duetVocal}.contains(a.kind)).toList();
    if(stems.length<2)return;
    if(stems.length>16 || !stems.any((a)=>a.kind==KaraokeAssetKind.instrumental))throw const FormatException('A stem mix needs one instrumental and at most 16 aligned stems');
    if(stems.any((a)=>a.clockId!=track.id))throw const FormatException('Confirm each stem clockId matches the rendition before mixing');
    for(final stem in stems) {
      final file=await store.asset(track.id,stem.path);
      final current=await player.getProperty('path');
      if(current!=file.path && current!=file.uri.toString())await player.command(['audio-add',file.uri.toString(),'auto']);
      final count=int.tryParse(await player.getProperty('track-list/count') ?? '') ?? 0;
      String? id;
      for(var i=0;i<count;i++) {
        if(await player.getProperty('track-list/$i/type')!='audio')continue;
        final external=await player.getProperty('track-list/$i/external-filename');
        final isMain=await player.getProperty('track-list/$i/external')=='no';
        if(external==file.path || external==file.uri.toString() || (isMain && (current==file.path || current==file.uri.toString()))) {
          id=await player.getProperty('track-list/$i/id');break;
        }
      }
      if(id==null || !RegExp(r'^\d+$').hasMatch(id))throw StateError('The backend did not identify stem ${stem.path}');
      _ids[stem.path]=id;
      levels[stem.path]=stem.kind==KaraokeAssetKind.leadVocal || stem.kind==KaraokeAssetKind.duetVocal ? 0 : 1;
    }
    await apply(levels);
  }
  Future<void> apply(Map<String,double> values) async {
    if(!available)throw StateError('No aligned stem set is loaded');
    final gains={for(final path in _ids.keys)path:values[path] ?? 0};
    if(gains.values.any((v)=>!v.isFinite || v<0 || v>2))throw ArgumentError('Stem gains must be between 0 and 2');
    final chains=<String>[],outputs=<String>[];
    var i=0;
    for(final entry in _ids.entries) {
      final label='stem${i++}';
      chains.add('[aid${entry.value}]aresample=48000,volume=${gains[entry.key]!.toStringAsFixed(4)}[$label]');outputs.add('[$label]');
    }
    // Fixed headroom and limiter protect summed stems; the player applies key,
    // tempo and the existing EQ after this graph.
    chains.add('${outputs.join()}amix=inputs=${outputs.length}:duration=longest:normalize=0,volume=0.5,alimiter=limit=0.95:level=0[ao]');
    final graph=chains.join(';'),previous=_graph,wasPlaying=player.state.playing,position=player.currentPosition;
    await player.pause();
    try {
      await player.setAudioPassthrough(false);
      await player.setProperty('lavfi-complex',graph);
      await player.seek(position);_graph=graph;levels..clear()..addAll(gains);
    } catch(_) { await player.setProperty('lavfi-complex',previous ?? '');rethrow; }
    finally { if(wasPlaying)await player.play(); }
  }
  Future<void> guide(bool enabled) => apply({for(final a in track.assets)if(_ids.containsKey(a.path))a.path:
    a.kind==KaraokeAssetKind.leadVocal || a.kind==KaraokeAssetKind.duetVocal ? (enabled ? .6 : 0) : 1});
}
