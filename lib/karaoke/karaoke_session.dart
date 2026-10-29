import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../media/lyrics.dart';
import '../media/media_item.dart';
import '../mpv/models.dart';
import '../mpv/player/player.dart';
import '../mpv/player/player_base.dart';
import '../services/music/music_playback_service.dart';
import '../services/playback_coordinator.dart';
import 'karaoke_models.dart';
import 'karaoke_packages.dart';
import 'karaoke_store.dart';
import 'karaoke_stem_mixer.dart';

class KaraokeConflict implements Exception {
  const KaraokeConflict(this.revision);
  final int revision;
  @override String toString() => 'The room changed. Refresh and retry (revision $revision).';
}

/// One profile, one authority and one playback clock. Microphones are never
/// restored automatically. Commands are serialized and acknowledged only after
/// the resulting snapshot and idempotency receipt have reached durable storage.
class KaraokeSession extends ChangeNotifier {
  KaraokeSession({required this.music, required String profileId}) : store = KaraokeStore(profileId) {
    packages = KaraokePackages(store);
    ready = _restore();
    music.addListener(_onMusic);
    _clock = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }
  final MusicPlaybackService music;
  final KaraokeStore store;
  late final KaraokePackages packages;
  late final Future<void> ready;
  final Map<String,KaraokeTrack> catalog = {};
  final List<KaraokeSinger> singers = [];
  final List<KaraokeRequest> requests = [];
  final Map<String,List<String>> setlists = {};
  final Map<String,int> _turns = {}, _lastTurn = {};
  final Map<String,Map<String,dynamic>> _receipts = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final ValueNotifier<int> positionMs = ValueNotifier(0);
  late final Timer _clock;
  Future<void> _commands = Future.value();
  Player? _player;
  KaraokeStemMixer? mixer;
  VideoPlayerLease? _videoLease;
  KaraokeRequest? current;
  int revision = 0, epoch = 0, _turnNumber = 0, _savedAt = 0;
  int? loopStartMs, loopEndMs, _undoSeek;
  bool fairRotation = true, allowExplicit = true, requireApproval = true, held = false;
  bool _disposed = false, _loopSeeking = false, _finishing = false;
  bool _usingMusic = false, _started = false;
  KaraokeMode mode = KaraokeMode.sing;
  String? error;
  String authority = 'plezyng';
  String banner = '';
  int stageColor = 0xff101018;
  double stageTextScale = 1;
  int displayOffsetMs = 0;
  int perSingerLimit = 5;
  Player? get videoPlayer => _videoLease == null ? null : _player;
  Player? get localPlayer => _player;
  KaraokeTrack? get track => current == null ? null : catalog[current!.trackId];
  bool get playing => _started && (_usingMusic ? music.isPlaying : _player?.state.playing == true);
  bool get hasPerformance => _started;
  int get durationMs => (_usingMusic ? music.duration?.inMilliseconds : _player?.state.duration.inMilliseconds) ?? track?.durationMs ?? 0;
  Set<String> get pinned => {for(final r in requests) if({KaraokeRequestState.ready,KaraokeRequestState.pending,KaraokeRequestState.playing}.contains(r.state)) r.trackId};

  Future<void> _restore() async {
    try {
      final j = await store.read('session');
      if(j == null) return;
      if(j['schema'] != 1) throw const FormatException('Unsupported karaoke session');
      for(final t in (j['catalog'] as List? ?? const [])) { final track=KaraokeTrack.fromJson(Map<String,dynamic>.from(t as Map)); catalog[track.id]=track; }
      singers.addAll((j['singers'] as List? ?? const []).map((s) => KaraokeSinger.fromJson(Map<String,dynamic>.from(s as Map))));
      requests.addAll((j['requests'] as List? ?? const []).map((r) => KaraokeRequest.fromJson(Map<String,dynamic>.from(r as Map))));
      for(final r in requests) { if(r.state == KaraokeRequestState.playing) { r.state=KaraokeRequestState.ready; current=r; } }
      positionMs.value = j['positionMs'] as int? ?? 0;
      revision=j['revision'] as int? ?? 0; epoch=(j['epoch'] as int? ?? 0)+1;
      _turnNumber=j['turnNumber'] as int? ?? 0;
      _turns.addAll(Map<String,int>.from(j['turns'] as Map? ?? {}));
      _lastTurn.addAll(Map<String,int>.from(j['lastTurn'] as Map? ?? {}));
      _receipts.addAll((j['receipts'] as Map? ?? {}).map((k,v) => MapEntry(k as String,Map<String,dynamic>.from(v as Map))));
      setlists.addAll((j['setlists'] as Map? ?? {}).map((k,v) => MapEntry(k as String,List<String>.from(v as List))));
      fairRotation=j['fairRotation'] != false; allowExplicit=j['allowExplicit'] != false; requireApproval=j['requireApproval'] != false;
      banner=j['banner'] as String? ?? ''; stageColor=j['stageColor'] as int? ?? stageColor;
      stageTextScale=(j['stageTextScale'] as num?)?.toDouble().clamp(.75,2) ?? 1;
      displayOffsetMs=j['displayOffsetMs'] as int? ?? 0;
      held=true; // Recovery always requires an intentional start/resume.
    } catch(e) { error='Could not restore karaoke session: $e'; }
    _notify();
  }
  Map<String,dynamic> _snapshot() => {'schema':1,'revision':revision,'epoch':epoch,'positionMs':positionMs.value,
    'catalog':catalog.values.map((t)=>t.toJson()).toList(),'singers':singers.map((s)=>s.toJson()).toList(),
    'requests':requests.map((r)=>r.toJson()).toList(),'turns':_turns,'lastTurn':_lastTurn,'turnNumber':_turnNumber,
    'receipts':_receipts,'setlists':setlists,'fairRotation':fairRotation,'allowExplicit':allowExplicit,'requireApproval':requireApproval,
    'banner':banner,'stageColor':stageColor,'stageTextScale':stageTextScale,'displayOffsetMs':displayOffsetMs};
  Future<void> save() => store.write('session',_snapshot());
  void _notify() { if(!_disposed) notifyListeners(); }
  void report(Object e) { error=e.toString(); _notify(); }

  Future<void> addTrack(KaraokeTrack value) async {
    await ready;
    if(catalog.length >= 2000 && !catalog.containsKey(value.id)) throw StateError('Karaoke catalog limit reached');
    catalog[value.id]=value; revision++; await save(); _notify();
  }
  Future<KaraokeTrack> addMedia(MediaItem media) async {
    await ready;
    final id=sha256.convert(utf8.encode(media.globalKey)).toString();
    if(catalog[id] case final existing?) return existing;
    final lyrics=await music.fetchLyrics(media) ?? const Lyrics(synced:false,lines:[]);
    final value=KaraokeTrack(id:id,songId:media.globalKey,title:media.title,artist:media.trackArtistTitle ?? '',
      media:media,lyrics:lyrics,durationMs:media.durationMs ?? 0);
    await addTrack(value); return value;
  }
  List<KaraokeTrack> search(String query,{bool offline=false,bool duet=false,String? language,String? tag,String? singerId}) {
    final words=query.toLowerCase().split(RegExp(r'\s+')).where((s)=>s.isNotEmpty);
    final singer=singers.where((s)=>s.id==singerId).firstOrNull;
    final found=catalog.values.where((t) => (allowExplicit || !t.explicit) && (!offline || t.assets.isNotEmpty) &&
      (!duet || t.parts.length>1) && (language==null || t.language==language) && (tag==null || t.tags.contains(tag)) &&
      words.every((q)=>'${t.title} ${t.artist} ${t.producer} ${t.tags.join(' ')}'.toLowerCase().contains(q))).toList();
    found.sort((a,b) {
      final fa=singer?.favorites.contains(a.id)==true ? 0 : 1, fb=singer?.favorites.contains(b.id)==true ? 0 : 1;
      return fa!=fb ? fa.compareTo(fb) : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return found;
  }
  List<KaraokeRequest> get rotation {
    final result=requests.where((r)=>r.state==KaraokeRequestState.ready && r.singers.every((id)=>singers.any((s)=>s.id==id && !s.absent))).toList();
    if(!fairRotation) return result;
    int turns(KaraokeRequest r) => r.singers.fold(0,(v,s)=>math.max(v,_turns[s] ?? 0));
    int last(KaraokeRequest r) => r.singers.fold(-1,(v,s)=>math.max(v,_lastTurn[s] ?? -1));
    result.sort((a,b) { var c=turns(a).compareTo(turns(b)); if(c==0)c=last(a).compareTo(last(b)); if(c==0)c=a.createdMs.compareTo(b.createdMs); return c==0 ? a.id.compareTo(b.id) : c; });
    return result;
  }
  String rotationReason(KaraokeRequest request) => fairRotation ? 'Fewest completed turns, then longest waiting; duets use both turns' : 'Host playlist order';
  int waitMs(KaraokeRequest request) {
    var ms=current==null ? 0 : math.max(0,durationMs-positionMs.value);
    for(final r in rotation) { if(r.id==request.id)break; ms+=((catalog[r.trackId]?.durationMs ?? 180000)/r.tempo).round()+10000; }
    return ms;
  }

  Future<Map<String,dynamic>> command(String id,int expectedRevision,String action,Map<String,dynamic> payload,{String? guestSinger}) {
    final future=_commands.then((_) async {
      await ready;
      if(_disposed) throw StateError('Room closed');
      if(!RegExp(r'^[a-zA-Z0-9_-]{8,128}$').hasMatch(id)) throw const FormatException('Invalid command ID');
      final fingerprint=sha256.convert(utf8.encode(jsonEncode([action,payload,guestSinger]))).toString();
      final prior=_receipts[id];
      if(prior!=null) { if(prior['fingerprint']!=fingerprint) throw StateError('Command ID reused for different content'); return Map<String,dynamic>.from(prior['result'] as Map); }
      if(expectedRevision!=revision) throw KaraokeConflict(revision);
      if(guestSinger!=null && !{'request','cancel','favorite'}.contains(action)) throw StateError('Host permission required');
      final response=<String,dynamic>{};
      switch(action) {
        case 'singer':
          final name=(payload['name'] as String).trim();
          if(name.isEmpty || name.length>80 || singers.length>=64) throw const FormatException('Singer name/room limit');
          final singer=KaraokeSinger(id:const Uuid().v4(),name:name);
          final active=singers.where((s)=>!s.absent).map((s)=>_turns[s.id] ?? 0);
          _turns[singer.id]=active.isEmpty ? 0 : active.reduce(math.min);
          singers.add(singer); response['singerId']=singer.id;
        case 'request':
          final trackId=payload['trackId'] as String, song=catalog[trackId];
          if(song==null || (!allowExplicit && song.explicit)) throw StateError('Song unavailable');
          final people=guestSinger==null ? List<String>.from(payload['singers'] as List) : [guestSinger];
          if(people.isEmpty || people.length>4 || people.toSet().length!=people.length || people.any((id)=>!singers.any((s)=>s.id==id))) throw const FormatException('Invalid singers');
          final waiting=requests.where((r)=>r.state==KaraokeRequestState.ready || r.state==KaraokeRequestState.pending || r.state==KaraokeRequestState.playing);
          if(waiting.length>=256 || people.any((s)=>waiting.where((r)=>r.singers.contains(s)).length>=perSingerLimit)) throw StateError('Request limit reached');
          if(waiting.any((r)=>r.trackId==trackId && r.singers.any(people.contains))) throw StateError('This singer already requested this rendition');
          final key=(payload['key'] as num?)?.toDouble() ?? 0, tempo=(payload['tempo'] as num?)?.toDouble() ?? 1;
          if(!key.isFinite || key.abs()>12 || !tempo.isFinite || tempo<.5 || tempo>2) throw const FormatException('Invalid key/tempo');
          final part=payload['part'] as String?;
          if(part!=null && !song.parts.contains(part)) throw const FormatException('Unknown duet part');
          final r=KaraokeRequest(id:const Uuid().v4(),trackId:trackId,singers:people,createdMs:DateTime.now().millisecondsSinceEpoch,
            key:key,tempo:tempo,part:part,state:guestSinger!=null && requireApproval ? KaraokeRequestState.pending : KaraokeRequestState.ready);
          requests.add(r); response['requestId']=r.id; response['state']=r.state.name;
        case 'cancel':
          final r=requests.firstWhere((r)=>r.id==payload['requestId']);
          if(guestSinger!=null && !r.singers.contains(guestSinger)) throw StateError('Cannot cancel another singer request');
          if(!{KaraokeRequestState.pending,KaraokeRequestState.ready}.contains(r.state)) throw StateError('Request already started or ended');
          r.state=KaraokeRequestState.rejected;
        case 'approve':
          final r=requests.firstWhere((r)=>r.id==payload['requestId']);
          if(r.state!=KaraokeRequestState.pending) throw StateError('Request is not pending');
          r.state=KaraokeRequestState.ready;
        case 'favorite':
          final s=singers.firstWhere((s)=>s.id==(guestSinger ?? payload['singerId']));
          final trackId=payload['trackId'] as String;
          if(!catalog.containsKey(trackId)) throw StateError('Unknown song');
          if(payload['value']==true) { s.favorites.add(trackId); } else { s.favorites.remove(trackId); }
        case 'absent':
          singers.firstWhere((s)=>s.id==payload['singerId']).absent=payload['value']==true;
        case 'reorder':
          final from=requests.indexWhere((r)=>r.id==payload['requestId']);
          final to=(payload['index'] as int).clamp(0,requests.length-1);
          if(from<0) throw StateError('Request missing');
          requests.insert(to,requests.removeAt(from)); fairRotation=false;
        case 'start':
          final r=payload['requestId']==null ? rotation.firstOrNull : requests.where((r)=>r.id==payload['requestId']).firstOrNull;
          if(r==null || r.state!=KaraokeRequestState.ready) throw StateError('No ready request');
          await _start(r,resumeMs:payload['resume']==true ? positionMs.value : 0);
        case 'pause': await pause(); held=true;
        case 'resume': if(!_started) throw StateError('Select the recovered request to resume'); await resume(); held=false;
        case 'restart': await seek(0);
        case 'seek': await seek(payload['positionMs'] as int);
        case 'finish': await _finish(skipped:payload['skipped']==true);
        case 'end': await stopPlayback(); held=true;
        case 'controls': await setControls((payload['key'] as num).toDouble(),(payload['tempo'] as num).toDouble());
        case 'settings':
          fairRotation=payload['fairRotation'] as bool? ?? fairRotation;
          allowExplicit=payload['allowExplicit'] as bool? ?? allowExplicit;
          requireApproval=payload['requireApproval'] as bool? ?? requireApproval;
          banner=(payload['banner'] as String? ?? banner).substring(0,math.min((payload['banner'] as String? ?? banner).length,160));
        default: throw UnsupportedError('Unknown room command: $action');
      }
      revision++; response['revision']=revision; response['epoch']=epoch;
      _receipts[id]={'fingerprint':fingerprint,'result':response};
      while(_receipts.length>512) { _receipts.remove(_receipts.keys.first); }
      try { await save(); } catch(_) { _receipts.remove(id); rethrow; }
      _notify(); return response;
    });
    _commands=future.then<void>((_){}).catchError((Object _){});
    return future;
  }
  Future<Map<String,dynamic>> host(String action,[Map<String,dynamic> payload=const {}]) => command(const Uuid().v4(),revision,action,payload);

  Future<void> _start(KaraokeRequest request,{int resumeMs=0}) async {
    if(_started) throw StateError('Finish or stop the current performance first');
    await stopPlayback();
    final song=catalog[request.trackId]!;
    current=request; positionMs.value=resumeMs; error=null;
    try {
      if(song.media!=null) {
        _usingMusic=true;
        music.setRepeatMode(MusicRepeatMode.off);
        await music.playFromList(tracks:[song.media!],playContext:MusicPlayContext(title:'Karaoke',kind:MusicPlayContextKind.tracks),initialPosition:Duration(milliseconds:resumeMs));
        if(music.status==MusicPlaybackStatus.error || music.currentTrack?.globalKey!=song.media!.globalKey) throw StateError('Music playback did not start');
      } else {
        if((await packages.verify(song)).isNotEmpty) throw StateError('Package assets are missing or corrupt');
        await PlaybackCoordinator.instance.claimKaraoke();
        final media=song.assets.where((a)=>a.kind==KaraokeAssetKind.video).firstOrNull ??
          song.assets.where((a)=>a.kind==KaraokeAssetKind.instrumental).firstOrNull ?? song.assets.firstWhere((a)=>a.kind==KaraokeAssetKind.audio);
        if(media.kind==KaraokeAssetKind.video) {
          _videoLease=await PlaybackCoordinator.instance.claimVideoSlot();
          _player=Player(companionSession:_videoLease!.slot==VideoPlayerSlot.companion);
        } else { _player=Player.audio(); }
        final player=_player!;
        _subscriptions.add(player.streams.error.listen((e)=>report(e)));
        _subscriptions.add(player.streams.completed.listen((done) { if(done && _started) unawaited(_completeAtBoundary()); }));
        final subtitles=<SubtitleTrack>[];
        for(final a in song.assets.where((a)=>a.kind==KaraokeAssetKind.subtitle)) {
          subtitles.add(SubtitleTrack.uri((await store.asset(song.id,a.path)).uri.toString(),title:a.path,isDefault:true));
        }
        await player.open(Media((await store.asset(song.id,media.path)).uri.toString(),start:Duration(milliseconds:resumeMs)),play:false,externalSubtitles:subtitles);
        if(subtitles.isNotEmpty) await player.selectSubtitleTrack(subtitles.first);
        if(song.assets.where((a)=>{KaraokeAssetKind.instrumental,KaraokeAssetKind.leadVocal,KaraokeAssetKind.backingVocal,KaraokeAssetKind.duetVocal}.contains(a.kind)).length>1) {
          final candidate=KaraokeStemMixer(player,song,store);await candidate.initialize();mixer=candidate;
        }
        await player.play();
      }
      _started=true; request.state=KaraokeRequestState.playing; held=false; epoch++;
      PlaybackCoordinator.instance.registerKaraoke(stopPlayback);
      if(request.key!=0 || request.tempo!=1) await setControls(request.key,request.tempo);
      _notify();
    } catch(_) { await stopPlayback(); request.state=KaraokeRequestState.ready; rethrow; }
  }
  Future<void> pause() async { if(_usingMusic) { await music.pause(); } else { await _player?.pause(); } _notify(); }
  Future<void> resume() async { if(_usingMusic) { await music.play(); } else { await _player?.play(); } _notify(); }
  Future<void> seek(int ms) async {
    if(!_started) throw StateError('No performance');
    _undoSeek=positionMs.value;
    final target=Duration(milliseconds:ms.clamp(0,durationMs>0 ? durationMs : math.max(0,ms)));
    epoch++;
    if(_usingMusic) { await music.seek(target); } else { await _player?.seek(target); }
    positionMs.value=target.inMilliseconds;
  }
  Future<void> undoSeek() async { final at=_undoSeek; if(at!=null) await seek(at); }
  Future<void> skipToSinging() async {
    final next=track?.lyrics.lines.where((l)=>l.startMs!=null && l.startMs!>positionMs.value+1500).firstOrNull;
    if(next!=null) await seek(math.max(0,next.startMs!-2000));
  }
  void setLoop(int? start,int? end) {
    if(start!=null && end!=null && (start<0 || end-start<500 || (durationMs>0 && end>durationMs))) throw ArgumentError('Loop must be at least 500 ms within the song');
    loopStartMs=start; loopEndMs=end; _notify();
  }
  Future<void> setControls(double key,double tempo) async {
    if(!_started || current==null) throw StateError('No performance');
    if(!key.isFinite || key.abs()>12 || !tempo.isFinite || tempo<.5 || tempo>2) throw ArgumentError('Invalid key/tempo');
    if(_usingMusic) {
      if(music is! MusicKaraokeControls) throw UnsupportedError('Music backend does not support independent key/tempo');
      await (music as MusicKaraokeControls).setKaraokeControls(semitones:key,tempo:tempo);
    } else {
      final player=_player!;
      if(player.playerType!='mpv' || player is! AudioEffectsCapable) throw UnsupportedError('Key/tempo require MPV');
      await player.setAudioPassthrough(false);
      await (player as AudioEffectsCapable).setAudioEffects((stereoWidth:0,spatializer:false,pitchSemitones:key));
      await player.setRate(tempo);
    }
    current!.key=key; current!.tempo=tempo; epoch++;
    for(final s in singers.where((s)=>current!.singers.contains(s.id))) { s.keys[current!.trackId]=key; s.tempos[current!.trackId]=tempo; }
    _notify();
  }
  Future<void> _completeAtBoundary() async {
    if(_finishing || !_started || loopEndMs!=null) return;
    _finishing=true;
    try { await host('finish'); } catch(e) { report(e); } finally { _finishing=false; }
  }
  Future<void> _finish({bool skipped=false}) async {
    final done=current;
    await stopPlayback();
    if(done==null) return;
    done.state=skipped ? KaraokeRequestState.skipped : KaraokeRequestState.completed;
    _turnNumber++;
    for(final s in singers.where((s)=>done.singers.contains(s.id))) {
      _turns[s.id]=(_turns[s.id] ?? 0)+1; _lastTurn[s.id]=_turnNumber;
      if(!skipped) { s.history.insert(0,done.trackId); if(s.history.length>500)s.history.removeLast(); }
    }
    current=null; positionMs.value=0;
  }
  Future<void> stopPlayback() async {
    PlaybackCoordinator.instance.unregisterKaraoke(stopPlayback);
    _started=false;
    for(final sub in _subscriptions) { await sub.cancel(); } _subscriptions.clear();
    if(current?.state==KaraokeRequestState.playing) current!.state=KaraokeRequestState.ready;
    final player=_player; _player=null; mixer=null;
    try {
      if(_usingMusic) {
        if(music is MusicKaraokeControls) await (music as MusicKaraokeControls).resetKaraokeControls();
        await music.pause();
      }
      await player?.dispose();
    } finally { _usingMusic=false; _videoLease?.release(); _videoLease=null; }
    loopStartMs=null; loopEndMs=null; _notify();
  }
  void _onMusic() { if(_usingMusic && !_disposed) _notify(); }
  void _tick() {
    if(_disposed || !_started) return;
    final ms=(_usingMusic ? music.position : _player?.currentPosition)?.inMilliseconds ?? 0;
    if(ms!=positionMs.value) positionMs.value=ms;
    if(loopStartMs!=null && loopEndMs!=null && ms>=loopEndMs! && !_loopSeeking) {
      _loopSeeking=true;
      unawaited(seek(loopStartMs!).catchError(report).whenComplete(()=>_loopSeeking=false));
    }
    if(_usingMusic && !playing && durationMs>0 && ms>=durationMs-150) unawaited(_completeAtBoundary());
    final now=DateTime.now().millisecondsSinceEpoch;
    if(now-_savedAt>5000) { _savedAt=now; unawaited(save().catchError(report)); }
  }
  @override void dispose() {
    _disposed=true; _clock.cancel(); music.removeListener(_onMusic);
    unawaited(save().catchError((Object _){}));
    unawaited(stopPlayback().catchError((Object _){}));
    positionMs.dispose(); super.dispose();
  }
}
