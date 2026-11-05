import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../mpv/models.dart';
import '../mpv/player/player.dart';
import '../services/playback_coordinator.dart';
import 'karaoke_preparation.dart';
import 'karaoke_session.dart';
import 'karaoke_takes.dart';

class KaraokeTakesScreen extends StatefulWidget {
  const KaraokeTakesScreen({super.key,required this.session,required this.client});
  final KaraokeSession session;
  final KaraokePreparation client;
  @override State<KaraokeTakesScreen> createState()=>_KaraokeTakesScreenState();
}
class _KaraokeTakesScreenState extends State<KaraokeTakesScreen> {
  late final _library=KaraokeTakes(widget.session);
  List<KaraokeTake> _takes=[];
  Player? _preview;
  StreamSubscription<bool>? _previewCompleted;
  bool _busy=false;
  String? _error;
  @override void initState(){super.initState();unawaited(run(()async{await widget.client.restore();}));}
  Future<void> run(Future<void> Function() action) async {
    if(_busy)return;setState(()=>_busy=true);
    try {await action();final takes=await _library.list();if(mounted)setState(()=>_takes=takes);}
    catch(e){if(mounted)setState(()=>_error=e.toString());}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> stopPreview() async {PlaybackCoordinator.instance.unregisterKaraoke(stopPreview);final sub=_previewCompleted;_previewCompleted=null;await sub?.cancel();final player=_preview;_preview=null;await player?.dispose();}
  Future<void> stopPreviewAndRestore() async {await stopPreview();await widget.session.restoreMusic();}
  Future<void> play(KaraokeTake take)=>run(()async{
    await stopPreview();await widget.session.stopPlayback();await widget.session.claimPlaybackResources();
    final player=Player.audio();_preview=player;PlaybackCoordinator.instance.registerKaraoke(stopPreview);
    _previewCompleted=player.streams.completed.listen((done){if(done){unawaited(_library.markListened(take).then((_) async {
      if(mounted){setState((){});await stopPreviewAndRestore();}
    }).catchError((Object error){if(mounted)setState(()=>_error=error.toString());}));}});
    await player.open(Media(take.dry.uri.toString()));
  });
  Future<void> produce(KaraokeTake take) async {
    var backing=.7,vocal=1.0,echo=0.0,gate=0.0;
    final trim=TextEditingController(text:'0'),duration=TextEditingController(text:((take.metadata['frames'] as int? ?? 0)*1000/(take.metadata['sampleRate'] as int? ?? 48000)).round().toString());
    var includeVideo=false,lyricOverlay=true;final selected=<String>{};final candidates=_takes.where((t)=>t.id!=take.id && t.metadata['mergeApproved']==true &&
      t.metadata['renditionId']==take.metadata['renditionId'] && t.metadata['invitationId']==take.metadata['invitationId'] &&
      t.metadata['key']==take.metadata['key'] && t.metadata['tempo']==take.metadata['tempo'] &&
      (take.metadata['part']==null || t.metadata['part']!=take.metadata['part'])).toList();
    final save=await showDialog<bool>(context:context,builder:(context)=>StatefulBuilder(builder:(context,update)=>AlertDialog(title:const Text('Mix and export privately'),
      content:SizedBox(width:500,child:SingleChildScrollView(child:Column(children:[
        const Text('The dry vocal stays unchanged. Choose gains, effects and trim for a new render.'),
        const Text('Backing'),Slider(min:0,max:2,value:backing,onChanged:(v)=>update(()=>backing=v)),
        const Text('Vocal'),Slider(min:0,max:2,value:vocal,onChanged:(v)=>update(()=>vocal=v)),
        const Text('Echo wet'),Slider(min:0,max:.6,value:echo,onChanged:(v)=>update(()=>echo=v)),
        const Text('Noise gate'),Slider(min:0,max:.2,value:gate,onChanged:(v)=>update(()=>gate=v)),
        TextField(controller:trim,decoration:const InputDecoration(labelText:'Trim start (ms)'),keyboardType:TextInputType.number),
        TextField(controller:duration,decoration:const InputDecoration(labelText:'Output duration (ms)'),keyboardType:TextInputType.number),
        for(final partner in candidates)CheckboxListTile(title:Text('Mix approved response ${partner.id}'),value:selected.contains(partner.id),onChanged:(v)=>update(()=>v! ? selected.add(partner.id) : selected.remove(partner.id))),
        CheckboxListTile(title:const Text('Include a camera/video file I choose'),value:includeVideo,onChanged:(v)=>update(()=>includeVideo=v!)),
        if(includeVideo)CheckboxListTile(title:const Text('Overlay timed lyrics'),value:lyricOverlay,onChanged:(v)=>update(()=>lyricOverlay=v!)),
      ]))),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Render'))])));
    try {
      if(save!=true)return;
      await run(()async{
        await stopPreview();File? camera;
        if(includeVideo){final selected=await FilePicker.platform.pickFiles(type:FileType.video);final path=selected?.files.single.path;if(path==null)return;camera=File(path);}
        await _library.render(take,widget.client,{'backingGain':backing,'vocalGain':vocal,'echoWet':echo,'gate':gate,
          'lyricOverlay':lyricOverlay,'trimStartMs':int.parse(trim.text),'durationMs':int.parse(duration.text)},camera:camera,partners:candidates.where((t)=>selected.contains(t.id)).toList());
      });
    }finally{trim.dispose();duration.dispose();}
  }
  Future<void> download(KaraokeTake take)=>run(()async{
    final result=await widget.client.refresh(take.metadata['renderJobId'] as String),dir=await widget.client.download(result);
    final file=File(p.join(dir.path,'performance.mp4'));final media=await file.exists() ? file : File(p.join(dir.path,'performance.wav'));
    final destination=await FilePicker.platform.saveFile(fileName:p.basename(media.path));if(destination!=null)await media.copy(destination);
  });
  @override void dispose(){unawaited(stopPreview().then((_)=>widget.session.restoreMusic()).catchError((Object error){widget.session.report(error);}));super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Private takes'),actions:[
    IconButton(tooltip:'Stop preview',onPressed:stopPreviewAndRestore,icon:const Icon(Icons.stop)),
    IconButton(tooltip:'Refresh',onPressed:()=>run(()async{}),icon:const Icon(Icons.refresh)),
  ]),body:ListView(padding:const EdgeInsets.all(16),children:[
    if(_busy)const LinearProgressIndicator(),if(_error!=null)Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
    Wrap(spacing:12,children:[OutlinedButton(onPressed:_busy ? null : ()=>run(()async{final pick=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['plezyduet']);final path=pick?.files.single.path;if(path!=null)await _library.acceptInvitation(path);}),child:const Text('Accept duet invitation')),
      OutlinedButton(onPressed:_busy ? null : ()=>run(()async{final pick=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['plezytake']);final path=pick?.files.single.path;if(path!=null)await _library.importResponse(path);}),child:const Text('Import duet response'))]),
    if(widget.session.duetInvitation case final invitation?)Text('${invitation['owner']==true ? 'Host invitation' : 'Accepted invitation'}: ${invitation['title']}. Use the assigned part and keep the backing rendition, key, and tempo fixed.'),
    const Text('Recordings remain private. Export creates a file you can choose to share. Rendering uses your configured preparation companion.'),
    for(final take in _takes)Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(widget.session.catalog[take.metadata['renditionId']]?.title ?? take.id,style:Theme.of(context).textTheme.titleLarge),
      Text('${take.metadata['created']} · ${take.metadata['listened']==true ? 'Listened' : 'Unreviewed'} · key ${take.metadata['key']} · tempo ${take.metadata['tempo']} · ${take.complete ? 'Saved' : 'Interrupted'}'),
      Wrap(spacing:10,runSpacing:8,children:[
        if(!take.complete)TextButton(onPressed:_busy ? null : ()=>run(()=>_library.recover(take)),child:const Text('Recover recording')),
        if(take.complete && take.metadata['invitationId']==null && widget.session.duetInvitation?['owner']==true &&
          widget.session.duetInvitation?['renditionId']==take.metadata['renditionId'])
          TextButton(onPressed:_busy ? null : ()=>run(()=>_library.linkToInvitation(take)),child:const Text('Link this take to the duet invitation')),
        TextButton(onPressed:_busy || !take.complete ? null : ()=>play(take),child:const Text('Listen to dry take')),
        TextButton(onPressed:_busy || !take.complete ? null : ()=>produce(take),child:const Text('Mix / export audio or video')),
        TextButton(onPressed:_busy ? null : ()=>run(()async{final file=await FilePicker.platform.saveFile(fileName:'${take.id}.plezytake');if(file!=null)await _library.export(take,file);}),child:const Text('Export portable take')),
        if(take.metadata['renderJobId']!=null)TextButton(onPressed:_busy ? null : ()=>download(take),child:const Text('Download completed render')),
        if(take.metadata['invitationId']!=null && take.metadata['mergeApproved']!=true)
          TextButton(onPressed:_busy ? null : ()=>run(()=>_library.approveMerge(take)),child:const Text('Approve duet merge after listening')),
      ]),
    ]))),
  ]));
}
