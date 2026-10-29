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
import 'karaoke_party.dart';

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
  Future<void>? _stoppingPlayback;
  int _playbackGeneration=0;
  Player? _player;
  KaraokeStemMixer? mixer;
  VideoPlayerLease? _videoLease;
  KaraokeRequest? current;
  int revision = 0, epoch = 0, _turnNumber = 0, _savedAt = 0;
  int? loopStartMs, loopEndMs, _undoSeek;
  bool fairRotation = true, allowExplicit = true, requireApproval = true, held = false;
  bool _disposed = false, _loopSeeking = false, _finishing = false;
  bool _usingMusic = false, _started = false;
  bool _resumeAfterQuiz = false;
  KaraokeMode mode = KaraokeMode.sing;
  String? error;
  KaraokeParty party=KaraokeParty();
  Future<void> Function()? stopCapture;
  String authority = 'plezyng';
  List<String> fillerTrackIds=[];
  _KaraokeMusicSnapshot? _musicSnapshot;
  int? _musicClaimRevision;
  bool _usingFiller=false;
  int _fillerIndex=0;
  StreamSubscription<bool>? _fillerSubscription;
  Map<String,dynamic>? duetInvitation;
  final Map<String,Map<String,dynamic>> analysis={};
  final Map<String,Future<void>> _analysisLoads={};
  String banner = '';
  int stageColor = 0xff101018;
  double stageTextScale = 1;
  int displayOffsetMs = 0;
  int perSingerLimit = 5;
  Player? get videoPlayer => _videoLease == null ? null : _player;
  Player? get localPlayer => _player;
  KaraokeTrack? get track => current == null ? null : catalog[current!.trackId];
  bool get playing => _usingFiller ? (_player?.state.playing==true) : _started && (_usingMusic ? music.isPlaying : _player?.state.playing == true);
  bool get hasPerformance => _started;
  int get durationMs {final actual=(_usingMusic ? music.duration?.inMilliseconds : _player?.state.duration.inMilliseconds) ?? 0;return actual>0 ? actual : track?.durationMs ?? 0;}
  Set<String> get pinned => {for(final r in requests) if({KaraokeRequestState.ready,KaraokeRequestState.pending,KaraokeRequestState.playing}.contains(r.state)) r.trackId,...setlists.values.expand((v)=>v),...fillerTrackIds};

  Future<void> _restore() async {
    try {
      final j = await store.read('session');
      if(j == null || _disposed) return;
      if(j['schema'] != 1) throw const FormatException('Unsupported karaoke session');
      for(final t in (j['catalog'] as List? ?? const [])) { final track=KaraokeTrack.fromJson(Map<String,dynamic>.from(t as Map)); catalog[track.id]=track; }
      fillerTrackIds=fillerTrackIds.where(catalog.containsKey).toList();
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
      stageTextScale=((j['stageTextScale'] as num?)?.toDouble() ?? 1).clamp(.75,2).toDouble();
      displayOffsetMs=(j['displayOffsetMs'] as int? ?? 0).clamp(-2000,2000);
      fillerTrackIds=List<String>.from(j['fillerTrackIds'] as List? ?? const []).take(16).toList();
      perSingerLimit=(j['perSingerLimit'] as int? ?? 5).clamp(1,10);
      if(j['party'] is Map)party=KaraokeParty.fromJson(Map<String,dynamic>.from(j['party'] as Map));
      if(j['duetInvitation'] is Map)duetInvitation=Map<String,dynamic>.from(j['duetInvitation'] as Map);
      held=true; // Recovery always requires an intentional start/resume.
    } catch(e) { error='Could not restore karaoke session: $e'; }
    _notify();
  }
  Map<String,dynamic> _snapshot() => {'schema':1,'revision':revision,'epoch':epoch,'positionMs':positionMs.value,
    'catalog':catalog.values.map((t)=>t.toJson()).toList(),'singers':singers.map((s)=>s.toJson()).toList(),
    'requests':requests.map((r)=>r.toJson()).toList(),'turns':_turns,'lastTurn':_lastTurn,'turnNumber':_turnNumber,
    'receipts':_receipts,'setlists':setlists,'fairRotation':fairRotation,'allowExplicit':allowExplicit,'requireApproval':requireApproval,
    'party':party.toJson(),'duetInvitation':duetInvitation,'fillerTrackIds':fillerTrackIds,'perSingerLimit':perSingerLimit,'banner':banner,'stageColor':stageColor,'stageTextScale':stageTextScale,'displayOffsetMs':displayOffsetMs};
  Future<void> save() => store.write('session',_snapshot());
  String _analysisKey(String id)=>'analysis-${sha256.convert(utf8.encode(id))}';
  Future<void> saveAnalysis(String id,Map<String,dynamic> value) async {analysis[id]=value;await store.write(_analysisKey(id),{'schema':1,'renditionId':id,'analysis':value});_notify();}
  Future<void> loadAnalysis(String id) async {
    if(analysis.containsKey(id))return;
    final pending=_analysisLoads[id];if(pending!=null){await pending;return;}
    final loading=Future<void>(() async {
      try {final saved=await store.read(_analysisKey(id));if(saved?['schema']==1 && saved?['renditionId']==id && saved?['analysis'] is Map){analysis[id]=Map<String,dynamic>.from(saved!['analysis'] as Map);_notify();}}
      catch(error){report(error);}
    });
    _analysisLoads[id]=loading;
    try {await loading;} finally {if(identical(_analysisLoads[id],loading))_analysisLoads.remove(id);}
  }

  void _notify() { if(!_disposed) notifyListeners(); }
  void report(Object e) { error=e.toString(); _notify(); }

  Future<void> addTrack(KaraokeTrack value) async {
    await ready;
    if(_disposed)throw StateError('Profile session closed');
    if(current?.trackId==value.id && _started)await stopPlayback();
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
  void _captureMusicSnapshot() {
    if(_musicSnapshot==null && music.currentTrack!=null && music.playContext?.title!='Karaoke' && music.playContext?.title!='Karaoke filler')
      _musicSnapshot=_KaraokeMusicSnapshot(tracks:List.of(music.queue),current:music.currentTrack!,position:music.position,
        context:music.playContext,repeat:music.repeatMode,shuffle:music.shuffled,wasPlaying:music.isPlaying);
  }
  Future<void> claimPlaybackResources() async {
    _captureMusicSnapshot();
    await PlaybackCoordinator.instance.claimKaraoke();
    _musicClaimRevision=music.queueSessionRevision;
  }
  int? suggestedKey(KaraokeTrack track,{String? singerId}) {
    final singer=singers.where((s)=>s.id==singerId).firstOrNull;
    final low=singer?.lowMidi,high=singer?.highMidi;
    final notes=track.notes.where((n)=>!n.freestyle).toList();
    if(low==null || high==null || notes.isEmpty)return null;
    var bottom=double.infinity,top=double.negativeInfinity;
    for(final note in notes) { bottom=math.min(bottom,note.midi).toDouble(); top=math.max(top,note.midi).toDouble(); }
    var best=0,bestCost=double.infinity;
    for(var key=-12;key<=12;key++) {
      final cost=(math.max(0,low-(bottom+key))+math.max(0,(top+key)-high)).toDouble()+key.abs()*.005;
      if(cost<bestCost) { best=key; bestCost=cost; }
    }
    return best;
  }
  bool fitsComfortableRange(KaraokeTrack track,{String? singerId}) {
    final singer=singers.where((s)=>s.id==singerId).firstOrNull;
    final low=singer?.lowMidi,high=singer?.highMidi;
    final notes=track.notes.where((n)=>!n.freestyle).toList();
    if(low==null || high==null || notes.isEmpty)return false;
    var bottom=double.infinity,top=double.negativeInfinity;
    for(final note in notes) { bottom=math.min(bottom,note.midi).toDouble(); top=math.max(top,note.midi).toDouble(); }
    return math.max(-12,(low-bottom).ceil())<=math.min(12,(high-top).floor());
  }
  List<KaraokeTrack> search(String query,{bool offline=false,bool duet=false,bool scored=false,bool fitsRange=false,
      String? language,String? genre,int? decade,int? difficulty,String? tag,String? singerId}) {
    final words=query.toLowerCase().split(RegExp(r'\s+')).where((s)=>s.isNotEmpty);
    final singer=singers.where((s)=>s.id==singerId).firstOrNull;
    final rangeFit=<String,bool>{};
    final found=<KaraokeTrack>[];
    for(final t in catalog.values) {
      if(singer?.lowMidi!=null && singer?.highMidi!=null)rangeFit[t.id]=fitsComfortableRange(t,singerId:singerId);
      if((!allowExplicit && t.explicit) || (offline && t.assets.isEmpty) || (duet && t.parts.length<=1) ||
          (scored && !t.canScore) || (fitsRange && rangeFit[t.id]!=true) || (language!=null && t.language!=language) ||
          (genre!=null && t.genre!=genre) || (decade!=null && (t.year==null || (t.year! ~/ 10) * 10 != decade)) ||
          (difficulty!=null && t.difficulty!=difficulty) || (tag!=null && !t.tags.contains(tag)) ||
          !words.every((q)=>'${t.title} ${t.artist} ${t.producer} ${t.genre} ${t.year ?? ''} ${t.tags.join(' ')}'.toLowerCase().contains(q)))continue;
      found.add(t);
    }
    found.sort((a,b) {
      final rangeA=rangeFit[a.id]==true ? 0 : 1, rangeB=rangeFit[b.id]==true ? 0 : 1;
      if(rangeA!=rangeB)return rangeA.compareTo(rangeB);
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
      if(prior!=null) { if(prior['fingerprint']!=fingerprint) throw StateError('Command ID reused for different content');await save();return Map<String,dynamic>.from(prior['result'] as Map); }
      if(expectedRevision!=revision) throw KaraokeConflict(revision);
      if(guestSinger!=null && !{'request','cancel','favorite','party'}.contains(action)) throw StateError('Host permission required');
      final response=<String,dynamic>{};
      switch(action) {
        case 'party':
          final operation=payload['operation'] as String;
          if(guestSinger!=null && operation!='answer')throw StateError('Host permission required');
          final data=Map<String,dynamic>.from(payload['data'] as Map? ?? {});
          if(operation=='startQuestion') {
            final index=data['index'], seconds=data['seconds'];
            if(index is! int || index<0 || index>=party.questions.length || (seconds!=null && seconds is! int)) {
              throw const FormatException('Invalid quiz question or duration');
            }
            final resumeAfter=_started && playing;
            if(resumeAfter) { await pause(); held=true; }
            _resumeAfterQuiz=_resumeAfterQuiz || resumeAfter;
          }
          if(operation=='mode') {
            if(!{'no-score','solo','duet','teams','cooperative','battle','tournament','medley','quiz'}.contains(data['game'])) {
              throw const FormatException('Unknown party mode');
            }
            _resumeAfterQuiz=false;
            if(_started) { if(playing)await pause(); held=true; }
            epoch++;
          }
          party.command(operation,data,singerId:guestSinger);
          if(operation=='endQuiz') {
            if(_resumeAfterQuiz && _started) { await resume(); held=false; }
            _resumeAfterQuiz=false;
          }
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
          final parts=guestSinger==null ? Map<String,String>.from(payload['parts'] as Map? ?? {}) : <String,String>{};
          if(parts.entries.any((e)=>!people.contains(e.key) || !song.parts.contains(e.value)))throw const FormatException('Invalid singer part assignment');
          if(part!=null && (part.isEmpty || part.length>80 || (song.parts.isNotEmpty && !song.parts.contains(part)))) throw const FormatException('Unknown duet part');
          final r=KaraokeRequest(id:const Uuid().v4(),trackId:trackId,singers:people,createdMs:DateTime.now().millisecondsSinceEpoch,
            key:key,tempo:tempo,part:part,parts:parts,state:guestSinger!=null && requireApproval ? KaraokeRequestState.pending : KaraokeRequestState.ready);
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
          final visible=rotation,from=visible.indexWhere((r)=>r.id==payload['requestId']);
          if(from<0 || visible.isEmpty) throw StateError('Ready request missing');
          final to=(payload['index'] as int).clamp(0,visible.length-1);
          visible.insert(to,visible.removeAt(from));
          final ids=visible.map((r)=>r.id).toSet();var next=0;
          for(var i=0;i<requests.length;i++) { if(ids.contains(requests[i].id))requests[i]=visible[next++]; }
          fairRotation=false;
        case 'medley':
          if(_started)throw StateError('Finish the active performance first');
          final group=const Uuid().v4(),items=rotation.take(10).toList();
          if(items.length<2)throw StateError('Queue at least two ready requests for a medley');
          for(final r in items){final song=catalog[r.trackId]!,section=song.sections.where((s)=>!s.instrumental).firstOrNull;
            final start=section?.startMs ?? song.lyrics.lines.where((l)=>l.startMs!=null).firstOrNull?.startMs ?? 0;
            final end=section?.endMs ?? math.min(song.durationMs>0 ? song.durationMs : start+60000,start+60000);
            if(end-start<1000)throw StateError('Set a usable section for ${song.title}');
            r.clipStartMs=start;r.clipEndMs=end;r.medleyGroup=group;
          }
          party.game='medley';party.medleyGroup=group;await _start(items.first);
        case 'start':
          final r=payload['requestId']==null ? rotation.firstOrNull : requests.where((r)=>r.id==payload['requestId']).firstOrNull;
          if(r==null || r.state!=KaraokeRequestState.ready) throw StateError('No ready request');
          await _start(r,resumeMs:payload['resume']==true ? positionMs.value : 0);
        case 'pause': await pause(); held=true;_resumeAfterQuiz=false;
        case 'resume': if(!_started) throw StateError('Select the recovered request to resume'); await resume(); held=false;_resumeAfterQuiz=false;
        case 'restart': await seek(0);
        case 'seek': await seek(payload['positionMs'] as int);
        case 'finish': await _finish(skipped:payload['skipped']==true);
        case 'end': await stopPlayback();await restoreMusic();current=null;held=true;_resumeAfterQuiz=false;
        case 'controls': await setControls((payload['key'] as num).toDouble(),(payload['tempo'] as num).toDouble());
        case 'requestSetlist':
          final name=payload['name'] as String,ids=List<String>.from(setlists[name] ?? const []);
          final people=List<String>.from(payload['singers'] as List? ?? const []);
          if(ids.isEmpty || ids.length>32 || people.isEmpty || people.length>4 || people.toSet().length!=people.length ||
            people.any((id)=>!singers.any((s)=>s.id==id && !s.absent)) || ids.toSet().length!=ids.length)throw const FormatException('Choose a nonempty setlist, unique songs and present singers');
          final active=requests.where((r)=>{KaraokeRequestState.pending,KaraokeRequestState.ready,KaraokeRequestState.playing}.contains(r.state)).toList();
          if(active.length+ids.length>256 || people.any((s)=>active.where((r)=>r.singers.contains(s)).length+ids.length>perSingerLimit))throw StateError('Setlist exceeds the request limit');
          for(final id in ids){final song=catalog[id];if(song==null || (!allowExplicit && song.explicit) || active.any((r)=>r.trackId==id && r.singers.any(people.contains)))throw StateError('A setlist rendition is missing, blocked or already queued');}
          final now=DateTime.now().millisecondsSinceEpoch;
          for(var i=0;i<ids.length;i++){requests.add(KaraokeRequest(id:const Uuid().v4(),trackId:ids[i],singers:people,createdMs:now+i));}
          response['queued']=ids.length;
        case 'fillers':
          final ids=List<String>.from(payload['trackIds'] as List);if(ids.length>16 || ids.toSet().length!=ids.length || ids.any((id)=>!catalog.containsKey(id) || !catalog[id]!.assets.any((a)=>a.kind==KaraokeAssetKind.instrumental)))throw const FormatException('Filler requires verified instrumental renditions');
          if(ids.isNotEmpty){for(final id in ids){if((await packages.verify(catalog[id]!)).isNotEmpty)throw StateError('A filler package failed checksum verification');}}
          fillerTrackIds=ids;
        case 'setlist':
          final name=(payload['name'] as String).trim();
          if(name.isEmpty || name.length>100)throw const FormatException('Invalid setlist name');
          if(payload['remove']==true){setlists.remove(name);}else{
            final ids=List<String>.from(payload['tracks'] as List);
            if(ids.length>256 || ids.any((id)=>!catalog.containsKey(id)) || (setlists.length>=100 && !setlists.containsKey(name)))throw const FormatException('Setlist limit or missing song');
            setlists[name]=ids;
          }
        case 'settings':
          stageTextScale=((payload['stageTextScale'] as num?)?.toDouble() ?? stageTextScale).clamp(.75,2).toDouble();
          stageColor=(payload['stageColor'] as int? ?? stageColor) | 0xff000000;
          displayOffsetMs=(payload['displayOffsetMs'] as int? ?? displayOffsetMs).clamp(-2000,2000);
          perSingerLimit=(payload['perSingerLimit'] as int? ?? perSingerLimit).clamp(1,10);
          fairRotation=payload['fairRotation'] as bool? ?? fairRotation;
          allowExplicit=payload['allowExplicit'] as bool? ?? allowExplicit;
          requireApproval=payload['requireApproval'] as bool? ?? requireApproval;
          banner=(payload['banner'] as String? ?? banner).substring(0,math.min((payload['banner'] as String? ?? banner).length,160));
        default: throw UnsupportedError('Unknown room command: $action');
      }
      revision++; response['revision']=revision; response['epoch']=epoch;
      _receipts[id]={'fingerprint':fingerprint,'result':response};
      while(_receipts.length>512) { _receipts.remove(_receipts.keys.first); }
      await save(); // Keep the receipt in memory if storage fails; a retry persists it before acknowledging.
      _notify(); return response;
    });
    _commands=future.then<void>((_){}).catchError((Object _){});
    return future;
  }
  Future<Map<String,dynamic>> host(String action,[Map<String,dynamic> payload=const {}]) => command(const Uuid().v4(),revision,action,payload);

  Future<void> _start(KaraokeRequest request,{int resumeMs=0}) async {
    if(_started) throw StateError('Finish or stop the current performance first');
    _resumeAfterQuiz=false;
    _captureMusicSnapshot();
    await stopPlayback();
    if(_disposed)throw StateError('Profile session closed');
    final generation=++_playbackGeneration;
    void checkActive() {if(_disposed || generation!=_playbackGeneration)throw StateError('Performance startup was canceled');}
    final song=catalog[request.trackId]!;
    _usingFiller=false;
    resumeMs=math.max(resumeMs,request.clipStartMs ?? 0);
    current=request; positionMs.value=resumeMs; error=null;
    try {
      if(song.media!=null) {
        _usingMusic=true;
        music.setRepeatMode(MusicRepeatMode.off);
        await music.playFromList(tracks:[song.media!],playContext:MusicPlayContext(title:'Karaoke',kind:MusicPlayContextKind.tracks),initialPosition:Duration(milliseconds:resumeMs));
        checkActive();
        if(music.status==MusicPlaybackStatus.error || music.currentTrack?.globalKey!=song.media!.globalKey) throw StateError('Music playback did not start');
      } else {
        if(!song.hasLocalAudio && !song.assets.any((a)=>a.kind==KaraokeAssetKind.video))throw StateError('Render this MIDI rendition with an approved soundfont before singing');
        if((await packages.verify(song)).isNotEmpty) throw StateError('Package assets are missing or corrupt');
        checkActive();
        await claimPlaybackResources();
        checkActive();
        final media=song.assets.where((a)=>a.kind==KaraokeAssetKind.video).firstOrNull ??
          song.assets.where((a)=>a.kind==KaraokeAssetKind.instrumental).firstOrNull ?? song.assets.firstWhere((a)=>a.kind==KaraokeAssetKind.audio);
        if(media.kind==KaraokeAssetKind.video) {
          final lease=await PlaybackCoordinator.instance.claimVideoSlot();
          if(_disposed || generation!=_playbackGeneration){lease.release();checkActive();}
          _videoLease=lease;
          _player=Player(companionSession:_videoLease!.slot==VideoPlayerSlot.companion);
        } else { _player=Player.audio(); }
        final player=_player!;
        PlaybackCoordinator.instance.registerKaraoke(stopPlayback);
        _subscriptions.add(player.streams.error.listen((e)=>report(e)));
        _subscriptions.add(player.streams.completed.listen((done) { if(done && _usingFiller)unawaited(_advanceFiller(generation));else if(done && _started)unawaited(_completeAtBoundary()); }));
        final subtitles=<SubtitleTrack>[];
        for(final a in song.assets.where((a)=>a.kind==KaraokeAssetKind.subtitle)) {
          subtitles.add(SubtitleTrack.uri((await store.asset(song.id,a.path)).uri.toString(),title:a.path,isDefault:true));
        }
        checkActive();
        await player.open(Media((await store.asset(song.id,media.path)).uri.toString(),start:Duration(milliseconds:resumeMs)),play:false,externalSubtitles:subtitles);
        checkActive();
        if(subtitles.isNotEmpty) await player.selectSubtitleTrack(subtitles.first);
        if(song.assets.where((a)=>{KaraokeAssetKind.instrumental,KaraokeAssetKind.leadVocal,KaraokeAssetKind.backingVocal,KaraokeAssetKind.duetVocal}.contains(a.kind)).length>1) {
          final candidate=KaraokeStemMixer(player,song,store);await candidate.initialize();mixer=candidate;
        }
        checkActive();await player.play();checkActive();
      }
      _started=true; request.state=KaraokeRequestState.playing; held=false; epoch++;
      PlaybackCoordinator.instance.registerKaraoke(stopPlayback);
      if(request.key!=0 || request.tempo!=1) await setControls(request.key,request.tempo);
      _notify();
    } catch(_) { await stopPlayback(); request.state=KaraokeRequestState.ready; rethrow; }
  }
  Future<void> pause() async { await stopCapture?.call();epoch++;if(_usingMusic) { await music.pause(); } else { await _player?.pause(); } _notify(); }
  Future<void> resume() async { if(_disposed || !_started)throw StateError('No active performance');if(_usingMusic) { await music.play(); } else { await _player?.play(); } _notify(); }
  Future<void> seek(int ms) async {
    if(!_started) throw StateError('No performance');
    _undoSeek=positionMs.value;
    final target=Duration(milliseconds:ms.clamp(0,durationMs>0 ? durationMs : math.max(0,ms)));
    if(current?.clipStartMs!=null && target.inMilliseconds<current!.clipStartMs!)throw StateError('Seek stays inside this medley section');
    if(current?.clipEndMs!=null && target.inMilliseconds>current!.clipEndMs!)throw StateError('Seek stays inside this medley section');
    epoch++;
    if(_usingMusic) { await music.seek(target); } else { await _player?.seek(target); }
    if(!_disposed)positionMs.value=target.inMilliseconds;_notify();
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
    final invitation=duetInvitation;
    if(invitation!=null && current!.trackId==invitation['renditionId'] && (key!=invitation['key'] || tempo!=invitation['tempo']))throw StateError('This duet invitation fixes the key and tempo');
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
    current=null;if(!_disposed)positionMs.value=0;
    if(!_disposed && party.game=='medley' && party.medleyGroup!=null){final next=rotation.where((r)=>r.medleyGroup==party.medleyGroup).firstOrNull;
      if(next!=null){await _start(next);}else{party.medleyGroup=null;}}
    if(!_disposed && !_started && current==null && fillerTrackIds.isNotEmpty){await startFiller();}else if(!_started && current==null)await restoreMusic();
  }
  Future<void> stopPlayback() {
    _playbackGeneration++; // Invalidates open/resolve work before any await.
    return _stoppingPlayback ??= _stopPlayback().whenComplete(()=>_stoppingPlayback=null);
  }
  Future<void> _stopPlayback() async {
    PlaybackCoordinator.instance.unregisterKaraoke(stopPlayback);
    _started=false;
    Object? failure;
    Future<void> attempt(Future<void> Function() action) async {try {await action();}catch(e){failure ??= e;}}
    await attempt(() async {await stopCapture?.call();});
    final subscriptions=_subscriptions.toList();_subscriptions.clear();
    final fillerSubscription=_fillerSubscription;_fillerSubscription=null;
    if(fillerSubscription!=null)await attempt(fillerSubscription.cancel);
    for(final sub in subscriptions) {await attempt(sub.cancel);}
    if(current?.state==KaraokeRequestState.playing)current!.state=KaraokeRequestState.ready;
    final player=_player,lease=_videoLease,usingMusic=_usingMusic,usingFiller=_usingFiller;
    _player=null;mixer=null;_videoLease=null;_usingMusic=false;_usingFiller=false;
    if(usingFiller)await attempt(() async {await player?.pause();});
    if(usingMusic) {
      await attempt(() async {if(music is MusicKaraokeControls)await (music as MusicKaraokeControls).resetKaraokeControls();});
      await attempt(music.pause);
    }
    await attempt(() async {await player?.dispose();});lease?.release();
    loopStartMs=null;loopEndMs=null;_notify();
    if(failure!=null)report(failure!);
  }
  Future<void> startFiller() async {
    if(fillerTrackIds.isEmpty || _disposed)throw StateError('No filler tracks configured');
    await stopPlayback();await claimPlaybackResources();
    _fillerIndex=0;await _openFiller(++_playbackGeneration);
  }
  Future<void> _openFiller(int generation) async {
    if(_disposed || generation!=_playbackGeneration || fillerTrackIds.isEmpty)return;
    final track=catalog[fillerTrackIds[_fillerIndex%fillerTrackIds.length]];
    if(track==null || (await packages.verify(track)).isNotEmpty)throw StateError('Filler package is unavailable or corrupt');
    final asset=track.assets.firstWhere((a)=>a.kind==KaraokeAssetKind.instrumental),file=await store.asset(track.id,asset.path);
    if(_player==null){_player=Player.audio();_fillerSubscription=_player!.streams.completed.listen((done){if(done && _usingFiller)unawaited(_advanceFiller(generation).catchError(report));});}
    _usingFiller=true;PlaybackCoordinator.instance.registerKaraoke(stopPlayback);
    await _player!.open(Media(file.uri.toString()));
  }
  Future<void> _advanceFiller(int generation) async {
    if(!_usingFiller || generation!=_playbackGeneration)return;
    _fillerIndex++;final old=_player;_player=null;final sub=_fillerSubscription;_fillerSubscription=null;await sub?.cancel();await old?.dispose();await _openFiller(generation);
  }
  Future<void> restoreMusic() async {
    final snapshot=_musicSnapshot;_musicSnapshot=null;
    final claimRevision=_musicClaimRevision;_musicClaimRevision=null;
    if(snapshot==null || _disposed || snapshot.tracks.isEmpty)return;
    final coordinator=PlaybackCoordinator.instance;
    final current=music.currentTrack;
    final karaokeContext=music.playContext?.title=='Karaoke';
    final claimedAndIdle=claimRevision!=null && music.queueSessionRevision==claimRevision && current==null && music.queue.isEmpty;
    final queueChanged=!karaokeContext && !claimedAndIdle && (current==null || music.queue.length!=snapshot.tracks.length ||
      List.generate(music.queue.length,(i)=>music.queue[i].globalKey).asMap().entries.any((e)=>e.value!=snapshot.tracks[e.key].globalKey));
    final externalPlayback=!karaokeContext && !claimedAndIdle && (current==null || music.isPlaying || current.globalKey!=snapshot.current.globalKey ||
      queueChanged || music.repeatMode!=snapshot.repeat || music.shuffled!=snapshot.shuffle);
    if(coordinator.hasFileSession || coordinator.hasVideoSession || coordinator.hasKaraokeSession || externalPlayback)return;
    try {
      await music.playFromList(tracks:snapshot.tracks,startTrack:snapshot.current,playContext:snapshot.context ?? const MusicPlayContext(title:'Music',kind:MusicPlayContextKind.tracks),shuffle:snapshot.shuffle,initialPosition:snapshot.position);
      music.setRepeatMode(snapshot.repeat);
      if(!snapshot.wasPlaying)await music.pause();
    }catch(e){report('Could not restore the previous music queue: $e');}
  }
  Future<void> changeStems(Map<String,double> gains) async {
    final currentMixer=mixer;if(currentMixer==null)throw StateError('No aligned stems');
    await stopCapture?.call();epoch++;
    await currentMixer.apply(gains);_notify();
  }
  void _onMusic() { if(_usingMusic && !_disposed) _notify(); }
  void _tick() {
    if(_disposed || (!_started && !_usingFiller)) return;
    final ms=(_usingMusic ? music.position : _player?.currentPosition)?.inMilliseconds ?? 0;
    if(_started && ms!=positionMs.value)positionMs.value=ms;
    if(loopStartMs!=null && loopEndMs!=null && ms>=loopEndMs! && !_loopSeeking) {
      _loopSeeking=true;
      unawaited(seek(loopStartMs!).catchError(report).whenComplete(()=>_loopSeeking=false));
    }
    if(current?.clipEndMs!=null && ms>=current!.clipEndMs! && playing)unawaited(_completeAtBoundary());
    if(_usingMusic && !playing && durationMs>0 && ms>=durationMs-150) unawaited(_completeAtBoundary());
    final now=DateTime.now().millisecondsSinceEpoch;
    if(now-_savedAt>5000) { _savedAt=now; unawaited(save().catchError(report)); }
  }
  @override void dispose() {
    _disposed=true; _clock.cancel(); music.removeListener(_onMusic);
    unawaited(save().catchError((Object _){}));
    unawaited(stopPlayback().catchError((Object _){}));
    // Async teardown may still read the final position; release it afterwards.
    unawaited((_stoppingPlayback ?? Future<void>.value()).whenComplete(positionMs.dispose));super.dispose();
  }
}

class _KaraokeMusicSnapshot {
  const _KaraokeMusicSnapshot({required this.tracks,required this.current,required this.position,required this.context,required this.repeat,required this.shuffle,required this.wasPlaying});
  final List<MediaItem> tracks;final MediaItem current;final Duration position;final MusicPlayContext? context;final MusicRepeatMode repeat;final bool shuffle,wasPlaying;
}
