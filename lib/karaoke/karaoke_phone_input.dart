import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'karaoke_scoring.dart';
import 'karaoke_session.dart';

/// Authenticated phone pitch and optional dry take ingestion. This is a bounded
/// recording transport, never a speaker/monitor route. Browser measurements are
/// uncalibrated practice evidence and cannot enter competitive leaderboards.
class KaraokePhoneInputs {
  KaraokePhoneInputs(this.session);
  final KaraokeSession session;
  final Map<String,_PhoneLease> _leases={};
  Future<void> _serial=Future.value();
  int get count=>_leases.length;
  List<Map<String,dynamic>> get meters=>[for(final l in _leases.values){'singer':l.singer,'rms':l.rms,'midi':l.midi,'recording':l.file!=null}];
  Future<Map<String,dynamic>> command(String token,String singer,Map<String,dynamic> data) {
    final result=_serial.then((_)=>_command(token,singer,data));_serial=result.then<void>((_){}).catchError((Object _){});return result;
  }
  Future<Map<String,dynamic>> _command(String token,String singer,Map<String,dynamic> data) async {
    final action=data['operation'];
    if(action=='stop'){await _stop(token);return {'stopped':true};}
    if(!session.playing || session.current?.singers.contains(singer)!=true)throw StateError('A phone microphone can join only its active singer request');
    if(action=='start') {
      final prior=_leases[token];if(prior!=null)return {'lease':prior.id,'nextSequence':prior.sequence+1};
      if(_leases.length>=4)throw StateError('Four phone input limit reached');
      final song=session.track!,request=session.current!,id=const Uuid().v4();
      final lease=_PhoneLease(id,singer,request.id,song.id,session.epoch,request.key,request.tempo);
      if(session.party.game!='no-score' && song.canScore)lease.score=KaraokeScore(track:song,part:request.parts[singer] ?? request.part ?? song.parts.firstOrNull ?? '1',
        key:request.key,tempo:request.tempo,assisted:request.clipEndMs!=null,calibration:const {'calibrated':false,'device':'phone','transport':'bounded-http'});
      if(data['record']==true) {
        final root=await session.store.directory,takes=Directory(p.join(root.path,'takes'));var used=0;
        if(await takes.exists()){await for(final f in takes.list(recursive:true,followLinks:false)){if(f is File)used+=await f.length();}}
        if(used>8*1024*1024*1024-128*1024*1024)throw StateError('Private take storage quota reached');
        final dir=await Directory(p.join(takes.path,id)).create(recursive:true);lease.directory=dir;
        lease.metadata={'schema':1,'id':id,'renditionId':song.id,'singerId':singer,'key':request.key,'tempo':request.tempo,
          'sourceStartMs':session.positionMs.value,'epoch':session.epoch,'inputOffsetMs':0,'calibrated':false,'sampleRate':16000,
          'channels':1,'created':DateTime.now().toUtc().toIso8601String(),'private':true,'complete':false,'dryFile':'dry.wav',
          'scoreRules':KaraokeScore.rulesVersion,'timeline':[],
          if(session.duetInvitation?['renditionId']==song.id)...{'invitationId':session.duetInvitation!['id'],'part':session.duetInvitation!['part'],'digests':session.duetInvitation!['digests']},'input':'phone','latencyQuality':'unmeasured'};
        await File(p.join(dir.path,'take.json')).writeAsString(jsonEncode(lease.metadata),flush:true);
        lease.file=await File(p.join(dir.path,'dry.wav')).open(mode:FileMode.write);await lease.file!.writeFrom(_header(0));
      }
      _leases[token]=lease;return {'lease':id,'nextSequence':0};
    }
    final lease=_leases[token];
    if(action!='frame' || lease==null || data['lease']!=lease.id)throw StateError('Phone input lease expired; enable it again');
    if(session.epoch!=lease.epoch || session.track?.id!=lease.rendition || data['epoch']!=lease.epoch){await _stop(token);throw StateError('Playback changed; phone capture stopped');}
    final sequence=data['sequence'] as int,fingerprint=sha256.convert(utf8.encode(jsonEncode(data))).toString();
    if(sequence==lease.sequence && fingerprint==lease.fingerprint)return {'sequence':sequence};
    if(sequence!=lease.sequence+1)throw StateError('Phone input sequence gap');
    final source=data['sourceMs'] as int,rms=(data['rms'] as num).toDouble(),confidence=(data['confidence'] as num).toDouble(),midi=(data['midi'] as num?)?.toDouble();
    if((source-session.positionMs.value).abs()>2000 || !rms.isFinite || rms<0 || rms>1 || !confidence.isFinite || confidence<0 || confidence>1 ||
      (midi!=null && (!midi.isFinite || midi<0 || midi>127)))throw const FormatException('Invalid phone timing or pitch frame');
    if(lease.file!=null) {
      final bytes=base64Decode(data['pcm'] as String);
      if(bytes.length!=4800 || lease.bytes+bytes.length>128*1024*1024)throw const FormatException('Phone recording size bound reached');
      if(lease.bytes==0)lease.metadata!['sourceStartMs']=(source-150*lease.tempo).round().clamp(0,86400000);
      await lease.file!.writeFrom(bytes);lease.bytes+=bytes.length;
    }
    lease.sequence=sequence;lease.fingerprint=fingerprint;lease.lastMs=DateTime.now().millisecondsSinceEpoch;lease.rms=rms;lease.midi=midi;
    lease.score?.add(KaraokePitch(sourceMs:source,epoch:lease.epoch,rms:rms,midi:midi,confidence:confidence));
    return {'sequence':sequence,'score':lease.score?.result(),'practiceOnly':true};
  }
  Future<void> _stop(String token) async {
    final lease=_leases.remove(token);if(lease==null)return;
    if(lease.score!=null)session.party.addResult({...lease.score!.result(),'eligible':false,'input':'phone'},singerId:lease.singer,requestId:lease.request);
    final file=lease.file,dir=lease.directory;
    if(file!=null && dir!=null) {
      try {await file.setPosition(0);await file.writeFrom(_header(lease.bytes));await file.flush();}finally{await file.close();}
      lease.metadata!['complete']=true;lease.metadata!['frames']=lease.bytes~/2;lease.metadata!['score']=null;
      await File(p.join(dir.path,'take.json')).writeAsString(jsonEncode(lease.metadata),flush:true);
    }
    await session.save();
  }
  Future<void> expire(Set<String> validTokens,{bool stopAll=false}) {
    final result=_serial.then((_)async{for(final e in _leases.entries.toList()){
      if(stopAll || !validTokens.contains(e.key) || DateTime.now().millisecondsSinceEpoch-e.value.lastMs>5000)await _stop(e.key);
    }});_serial=result.catchError((Object _){});return result;
  }
  static Uint8List _header(int bytes) {
    final h=ByteData(44);void word(int at,String text){for(var i=0;i<text.length;i++)h.setUint8(at+i,text.codeUnitAt(i));}
    word(0,'RIFF');h.setUint32(4,bytes+36,Endian.little);word(8,'WAVE');word(12,'fmt ');h.setUint32(16,16,Endian.little);
    h.setUint16(20,1,Endian.little);h.setUint16(22,1,Endian.little);h.setUint32(24,16000,Endian.little);h.setUint32(28,32000,Endian.little);
    h.setUint16(32,2,Endian.little);h.setUint16(34,16,Endian.little);word(36,'data');h.setUint32(40,bytes,Endian.little);return h.buffer.asUint8List();
  }
}
class _PhoneLease {
  _PhoneLease(this.id,this.singer,this.request,this.rendition,this.epoch,this.key,this.tempo);
  final String id,singer,request,rendition;
  final int epoch;
  final double key,tempo;
  int sequence=-1,bytes=0,lastMs=DateTime.now().millisecondsSinceEpoch;
  double rms=0;double? midi;
  String? fingerprint;
  RandomAccessFile? file;Directory? directory;Map<String,dynamic>? metadata;KaraokeScore? score;
}
