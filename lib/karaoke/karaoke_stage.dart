import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../media/lyrics.dart';
import '../mpv/video.dart';
import 'cdg_decoder.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';
import 'karaoke_strings.dart';

class KaraokeStage extends StatefulWidget {
  const KaraokeStage({super.key,required this.session});
  final KaraokeSession session;
  @override State<KaraokeStage> createState()=>_KaraokeStageState();
}
class _KaraokeStageState extends State<KaraokeStage> {
  String? _id;
  CdgDecoder? _cdg;
  @override void initState() { super.initState(); _load(); }
  @override void didUpdateWidget(KaraokeStage old) { super.didUpdateWidget(old); _load(); }
  Future<void> _load() async {
    final song=widget.session.track;
    if(song?.id==_id)return;
    _id=song?.id; _cdg=null;
    final asset=song?.assets.where((a)=>a.kind==KaraokeAssetKind.cdg).firstOrNull;
    if(song==null || asset==null)return;
    try {
      final file=await widget.session.store.asset(song.id,asset.path);
      if(await file.length()>64*1024*1024) throw const FormatException('CD+G exceeds renderer limit');
      final decoder=CdgDecoder(await file.readAsBytes());
      if(mounted && _id==song.id)setState(()=>_cdg=decoder);
    } catch(e) { widget.session.report(e); }
  }
  @override Widget build(BuildContext context) {
    final s=widget.session, song=s.track;
    return ColoredBox(color:Color(s.stageColor),child:ValueListenableBuilder<int>(valueListenable:s.positionMs,builder:(context,position,_) {
      final time=position+(song?.lyricOffsetMs ?? 0)+s.displayOffsetMs;
      return LayoutBuilder(builder:(context,constraints) {
        final font=(constraints.maxWidth/23).clamp(22.0,64.0)*s.stageTextScale;
        final lyrics=song?.lyrics;
        final active=<LyricLine>[],next=<LyricLine>[];
        if(lyrics?.synced==true) {
          for(var i=0;i<lyrics!.lines.length;i++) {
            final line=lyrics.lines[i],start=line.startMs;
            if(start==null)continue;
            final following=lyrics.lines.skip(i+1).where((l)=>l.part==line.part && l.startMs!=null).firstOrNull;
            final end=line.endMs ?? following?.startMs ?? s.durationMs;
            if(start<=time && end>time)active.add(line);
            if(start>time && next.length<2)next.add(line);
          }
        }
        return Stack(fit:StackFit.expand,children:[
          if(s.videoPlayer case final player?) Video(player:player),
          if(_cdg!=null) Center(child:CdgView(decoder:_cdg!,positionMs:time)),
          if(s.videoPlayer!=null && lyrics?.isEmpty==false) const ColoredBox(color:Color(0x66000000)),
          SafeArea(child:Padding(padding:const EdgeInsets.all(24),child:Column(children:[
            if(s.banner.isNotEmpty) Text(s.banner,style:TextStyle(color:Colors.white,fontSize:font*.4),maxLines:2,textAlign:TextAlign.center),
            Text(song==null ? karaokeText(context,'upNext') : '${song.title} · ${song.artist}',
              style:TextStyle(color:Colors.white70,fontSize:font*.42),maxLines:2,textAlign:TextAlign.center),
            Expanded(child:Center(child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
              if(song==null) Text(s.rotation.isEmpty ? karaokeText(context,'noQueue') : s.catalog[s.rotation.first.trackId]?.title ?? '',
                style:TextStyle(color:Colors.white,fontSize:font),textAlign:TextAlign.center),
              if(song!=null && lyrics?.isEmpty==true && _cdg==null && s.videoPlayer==null)
                Text(karaokeText(context,'noLyrics'),style:TextStyle(color:Colors.white70,fontSize:font*.65),textAlign:TextAlign.center),
              if(lyrics?.synced==false && lyrics?.isEmpty==false) ...[
                Text(karaokeText(context,'untimed'),style:const TextStyle(color:Colors.white70)),
                Text(lyrics!.lines.map((l)=>l.text).join('\n'),style:TextStyle(color:Colors.white,fontSize:font*.7),textAlign:TextAlign.center),
              ],
              if(active.isEmpty && next.isNotEmpty && next.first.startMs!-time>1000)
                Text('${karaokeText(context,'countIn')} · ${((next.first.startMs!-time)/1000).ceil()}',
                  style:TextStyle(color:Colors.white,fontSize:font*.65)),
              for(final line in active.take(4)) _StageLine(line:line,time:time,font:font),
              for(final line in next.take(active.length>1 ? 1 : 2)) Padding(padding:const EdgeInsets.only(top:16),child:Text(
                '${line.part==null ? '' : '${line.part} · '}${line.text}',textAlign:TextAlign.center,
                style:TextStyle(color:Colors.white60,fontSize:font*.65))),
            ])))),
            if(song!=null && s.durationMs>0) Semantics(label:'${position~/1000} / ${s.durationMs~/1000}',
              child:LinearProgressIndicator(value:(position/s.durationMs).clamp(0,1),color:Colors.amber,backgroundColor:Colors.white24)),
          ]))),
        ]);
      });
    }));
  }
}

class _StageLine extends StatelessWidget {
  const _StageLine({required this.line,required this.time,required this.font});
  final LyricLine line;
  final int time;
  final double font;
  @override Widget build(BuildContext context) {
    final color=line.part=='2' ? Colors.cyanAccent : Colors.amberAccent;
    final style=TextStyle(fontSize:font,fontWeight:FontWeight.w700,color:Colors.white,height:1.3);
    return Padding(padding:const EdgeInsets.symmetric(vertical:10),child:Semantics(label:'${line.part ?? ''} ${line.text}',
      child:ExcludeSemantics(child:Column(mainAxisSize:MainAxisSize.min,children:[
        if(line.part!=null) Text(line.part!,style:TextStyle(color:color,fontSize:font*.4)),
        if(line.spans.isEmpty) Text(line.text,style:style.copyWith(color:color),textAlign:TextAlign.center)
        else Text.rich(TextSpan(children:line.spans.map((span) {
          final end=span.endMs;
          final progress=end==null ? (time>=span.startMs ? 1.0 : 0.0) : ((time-span.startMs)/math.max(1,end-span.startMs)).clamp(0.0,1.0);
          // Whole source spans preserve grapheme clusters, whitespace and bidi
          // shaping. Opacity expresses within-span progress without splitting.
          return TextSpan(text:span.text,style:style.copyWith(color:Color.lerp(Colors.white54,color,progress)));
        }).toList()),textAlign:TextAlign.center),
        if(line.pronunciation!=null) Text(line.pronunciation!,textAlign:TextAlign.center,style:style.copyWith(fontSize:font*.5,color:Colors.white70)),
        if(line.translation!=null) Text(line.translation!,textAlign:TextAlign.center,style:style.copyWith(fontSize:font*.5,color:Colors.white70)),
      ]))));
  }
}
