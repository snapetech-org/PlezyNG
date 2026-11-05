import 'dart:typed_data';
import 'package:flutter/material.dart';

class _CdgFrame {
  _CdgFrame() : pixels=Uint8List(300*216), palette=Uint32List(16);
  _CdgFrame.copy(_CdgFrame source) : pixels=Uint8List.fromList(source.pixels),palette=Uint32List.fromList(source.palette),
    horizontal=source.horizontal,vertical=source.vertical,transparent=source.transparent;
  final Uint8List pixels;
  final Uint32List palette;
  int horizontal=0,vertical=0,transparent=-1;
}

/// Raw CD+G packets use 300 packets/second, independently of the audio codec.
/// Palette, scroll offsets and transparency travel with every seek checkpoint.
class CdgDecoder {
  CdgDecoder(this.data) {
    if(data.length%24!=0 || data.length>64*1024*1024) throw const FormatException('Invalid or oversized CD+G stream');
    _checkpoints[0]=_CdgFrame.copy(frame);
  }
  final Uint8List data;
  _CdgFrame frame=_CdgFrame();
  final Map<int,_CdgFrame> _checkpoints={};
  int packet=0,revision=0;
  void seek(int milliseconds) {
    final target=(milliseconds*300~/1000).clamp(0,data.length~/24);
    if(target==packet) return;
    if(target<packet) {
      var checkpoint=0;
      for(final key in _checkpoints.keys) { if(key<=target && key>checkpoint) checkpoint=key; }
      frame=_CdgFrame.copy(_checkpoints[checkpoint]!); packet=checkpoint;
    }
    while(packet<target) {
      _decode(packet*24); packet++;
      if(packet%1500==0) {
        _checkpoints[packet]=_CdgFrame.copy(frame);
        if(_checkpoints.length>64) _checkpoints.remove(_checkpoints.keys.firstWhere((k)=>k!=0));
      }
    }
    revision++;
  }
  void _decode(int offset) {
    if((data[offset]&63)!=9) return;
    final op=data[offset+1]&63;
    int d(int index)=>data[offset+4+index]&63;
    final pixels=frame.pixels;
    switch(op) {
      case 1:
        if((d(1)&15)==0) pixels.fillRange(0,pixels.length,d(0)&15);
      case 2:
        for(var y=0;y<216;y++) { for(var x=0;x<300;x++) { if(x<6 || x>=294 || y<12 || y>=204) pixels[y*300+x]=d(0)&15; } }
      case 6: case 38:
        final row=d(2)&31,column=d(3);
        if(row>=18 || column>=50) return;
        for(var y=0;y<12;y++) { for(var x=0;x<6;x++) {
          final color=d((d(4+y)&(1<<(5-x)))==0 ? 0 : 1)&15;
          final at=(row*12+y)*300+column*6+x;
          pixels[at]=op==38 ? pixels[at]^color : color;
        } }
      case 20: case 24:
        final h=(d(1)>>4)&3,v=(d(2)>>4)&3;
        frame.horizontal=(d(1)&7).clamp(0,5); frame.vertical=(d(2)&15).clamp(0,11);
        final dx=h==1 ? 6 : h==2 ? -6 : 0, dy=v==1 ? 12 : v==2 ? -12 : 0;
        if(dx==0 && dy==0) return;
        final old=Uint8List.fromList(pixels);
        for(var y=0;y<216;y++) { for(var x=0;x<300;x++) {
          final sx=x-dx,sy=y-dy;
          pixels[y*300+x]=op==20 && (sx<0 || sx>=300 || sy<0 || sy>=216) ? d(0)&15 : old[(sy%216)*300+sx%300];
        } }
      case 28: frame.transparent=d(0)&15;
      case 30: case 31:
        for(var i=0;i<8;i++) {
          final packed=(d(i*2)<<6)|d(i*2+1);
          frame.palette[(op==30 ? 0 : 8)+i]=0xff000000|(((packed>>8)&15)*17<<16)|(((packed>>4)&15)*17<<8)|((packed&15)*17);
        }
    }
  }
}

class CdgView extends StatelessWidget {
  const CdgView({super.key,required this.decoder,required this.positionMs});
  final CdgDecoder decoder;
  final int positionMs;
  @override Widget build(BuildContext context) {
    decoder.seek(positionMs);
    return Semantics(label:'CD+G karaoke graphics',image:true,child:AspectRatio(aspectRatio:4/3,
      child:CustomPaint(painter:_CdgPainter(decoder.frame,decoder.revision))));
  }
}
class _CdgPainter extends CustomPainter {
  _CdgPainter(this.frame,this.revision);
  final _CdgFrame frame;
  final int revision;
  @override void paint(Canvas canvas,Size size) {
    final paint=Paint()..isAntiAlias=false;
    final sx=size.width/288,sy=size.height/192;
    for(var y=0;y<192;y++) {
      var x=0;
      while(x<288) {
        int colorAt(int x)=>frame.pixels[(y+12+frame.vertical)*300+x+6+frame.horizontal];
        final color=colorAt(x),start=x++;
        while(x<288 && colorAt(x)==color) { x++; }
        if(color==frame.transparent) continue;
        paint.color=Color(frame.palette[color]);
        canvas.drawRect(Rect.fromLTRB(start*sx,y*sy,x*sx,(y+1)*sy),paint);
      }
    }
  }
  @override bool shouldRepaint(_CdgPainter old)=>revision!=old.revision || frame!=old.frame;
}
