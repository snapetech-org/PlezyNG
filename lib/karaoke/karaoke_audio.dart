import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import '../utils/platform_detector.dart';
import 'karaoke_scoring.dart';
import 'karaoke_session.dart';

/// Music capture is separate from Steam's voice/Opus transport. Shared lifetime
/// rules: explicit permission, a generation lease, bounded buffers, stop on
/// background/interruption and no automatic microphone resume.
class KaraokeAudio extends ChangeNotifier with WidgetsBindingObserver {
  KaraokeAudio(this.session) { WidgetsBinding.instance.addObserver(this); session.addListener(_sessionChanged); session.stopCapture=stop; }
  final KaraokeSession session;
  AudioRecorder? _recorder;
  AudioRecorder get _capture { if(!supported)throw UnsupportedError('Microphone capture is unavailable');return _recorder ??= AudioRecorder(); }
  StreamSubscription<Uint8List>? _samples;
  StreamSubscription<RecordState>? _state;
  Timer? _watchdog;
  bool capturing=false,starting=false,_disposed=false,_pitchBusy=false,_recordStarting=false,_writeFailed=false;
  int _generation=0,_lastPacket=0,_queuedBytes=0,droppedAnalysisFrames=0;
  double rms=0;
  double? midi;
  String? singerId,deviceId;
  int inputOffsetMs=0;
  bool calibrated=false;
  KaraokeScore? score;
  final List<double> rangeSamples=[];
  final List<KaraokePitch> trace=[];
  final List<double> _window=[];
  RandomAccessFile? _dry;
  Future<void> _writing=Future.value();
  Future<void>? _stopping,_finalizing;
  int _recordingLimit=512*1024*1024;
  Directory? _take;
  int _bytes=0;
  Map<String,dynamic>? _takeMetadata;
  bool get recording=>_dry!=null;
  bool get supported=>!PlatformDetector.isAppleTVSync() && !PlatformDetector.isTizenBuild() && !PlatformDetector.isWebOSBuild();
  Future<List<InputDevice>> devices() async => supported ? _capture.listInputDevices() : [];
  void _notify() { if(!_disposed)notifyListeners(); }

  Future<void> start({required String singer,InputDevice? device}) async {
    await _stopping;
    if(!supported)throw UnsupportedError('Local microphone capture is unavailable on this TV; use an external mixer or companion');
    if(capturing || starting)throw StateError('Microphone already active');
    if(!session.hasPerformance || !session.playing)throw StateError('Start a performance before enabling a microphone');
    if(session.current?.singers.contains(singer)!=true)throw StateError('Choose a singer in the active request');
    final generation=++_generation; starting=true;_notify();
    try {
      if(!await _capture.hasPermission())throw StateError('Microphone permission denied');
      if(_disposed || generation!=_generation || !session.hasPerformance)return;
      if(!await _capture.isEncoderSupported(AudioEncoder.pcm16bits))throw UnsupportedError('This capture backend cannot provide PCM');
      if(_disposed || generation!=_generation)return;
      singerId=singer;deviceId=device?.id;
      final route=await session.store.read('audio-calibration');
      final saved=(route?['routes'] as Map?)?[deviceId ?? 'default'] as Map?;
      inputOffsetMs=(saved?['inputOffsetMs'] as int? ?? 0).clamp(-2000,2000); calibrated=saved?['calibrated']==true;
      final stream=await _capture.startStream(RecordConfig(encoder:AudioEncoder.pcm16bits,sampleRate:48000,numChannels:1,
        device:device,autoGain:false,echoCancel:false,noiseSuppress:false,streamBufferSize:1920,
        androidConfig:const AndroidRecordConfig(manageBluetooth:false,audioSource:AndroidAudioSource.unprocessed),
        audioInterruption:AudioInterruptionMode.pause));
      if(_disposed || generation!=_generation) { await _recorder?.stop(); return; }
      capturing=true;_lastPacket=DateTime.now().millisecondsSinceEpoch;_window.clear();trace.clear();rangeSamples.clear();
      final song=session.track!;
      score=song.canScore && session.party.game!='no-score' ? KaraokeScore(track:song,part:session.current?.parts[singer] ?? session.current?.part ?? song.parts.firstOrNull ?? '1',
        key:session.current!.key,tempo:session.current!.tempo,assisted:session.current!.clipEndMs!=null,calibration:{'device':deviceId,'inputOffsetMs':inputOffsetMs,'calibrated':calibrated}) : null;
      _samples=stream.listen((bytes)=>_receive(bytes,generation),onError:(Object e){session.report(e);unawaited(stop());},onDone:()=>unawaited(stop()));
      _state=_capture.onStateChanged().listen((state){ if(state!=RecordState.record && capturing)unawaited(stop()); });
      _watchdog=Timer.periodic(const Duration(seconds:1),(_) {
        if(DateTime.now().millisecondsSinceEpoch-_lastPacket>3000) { session.report('Microphone stopped delivering audio. Reconnect and enable it again.'); unawaited(stop()); }
      });
    } catch(_) { await stop(); rethrow; }
    finally { starting=false;_notify(); }
  }

  void _receive(Uint8List bytes,int generation) {
    if(!capturing || generation!=_generation)return;
    if(bytes.length>192000 || bytes.length%2!=0) { session.report('Unsupported microphone frame'); unawaited(stop()); return; }
    _lastPacket=DateTime.now().millisecondsSinceEpoch;
    if(_dry!=null) {
      if(_queuedBytes+bytes.length>1024*1024 || _bytes+bytes.length>_recordingLimit) {
        session.report('Recording stopped at its storage/backlog limit');unawaited(stopRecording());
      } else {
        final copy=Uint8List.fromList(bytes),file=_dry!;
        _queuedBytes+=copy.length;_bytes+=copy.length;
        _writing=_writing.then((_)=>file.writeFrom(copy)).then<void>((_){_queuedBytes-=copy.length;}).catchError((Object e){
          _writeFailed=true;_queuedBytes=math.max(0,_queuedBytes-copy.length);session.report(e);unawaited(stopRecording());
        });
      }
    }
    final data=ByteData.sublistView(bytes);
    // 48 kHz PCM -> 16 kHz analysis. Average each triplet for anti-aliasing.
    for(var i=0;i+5<bytes.length;i+=6) { _window.add((data.getInt16(i,Endian.little)+data.getInt16(i+2,Endian.little)+data.getInt16(i+4,Endian.little))/(3*32768)); }
    if(_window.length>2048)_window.removeRange(0,_window.length-2048);
    if(_window.length<1024)return;
    if(_pitchBusy) { droppedAnalysisFrames++;return; }
    _pitchBusy=true;
    final samples=Float64List.fromList(_window),sourceMs=session.positionMs.value-(inputOffsetMs*session.current!.tempo).round(),epoch=session.epoch;
    unawaited(Isolate.run(()=>detectKaraokePitch(samples,16000)).then((result){
      if(generation!=_generation || _disposed)return;
      rms=result.rms;midi=result.midi;
      final frame=KaraokePitch(sourceMs:sourceMs,epoch:epoch,rms:rms,midi:midi,confidence:result.confidence);
      score?.add(frame); trace.add(frame);if(trace.length>2000)trace.removeAt(0);
      if(midi!=null && result.confidence>.85 && rangeSamples.length<20000)rangeSamples.add(midi!);
      _notify();
    }).catchError((Object e){session.report(e);}).whenComplete(()=>_pitchBusy=false));
  }

  Future<void> setCalibration(int offset,{required bool measured}) async {
    if(offset.abs()>2000)throw ArgumentError('Calibration offset out of range');
    inputOffsetMs=offset;calibrated=measured;if(score!=null)score!.invalidated=true;
    final data=await session.store.read('audio-calibration') ?? {'schema':1,'routes':<String,dynamic>{}};
    final routes=Map<String,dynamic>.from(data['routes'] as Map);
    routes[deviceId ?? 'default']={'inputOffsetMs':offset,'calibrated':measured,'sampleRate':48000,'channels':1,'updated':DateTime.now().toUtc().toIso8601String()};
    data['routes']=routes;await session.store.write('audio-calibration',data);_notify();
  }
  Future<void> startRecording() async {
    await _finalizing;
    if(!capturing || recording || _recordStarting || session.track==null)throw StateError('Enable a microphone before recording');
    final generation=_generation;_recordStarting=true;
    try {
    final id=const Uuid().v4(),root=await session.store.directory;
    var used=0;
    final takes=Directory(p.join(root.path,'takes'));
    if(await takes.exists()) { await for(final f in takes.list(recursive:true,followLinks:false)) { if(f is File)used+=await f.length(); } }
    _recordingLimit=math.min(512*1024*1024,8*1024*1024*1024-used);
    if(_recordingLimit<10*1024*1024)throw StateError('Private take storage quota reached');
    final dir=await Directory(p.join(root.path,'takes',id)).create(recursive:true);
    final metadata=<String,dynamic>{'schema':1,'id':id,'renditionId':session.track!.id,'singerId':singerId,
      'key':session.current!.key,'tempo':session.current!.tempo,'sourceStartMs':session.positionMs.value,
      'epoch':session.epoch,'inputOffsetMs':inputOffsetMs,'calibrated':calibrated,'sampleRate':48000,'channels':1,
      'created':DateTime.now().toUtc().toIso8601String(),'private':true,'complete':false,'dryFile':'dry.wav',
      'scoreRules':KaraokeScore.rulesVersion,'timeline':<Map<String,dynamic>>[],
      if(session.duetInvitation?['renditionId']==session.track!.id)...{'invitationId':session.duetInvitation!['id'],'part':session.duetInvitation!['part'],'digests':session.duetInvitation!['digests']}};
    await File(p.join(dir.path,'take.json')).writeAsString(jsonEncode(metadata),flush:true);
    final file=await File(p.join(dir.path,'dry.wav')).open(mode:FileMode.write);
    await file.writeFrom(_wavHeader(0));
    if(!capturing || generation!=_generation) {await file.close();await dir.delete(recursive:true);throw StateError('Microphone stopped before recording began');}
    metadata['sourceStartMs']=session.positionMs.value;metadata['epoch']=session.epoch;metadata['lastEpoch']=session.epoch;
    _take=dir;_takeMetadata=metadata;_bytes=0;_writeFailed=false;_dry=file;_notify();
    } finally {_recordStarting=false;}
  }
  static Uint8List _wavHeader(int bytes) {
    final h=ByteData(44);
    void word(int offset,String value) { for(var i=0;i<value.length;i++)h.setUint8(offset+i,value.codeUnitAt(i)); }
    word(0,'RIFF');h.setUint32(4,bytes+36,Endian.little);word(8,'WAVE');word(12,'fmt ');h.setUint32(16,16,Endian.little);
    h.setUint16(20,1,Endian.little);h.setUint16(22,1,Endian.little);h.setUint32(24,48000,Endian.little);h.setUint32(28,96000,Endian.little);
    h.setUint16(32,2,Endian.little);h.setUint16(34,16,Endian.little);word(36,'data');h.setUint32(40,bytes,Endian.little);
    return h.buffer.asUint8List();
  }
  Future<void> stopRecording() => _finalizing ??= _stopRecording().whenComplete(()=>_finalizing=null);
  Future<void> _stopRecording() async {
    final file=_dry,dir=_take,metadata=_takeMetadata;
    if(file==null || dir==null || metadata==null)return;
    _dry=null;_take=null;_takeMetadata=null;
    var written=0;
    try {await _writing;written=math.max(0,await file.length()-44);written-=written%2;await file.truncate(written+44);await file.setPosition(0);await file.writeFrom(_wavHeader(written));await file.flush();}
    finally {await file.close();}
    metadata['complete']=!_writeFailed;metadata['frames']=written~/2;metadata['score']=_writeFailed ? null : score?.result();
    await File(p.join(dir.path,'take.json')).writeAsString(jsonEncode(metadata),flush:true);_notify();
  }
  void _sessionChanged() {
    if((capturing || starting) && !session.hasPerformance)unawaited(stop());
    final metadata=_takeMetadata;
    if(metadata!=null && metadata['lastEpoch']!=session.epoch) {
      (metadata['timeline'] as List).add({'frame':_bytes~/2,'sourceMs':session.positionMs.value,'epoch':session.epoch,
        'key':session.current?.key,'tempo':session.current?.tempo,'playing':session.playing});
      metadata['lastEpoch']=session.epoch;
    }
    if(capturing && !session.playing)unawaited(stop());
  }
  Future<void> stop() => _stopping ??= _stop().whenComplete(()=>_stopping=null);
  Future<void> _stop() async {
    _generation++;capturing=false;starting=false;
    if(score!=null && singerId!=null && session.current!=null) {session.party.addResult(score!.result(),singerId:singerId!,requestId:session.current!.id);}
    _watchdog?.cancel();_watchdog=null;
    final samples=_samples;_samples=null;final state=_state;_state=null;
    await samples?.cancel();await state?.cancel();
    try {await _recorder?.stop();} catch(e) {session.report(e);}
    try {await stopRecording();} finally {score=null;_window.clear();rms=0;midi=null;_notify();}
    await session.save();
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) { if(state!=AppLifecycleState.resumed)unawaited(stop()); }
  @override void dispose() {
    _disposed=true;WidgetsBinding.instance.removeObserver(this);session.removeListener(_sessionChanged);if(session.stopCapture==stop)session.stopCapture=null;
    unawaited(stop().whenComplete(() async {await _recorder?.dispose();}).catchError((Object e){session.report(e);}));super.dispose();
  }
}
