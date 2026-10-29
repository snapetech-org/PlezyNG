import 'dart:convert';
import 'dart:typed_data';
import '../media/lyrics.dart';
import 'karaoke_formats.dart';
import 'karaoke_models.dart';

/// Standard MIDI format 0/1 (PPQ), including KAR lyric/text meta events. MIDI
/// instruments remain distinct parts; selecting a vocal chart requires review.
KaraokeTextImport parseKaraokeMidi(Uint8List bytes) {
  if(bytes.length>16*1024*1024)throw const FormatException('MIDI exceeds 16 MiB');
  var at=0,events=0;
  int read() {if(at>=bytes.length)throw const FormatException('Truncated MIDI');return bytes[at++];}
  int u16()=>(read()<<8)|read();
  int u32()=>(read()<<24)|(read()<<16)|(read()<<8)|read();
  int variable() {var value=0;for(var i=0;i<4;i++){final b=read();value=(value<<7)|(b&127);if(b<128)return value;}throw const FormatException('Invalid MIDI variable integer');}
  String tag()=>String.fromCharCodes([read(),read(),read(),read()]);
  if(tag()!='MThd')throw const FormatException('Missing MIDI header');
  final headerSize=u32();if(headerSize<6 || headerSize>1024)throw const FormatException('Invalid MIDI header');
  final format=u16(),tracks=u16(),division=u16();
  if(format>1 || tracks>128 || tracks==0 || division==0 || (division & 0x8000)!=0)throw const FormatException('Only format 0/1 PPQ MIDI is supported by the chart importer');
  at+=headerSize-6;
  final tempoAtTick=<int,int>{0:500000};
  final notes=<({int start,int end,int pitch,String part})>[];
  final words=<({int tick,String text})>[];
  final meta=<String,String>{};
  for(var track=0;track<tracks;track++) {
    if(tag()!='MTrk')throw const FormatException('Missing MIDI track');
    final length=u32(),end=at+length;if(length<0 || end>bytes.length)throw const FormatException('Truncated MIDI track');
    var tick=0,running=0;
    final active=<String,List<int>>{};
    while(at<end) {
      if(++events>500000)throw const FormatException('MIDI event limit exceeded');
      tick+=variable();if(tick>0x7fffffff)throw const FormatException('MIDI duration overflow');
      var status=read();
      if(status<128){if(running==0)throw const FormatException('Invalid MIDI running status');at--;status=running;}
      if(status==255) {
        running=0;
        final type=read(),size=variable();if(at+size>end)throw const FormatException('Truncated MIDI metadata');
        final data=bytes.sublist(at,at+size);at+=size;
        if(type==81 && size==3) {final micro=(data[0]<<16)|(data[1]<<8)|data[2];if(micro>0)tempoAtTick[tick]=micro;}
        if(type==5 || type==1) {
          String value;try{value=utf8.decode(data);}on FormatException{value=latin1.decode(data);}
          if(value.startsWith('@T')) {meta[meta.containsKey('TITLE') ? 'ARTIST' : 'TITLE']=value.substring(2);}
          else if(value.startsWith('@L')){meta['LANGUAGE']=value.substring(2);}
          else if(!value.startsWith('@'))words.add((tick:tick,text:value));
        }
        if(type==47)break;
        continue;
      }
      if(status==240 || status==247) {final size=variable();if(at+size>end)throw const FormatException('Truncated MIDI SysEx');at+=size;running=0;continue;}
      if(status>=240)throw const FormatException('Unsupported MIDI system event');
      running=status;final kind=status&240,channel=status&15,a=read(),b=kind==192 || kind==208 ? 0 : read();
      if(a>=128 || b>=128)throw const FormatException('Invalid MIDI event data');
      final key='$channel:$a';
      if(kind==144 && b>0){active.putIfAbsent(key,()=>[]).add(tick);}
      if(kind==128 || (kind==144 && b==0)) {
        final starts=active[key];if(starts!=null && starts.isNotEmpty){final start=starts.removeAt(0);if(tick>start && channel!=9)notes.add((start:start,end:tick,pitch:a,part:'${track+1}:${channel+1}'));}
      }
    }
    at=end;
  }
  if(tempoAtTick.length>20000)throw const FormatException('MIDI tempo map limit exceeded');
  final tempo=tempoAtTick.entries.map((e)=>(tick:e.key,micros:e.value)).toList()..sort((a,b)=>a.tick.compareTo(b.tick));
  final prefixes=<double>[0];
  for(var i=1;i<tempo.length;i++)prefixes.add(prefixes.last+(tempo[i].tick-tempo[i-1].tick)*tempo[i-1].micros/division/1000);
  int ms(int tick) {
    var lo=0,hi=tempo.length;
    while(lo+1<hi){final mid=(lo+hi)~/2;if(tempo[mid].tick<=tick)lo=mid;else hi=mid;}
    return (prefixes[lo]+(tick-tempo[lo].tick)*tempo[lo].micros/division/1000).round();
  }
  words.sort((a,b)=>a.tick.compareTo(b.tick));
  final lines=<LyricLine>[],spans=<LyricSpan>[];
  void flush(){if(spans.isEmpty)return;lines.add(LyricLine(text:spans.map((s)=>s.text).join(),startMs:spans.first.startMs,
    endMs:spans.last.endMs,spans:spans.toList()));spans.clear();}
  for(var i=0;i<words.length;i++) {
    var text=words[i].text;
    if(text.startsWith('/') || text.startsWith('\\') || text.startsWith('\r')){flush();text=text.substring(1);}
    spans.add(LyricSpan(text:text,startMs:ms(words[i].tick),endMs:i+1<words.length ? ms(words[i+1].tick) : null,unit:LyricUnit.token));
  }
  flush();
  return KaraokeTextImport(Lyrics(synced:lines.isNotEmpty,lines:lines),metadata:meta,
    notes:notes.map((n)=>KaraokeNote(startMs:ms(n.start),endMs:ms(n.end),midi:n.pitch.toDouble(),part:n.part)).where((n)=>n.endMs>n.startMs).toList(),
    warnings:const ['MIDI instrument parts are not automatically vocal targets. Select and review the melody before scoring.','MIDI playback requires rendering with an approved soundfont.']);
}
