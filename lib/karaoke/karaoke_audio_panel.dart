import 'dart:async';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'karaoke_audio.dart';
import 'karaoke_scoring.dart';
import 'karaoke_session.dart';

class KaraokeAudioPanel extends StatefulWidget {
  const KaraokeAudioPanel({super.key,required this.session,required this.audio,required this.singer});
  final KaraokeSession session;
  final KaraokeAudio audio;
  final String? singer;
  @override State<KaraokeAudioPanel> createState()=>_KaraokeAudioPanelState();
}
class _KaraokeAudioPanelState extends State<KaraokeAudioPanel> {
  bool _busy=false;
  Future<void> run(Future<void> Function() action) async {
    if(_busy)return;setState(()=>_busy=true);
    try { await action(); } catch(e) { widget.session.report(e); }
    finally { if(mounted)setState(()=>_busy=false); }
  }
  Future<void> enable() => run(() async {
    final devices=await widget.audio.devices();
    if(!mounted)return;
    InputDevice? device;
    if(devices.length>1) {
      device=await showDialog<InputDevice>(context:context,builder:(context)=>SimpleDialog(title:const Text('Choose a microphone'),
        children:devices.map((d)=>SimpleDialogOption(onPressed:()=>Navigator.pop(context,d),child:Text(d.label))).toList()));
      if(device==null)return;
    } else { device=devices.firstOrNull; }
    await widget.audio.start(singer:widget.singer!,device:device);
  });
  @override Widget build(BuildContext context) => AnimatedBuilder(animation:widget.audio,builder:(context,_) {
    final a=widget.audio,s=widget.session,result=a.score?.result();
    return Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Text('Microphone and private take',style:Theme.of(context).textTheme.titleLarge),
      const Text('Pitch feedback and dry recording use your selected microphone. Use an external mixer for amplification.'),
      Wrap(spacing:12,runSpacing:8,children:[
        FilledButton.icon(onPressed:_busy || a.starting || widget.singer==null || !s.hasPerformance || !a.supported ? null :
          ()=>a.capturing ? run(a.stop) : enable(),icon:Icon(a.capturing ? Icons.mic_off : Icons.mic),
          label:Text(a.capturing ? 'Mute microphone' : 'Enable microphone')),
        OutlinedButton.icon(onPressed:_busy || !a.capturing ? null : ()=>run(a.recording ? a.stopRecording : a.startRecording),
          icon:Icon(a.recording ? Icons.stop : Icons.fiber_manual_record),label:Text(a.recording ? 'Save private take' : 'Record private take')),
      ]),
      const SizedBox(height:12),LinearProgressIndicator(value:(a.rms*4).clamp(0,1),semanticsLabel:'Microphone level'),
      Text(a.midi==null ? 'No confident pitch' : 'Pitch: MIDI ${a.midi!.toStringAsFixed(1)}'),
      if(a.trace.isNotEmpty) SizedBox(height:120,child:CustomPaint(painter:_PitchTrace(a.trace.toList(),s.positionMs.value))),
      Text(result?['eligible']==true ? 'Score: ${result!['score']} / 10000 · ${KaraokeScore.rulesVersion}' :
        result?['invalidated']==true ? 'Practice pass: a seek or setting change disabled competitive scoring.' : 'Sing-along: scoring requires a reviewed reference chart.'),
      Text('Input offset: ${a.inputOffsetMs} ms · ${a.calibrated ? 'calibrated' : 'manual / uncalibrated'}'),
      Slider(min:-500,max:1000,divisions:150,value:a.inputOffsetMs.toDouble().clamp(-500,1000),
        label:'${a.inputOffsetMs} ms',onChanged:_busy ? null : (value)=>run(()=>a.setCalibration(value.round(),measured:false))),
      TextButton(onPressed:_busy || a.rangeSamples.length<30 || widget.singer==null ? null : ()=>run(() async {
        final range=karaokeRange(a.rangeSamples,s.track?.notes ?? []),singer=s.singers.firstWhere((p)=>p.id==widget.singer);
        singer.lowMidi=range.low;singer.highMidi=range.high;await s.save();
        if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Comfortable range saved: ${range.low.round()}–${range.high.round()} MIDI. Suggested key: ${range.suggestedKey}.')));
      }),child:const Text('Save my comfortable range')),
    ])));
  });
}
class _PitchTrace extends CustomPainter {
  _PitchTrace(this.frames,this.now);
  final List<KaraokePitch> frames;
  final int now;
  @override void paint(Canvas canvas,Size size) {
    final paint=Paint()..color=Colors.amber..strokeWidth=2..style=PaintingStyle.stroke;
    final path=Path();var connected=false;
    for(final f in frames.where((f)=>f.sourceMs>now-10000)) {
      if(f.midi==null){connected=false;continue;}
      final x=(f.sourceMs-(now-10000))/10000*size.width,y=size.height*(1-(f.midi!-36)/60).clamp(0,1);
      if(!connected){path.moveTo(x,y);connected=true;}else{path.lineTo(x,y);}
    }
    canvas.drawPath(path,paint);
  }
  @override bool shouldRepaint(_PitchTrace old)=>true;
}
