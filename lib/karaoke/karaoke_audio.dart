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
  KaraokeAudio(this.session) { WidgetsBinding.instance.addObserver(this); session.addListener(_sessionChanged); }
  final KaraokeSession session;
  final AudioRecorder _recorder=AudioRecorder();
  StreamSubscription<Uint8List>? _samples;
  StreamSubscription<RecordState>? _state;
  Timer? _watchdog;
  bool capturing=false,starting=false,_disposed=false,_pitchBusy=false;
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
  Future<void>? _stopping;
  int _recordingLimit=512*1024*1024;
  Directory? _take;
  int _bytes=0;
  Map<String,dynamic>? _takeMetadata;
  bool get recording=>_dry!=null;
  bool get supported=>!PlatformDetector.isAppleTVSync() && !PlatformDetector.isTizenBuild() && !PlatformDetector.isWebOSBuild();
  Future<List<InputDevice>> devices() async => supported ? _recorder.listInputDevices() : [];
  void _notify() { if(!_disposed)notifyListeners(); }

  Future<void> start({required String singer,InputDevice? device}) async {
    await _stopping;
    if(!supported)throw UnsupportedError('Local microphone capture is unavailable on this TV; use an external mixer or companion');
    if(capturing || starting)throw StateError('Microphone already active');
    if(!session.hasPerformance)throw StateError('Start a performance before enabling a microphone');
    final generation=++_generation; starting=true;_notify();
    try {
      if(!await _recorder.hasPermission())throw StateError('Microphone permission denied');
      if(_disposed || generation!=_generation || !session.hasPerformance)return;
      if(!await _recorder.isEncoderSupported(AudioEncoder.pcm16bits))throw UnsupportedError('This capture backend cannot provide PCM');
      if(_disposed || generation!=_generation)return;
      singerId=singer;deviceId=device?.id;
      final route=await session.store.read('audio-calibration');
      final saved=(route?['routes'] as Map?)?[deviceId ?? 'default'] as Map?;
      inputOffsetMs=(saved?['inputOffsetMs'] as int? ?? 0).clamp(-2000,2000); calibrated=saved?['calibrated']==true;
      final stream=await _recorder.startStream(RecordConfig(encoder:AudioEncoder.pcm16bits,sampleRate:48000,numChannels:1,
        device:device,autoGain:false,echoCancel:false,noiseSuppress:false,streamBufferSize:1920,
        androidConfig:const AndroidRecordConfig(manageBluetooth:false,audioSource:AndroidAudioSource.unprocessed),
        audioInterruption:AudioInterruptionMode.pause));
      if(_disposed || generation!=_generation) { await _recorder.stop(); return; }
      capturing=true;_lastPacket=DateTime.now().millisecondsSinceEpoch;_window.clear();trace.clear();rangeSamples.clear();
      final song=session.track!;
      score=song.canScore ? KaraokeScore(track:song,part:session.current?.part ?? song.parts.firstOrNull ?? '1',
        key:session.current!.key,tempo:session.current!.tempo,calibration:{'device':deviceId,'inputOffsetMs':inputOffsetMs,'calibrated':calibrated}) : null;
      _samples=stream.listen((bytes)=>_receive(bytes,generation),onError:(Object e){session.report(e);unawaited(stop());},onDone:()=>unawaited(stop()));
      _state=_recorder.onStateChanged().listen((state){ if(state!=RecordState.record && capturing)unawaited(stop()); });
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
          _queuedBytes=math.max(0,_queuedBytes-copy.length);session.report(e);unawaited(stopRecording());
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
    inputOffsetMs=offset;calibrated=measured;
    final data=await session.store.read('audio-calibration') ?? {'schema':1,'routes':<String,dynamic>{}};
    final routes=Map<String,dynamic>.from(data['routes'] as Map);
    routes[deviceId ?? 'default']={'inputOffsetMs':offset,'calibrated':measured,'sampleRate':48000,'channels':1,'updated':DateTime.now().toUtc().toIso8601String()};
    data['routes']=routes;await session.store.write('audio-calibration',data);_notify();
  }
  Future<void> startRecording() async {
    if(!capturing || recording || session.track==null)throw StateError('Enable a microphone before recording');
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
      'scoreRules':KaraokeScore.rulesVersion,'timeline':<Map<String,dynamic>>[]};
    await File(p.join(dir.path,'take.json')).writeAsString(jsonEncode(metadata),flush:true);
    final file=await File(p.join(dir.path,'dry.wav')).open(mode:FileMode.write);
    await file.writeFrom(_wavHeader(0));
    _take=dir;_takeMetadata=metadata;_bytes=0;_dry=file;_notify();
  }
  static Uint8List _wavHeader(int bytes) {
    final h=ByteData(44);
    void word(int offset,String value) { for(var i=0;i<value.length;i++)h.setUint8(offset+i,value.codeUnitAt(i)); }
    word(0,'RIFF');h.setUint32(4,bytes+36,Endian.little);word(8,'WAVE');word(12,'fmt ');h.setUint32(16,16,Endian.little);
    h.setUint16(20,1,Endian.little);h.setUint16(22,1,Endian.little);h.setUint32(24,48000,Endian.little);h.setUint32(28,96000,Endian.little);
    h.setUint16(32,2,Endian.little);h.setUint16(34,16,Endian.little);word(36,'data');h.setUint32(40,bytes,Endian.little);
    return h.buffer.asUint8List();
  }
  Future<void> stopRecording() async {
    final file=_dry,dir=_take,metadata=_takeMetadata;
    if(file==null || dir==null || metadata==null)return;
    _dry=null;_take=null;_takeMetadata=null;
    await _writing;await file.setPosition(0);await file.writeFrom(_wavHeader(_bytes));await file.flush();await file.close();
    metadata['complete']=true;metadata['frames']=_bytes~/2;metadata['score']=score?.result();
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
    _watchdog?.cancel();_watchdog=null;
    final samples=_samples;_samples=null;final state=_state;_state=null;
    await samples?.cancel();await state?.cancel();
    await _recorder.stop();await stopRecording();_window.clear();rms=0;midi=null;_notify();
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) { if(state!=AppLifecycleState.resumed)unawaited(stop()); }
  @override void dispose() {
    _disposed=true;WidgetsBinding.instance.removeObserver(this);session.removeListener(_sessionChanged);
    unawaited(stop().whenComplete(_recorder.dispose));super.dispose();
  }
}
