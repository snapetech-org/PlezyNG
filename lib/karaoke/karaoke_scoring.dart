import 'dart:math' as math;
import 'dart:typed_data';
import 'karaoke_models.dart';

class KaraokePitch {
  const KaraokePitch({required this.sourceMs,required this.epoch,required this.rms,this.midi,this.confidence=0});
  final int sourceMs,epoch;
  final double rms,confidence;
  final double? midi;
  Map<String,dynamic> toJson()=>{'sourceMs':sourceMs,'epoch':epoch,'rms':rms,'midi':midi,'confidence':confidence};
}

/// Bounded monophonic autocorrelation, intended for a close, isolated mic.
/// Silence/noise remains unpitched; this never extracts a target from a mix.
({double? midi,double confidence,double rms}) detectKaraokePitch(Float64List samples,int sampleRate) {
  if(samples.length<512 || samples.length>4096) return (midi:null,confidence:0,rms:0);
  var mean=0.0;
  for(final v in samples) { mean+=v; } mean/=samples.length;
  var energy=0.0;
  for(var i=0;i<samples.length;i++) { samples[i]-=mean; energy+=samples[i]*samples[i]; }
  final rms=math.sqrt(energy/samples.length);
  if(rms<.008)return (midi:null,confidence:0,rms:rms);
  final minLag=(sampleRate/1200).floor(),maxLag=math.min(samples.length~/2,(sampleRate/65).ceil());
  final correlations=Float64List(maxLag+1);
  var best=0.0;
  for(var lag=minLag;lag<=maxLag;lag++) {
    var cross=0.0,a=0.0,b=0.0;
    for(var i=0;i<samples.length-lag;i++) { final x=samples[i],y=samples[i+lag]; cross+=x*y;a+=x*x;b+=y*y; }
    final value=cross/math.sqrt(math.max(1e-20,a*b)); correlations[lag]=value;
    if(value>best)best=value;
  }
  if(best<.78)return (midi:null,confidence:best.clamp(0,1),rms:rms);
  for(var lag=minLag+1;lag<maxLag;lag++) {
    final center=correlations[lag];
    if(center>=math.max(.78,best*.95) && center>correlations[lag-1] && center>=correlations[lag+1]) {
      final a=correlations[lag-1],c=correlations[lag+1],denominator=a-2*center+c;
      final correction=denominator.abs()<1e-12 ? 0.0 : (.5*(a-c)/denominator).clamp(-.5,.5);
      final frequency=sampleRate/(lag+correction);
      return (midi:69+12*math.log(frequency/440)/math.ln2,confidence:center.clamp(0,1),rms:rms);
    }
  }
  return (midi:null,confidence:best.clamp(0,1),rms:rms);
}

class KaraokeScore {
  KaraokeScore({required this.track,required this.part,required this.key,required this.tempo,required this.calibration,
    this.octaveTolerance=true,this.assisted=false});
  static const rulesVersion='plezy-karaoke-1';
  final KaraokeTrack track;
  final String part;
  final double key,tempo;
  final Map<String,dynamic> calibration;
  final bool octaveTolerance,assisted;
  final Map<int,double> _coverage={},_pitch={},_onsets={};
  final List<KaraokePitch> trace=[];
  int? _lastTime,_epoch;
  bool invalidated=false;
  bool get eligible=>track.canScore && !assisted && !invalidated;
  void add(KaraokePitch frame) {
    if(!eligible)return;
    if(_epoch!=null && frame.epoch!=_epoch) { invalidated=true; return; }
    _epoch=frame.epoch;
    final previous=_lastTime; _lastTime=frame.sourceMs;
    if(previous==null || frame.sourceMs<=previous)return;
    final dt=(frame.sourceMs-previous).clamp(0,150);
    if(trace.length<20000)trace.add(frame);
    for(var i=0;i<track.notes.length;i++) {
      final n=track.notes[i];
      if(n.freestyle || n.part!=part || n.endMs<=frame.sourceMs-dt || n.startMs>=frame.sourceMs)continue;
      final overlap=math.max(0,math.min(n.endMs,frame.sourceMs)-math.max(n.startMs,frame.sourceMs-dt)).toDouble();
      final voiced=frame.midi!=null && frame.confidence>=.78;
      if(!voiced)continue;
      var distance=(frame.midi!-(n.midi+key)).abs();
      if(octaveTolerance) { distance%=12; distance=math.min(distance,12-distance); }
      final accuracy=(1-distance/1.5).clamp(0.0,1.0);
      final remaining=(n.endMs-n.startMs)-(_coverage[i] ?? 0),credited=math.min(overlap,math.max(0,remaining)).toDouble();
      _coverage[i]=(_coverage[i] ?? 0)+credited;
      _pitch[i]=(_pitch[i] ?? 0)+credited*accuracy;
      _onsets.putIfAbsent(i,()=>((frame.sourceMs-n.startMs).abs()/tempo));
    }
  }
  Map<String,dynamic> result() {
    var total=0.0,pitch=0.0,rhythm=0.0,onset=0.0,count=0;
    for(var i=0;i<track.notes.length;i++) {
      final n=track.notes[i]; if(n.freestyle || n.part!=part)continue;
      final weight=n.golden ? 2.0 : 1.0; total+=(n.endMs-n.startMs)*weight;
      pitch+=(_pitch[i] ?? 0)*weight; rhythm+=(_coverage[i] ?? 0)*weight;
      onset+=1-((_onsets[i] ?? 500)/500).clamp(0,1);count++;
    }
    return {'rules':rulesVersion,'renditionId':track.id,'part':part,'key':key,'tempo':tempo,'calibration':calibration,
      'octaveTolerance':octaveTolerance,'assisted':assisted,'eligible':eligible && total>0,'invalidated':invalidated,
      'score':!eligible || total==0 ? null : (10000*(.7*pitch/total+.2*rhythm/total+.1*(count==0 ? 0 : onset/count))).round(),
      'pitchAccuracy':total==0 ? null : pitch/total,'voicedDuration':total==0 ? null : rhythm/total,'onsetAccuracy':count==0 ? null : onset/count};
  }
}

/// Opt-in comfortable range uses robust percentiles, not permanent voice labels.
({double low,double high,int suggestedKey}) karaokeRange(List<double> pitches,List<KaraokeNote> notes) {
  final values=pitches.where((p)=>p.isFinite && p>=24 && p<=108).toList()..sort();
  if(values.length<30)throw StateError('Sing comfortably for longer before saving a range');
  final low=values[(values.length*.1).floor()],high=values[(values.length*.9).floor()];
  final reference=notes.where((n)=>!n.freestyle).map((n)=>n.midi).toList()..sort();
  final middle=reference.isEmpty ? (low+high)/2 : reference[reference.length~/2];
  return (low:low,high:high,suggestedKey:(((low+high)/2)-middle).round().clamp(-12,12));
}
