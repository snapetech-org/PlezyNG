import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../providers/multi_server_provider.dart';
import 'karaoke_models.dart';
import 'karaoke_editor.dart';
import 'karaoke_preparation.dart';
import 'karaoke_preparation_screen.dart';
import 'karaoke_audio.dart';
import 'karaoke_audio_panel.dart';
import 'karaoke_session.dart';
import 'karaoke_room_server.dart';
import 'karaoke_stage.dart';
import 'karaoke_strings.dart';

Future<void> openKaraoke(BuildContext context,{MediaItem? media}) async {
  final session=context.read<KaraokeSession>();
  final servers=context.read<MultiServerProvider>().serverManager;
  await session.ready;
  if(!context.mounted)return;
  if(media!=null) {
    try { await session.addMedia(media); } catch(e) { session.report(e); }
  }
  if(!context.mounted)return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>KaraokeScreen(session:session,
    searchRemote:(query) async {
      final results=await Future.wait(servers.visibleOnlineClients.values.map((c)=>c.searchItems(query,limit:30)));
      for(final item in results.expand((r)=>r).where((t)=>t.kind==MediaKind.track).take(100)) { await session.addMedia(item); }
    })));
}

class KaraokeScreen extends StatefulWidget {
  const KaraokeScreen({super.key,required this.session,required this.searchRemote});
  final KaraokeSession session;
  final Future<void> Function(String) searchRemote;
  @override State<KaraokeScreen> createState()=>_KaraokeScreenState();
}
class _KaraokeScreenState extends State<KaraokeScreen> {
  final _query=TextEditingController();
  String? _singer;
  bool _busy=false,_offline=false,_duet=false;
  int _tab=0;
  late final KaraokePreparation _preparation=KaraokePreparation(widget.session);
  late final KaraokeAudio _audio=KaraokeAudio(widget.session);
  late final KaraokeRoomServer _room=KaraokeRoomServer(widget.session);
  KaraokeSession get s=>widget.session;
  String tr(String key)=>karaokeText(context,key);
  @override void initState() { super.initState(); unawaited(_initialize()); }
  Future<void> _initialize() async { await s.ready; if(mounted)setState(()=>_singer=s.singers.firstOrNull?.id); }
  @override void dispose() {
    _query.dispose(); _room.dispose(); _audio.dispose(); _preparation.dispose();
    unawaited(s.stopPlayback().then((_)=>s.save()).catchError(s.report));
    super.dispose();
  }
  Future<void> _run(Future<void> Function() action) async {
    if(_busy)return;
    setState(()=>_busy=true);
    try { await action(); } catch(e) { s.report(e); }
    finally { if(mounted)setState(()=>_busy=false); }
  }
  Future<void> _command(String action,[Map<String,dynamic> payload=const {}]) => _run(() async { await s.host(action,payload); });
  Future<void> _addSinger() async {
    final input=TextEditingController();
    final name=await showDialog<String>(context:context,builder:(context)=>AlertDialog(title:Text(tr('addSinger')),
      content:TextField(controller:input,autofocus:true,maxLength:80,decoration:InputDecoration(labelText:tr('singerName')),
        onSubmitted:(value)=>Navigator.pop(context,value)),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:Text(tr('cancel'))),
        FilledButton(onPressed:()=>Navigator.pop(context,input.text),child:Text(tr('save')))]));
    input.dispose();
    if(name==null || name.trim().isEmpty)return;
    await _run(() async { final result=await s.host('singer',{'name':name}); _singer=result['singerId'] as String; });
  }
  Future<void> _import() => _run(() async {
    final selection=await FilePicker.platform.pickFiles(allowMultiple:true,type:FileType.custom,
      allowedExtensions:['zip','plezykaraoke','mp3','wav','ogg','flac','m4a','opus','mp4','mkv','webm','cdg','lrc','vtt','ttml','txt','ass','ssa','ttf','otf']);
    if(selection==null)return;
    final result=await s.packages.importFiles(selection.paths.whereType<String>().toList());
    await s.addTrack(result.track);
    if(result.warnings.isNotEmpty) s.report(result.warnings.join('\n'));
  });
  Future<void> _request(KaraokeTrack track,{bool start=false}) async {
    if(_singer==null) await _addSinger();
    if(_singer==null || !mounted)return;
    await _run(() async {
      final singer=s.singers.firstWhere((p)=>p.id==_singer);
      final result=await s.host('request',{'trackId':track.id,'singers':[_singer],
        'key':singer.keys[track.id] ?? 0,'tempo':singer.tempos[track.id] ?? 1});
      if(start) { await s.host('start',{'requestId':result['requestId']}); if(mounted)setState(()=>_tab=2); }
    });
  }
  Future<void> _guestRoom() => _run(() async {
    if(!_room.running) {
      final addresses=await KaraokeRoomServer.addresses();
      if(addresses.isEmpty) throw StateError('Connect to a local network to open a guest songbook');
      if(!mounted)return;
      final address=await showDialog<String>(context:context,builder:(context)=>SimpleDialog(title:Text(tr('guest')),
        children:addresses.map((a)=>SimpleDialogOption(onPressed:()=>Navigator.pop(context,a),child:Text(a))).toList()));
      if(address==null)return;
      await _room.start(address);
    }
    var link=_room.invitation(KaraokeRoomRole.singer);
    if(!mounted)return;
    await showDialog<void>(context:context,builder:(context)=>StatefulBuilder(builder:(context,update)=>AlertDialog(
      title:Text(tr('guest')),content:SizedBox(width:300,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        QrImageView(data:link,size:240,backgroundColor:Colors.white),SelectableText(link),
        const Text('This invitation expires in 30 minutes. Connected guests can request songs for 8 hours, until revoked or the room closes.'),
        TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:link)),child:const Text('Copy invitation')),
        TextButton(onPressed:()=>update(()=>link=_room.invitation(KaraokeRoomRole.display)),child:const Text('Create read-only stage link')),
        TextButton(onPressed:()=>update(()=>link=_room.invitation(KaraokeRoomRole.host)),child:const Text('Create one-use host handover link')),
        TextButton(onPressed:(){_room.revokeGuests();update(()=>link=_room.invitation(KaraokeRoomRole.singer));},child:const Text('Revoke guests and replace invitation')),
      ]))),actions:[TextButton(onPressed:() async { await _room.stop(); if(context.mounted)Navigator.pop(context); },child:const Text('Close room')),
        TextButton(onPressed:()=>Navigator.pop(context),child:Text(tr('close')))])));
  });
  Future<void> _stage() => Navigator.push(context,MaterialPageRoute<void>(builder:(context)=>AnimatedBuilder(animation:s,builder:(context,_)=>
    Scaffold(backgroundColor:Colors.black,body:Stack(children:[Positioned.fill(child:KaraokeStage(session:s)),
      SafeArea(child:Align(alignment:Alignment.topRight,child:IconButton.filledTonal(tooltip:tr('return'),
        onPressed:()=>Navigator.pop(context),icon:const Icon(Icons.close))))])))));

  @override Widget build(BuildContext context) => AnimatedBuilder(animation:s,builder:(context,_)=>Shortcuts(shortcuts:const {
    SingleActivator(LogicalKeyboardKey.escape):DismissIntent(),
  },child:Scaffold(appBar:AppBar(title:Text(tr('title')),actions:[
    IconButton(tooltip:tr('import'),onPressed:_busy ? null : _import,icon:const Icon(Icons.file_open)),
    IconButton(tooltip:tr('guest'),onPressed:_busy ? null : _guestRoom,icon:const Icon(Icons.qr_code)),
    IconButton(tooltip:tr('stage'),onPressed:_stage,icon:const Icon(Icons.fullscreen)),
    IconButton(tooltip:tr('stop'),onPressed:_busy ? null : ()=>_command('end'),icon:const Icon(Icons.stop_circle_outlined)),
  ]),body:Column(children:[
    if(_busy) const LinearProgressIndicator(),
    if(s.error!=null) MaterialBanner(content:Text(s.error!,maxLines:4),actions:[TextButton(onPressed:(){ s.error=null; setState((){}); },child:Text(tr('close')))]),
    Expanded(child:switch(_tab) { 0=>_library(),1=>_queue(),_=>_performance() }),
  ]),bottomNavigationBar:NavigationBar(selectedIndex:_tab,onDestinationSelected:(v)=>setState(()=>_tab=v),destinations:[
    NavigationDestination(icon:const Icon(Icons.library_music),label:tr('library')),
    NavigationDestination(icon:const Icon(Icons.group),label:tr('queue')),
    NavigationDestination(icon:const Icon(Icons.mic),label:tr('sing')),
  ]))));

  Widget _singerPicker() => Wrap(spacing:12,crossAxisAlignment:WrapCrossAlignment.center,children:[
    if(s.singers.isNotEmpty) DropdownButton<String>(value:s.singers.any((p)=>p.id==_singer) ? _singer : null,
      hint:Text(tr('singerName')),items:s.singers.map((p)=>DropdownMenuItem(value:p.id,child:Text(p.name))).toList(),
      onChanged:(value)=>setState(()=>_singer=value)),
    OutlinedButton.icon(onPressed:_busy ? null : _addSinger,icon:const Icon(Icons.person_add),label:Text(tr('addSinger'))),
  ]);
  Widget _library() {
    final tracks=s.search(_query.text,offline:_offline,duet:_duet,singerId:_singer);
    return Column(children:[Padding(padding:const EdgeInsets.all(16),child:Column(children:[
      TextField(controller:_query,onChanged:(_)=>setState((){}),onSubmitted:(q)=>_run(()=>widget.searchRemote(q)),
        decoration:InputDecoration(labelText:tr('search'),prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(
          tooltip:tr('refresh'),onPressed:_busy || _query.text.trim().length<2 ? null : ()=>_run(()=>widget.searchRemote(_query.text.trim())),icon:const Icon(Icons.cloud_sync)))),
      const SizedBox(height:12),_singerPicker(),Wrap(spacing:12,children:[
        FilterChip(label:Text(tr('offline')),selected:_offline,onSelected:(v)=>setState(()=>_offline=v)),
        FilterChip(label:Text(tr('duets')),selected:_duet,onSelected:(v)=>setState(()=>_duet=v)),
      ]),
    ])),Expanded(child:tracks.isEmpty ? Center(child:Padding(padding:const EdgeInsets.all(24),child:Text(tr('empty'),textAlign:TextAlign.center))) :
      ListView.builder(itemCount:tracks.length,itemBuilder:(context,i) {
        final track=tracks[i],favorite=s.singers.where((p)=>p.id==_singer).firstOrNull?.favorites.contains(track.id)==true;
        return ListTile(title:Text(track.title),subtitle:Text('${track.artist}\n${track.canScore ? tr('reviewed') : tr('notScored')}'),isThreeLine:true,
          leading:IconButton(tooltip:tr('favorite'),icon:Icon(favorite ? Icons.star : Icons.star_border),onPressed:_singer==null || _busy ? null :
            ()=>_command('favorite',{'singerId':_singer,'trackId':track.id,'value':!favorite})),
          onTap:_busy ? null : ()=>_request(track,start:!s.hasPerformance),trailing:PopupMenuButton<String>(onSelected:(action) async {
            switch(action) {
              case 'request': await _request(track);
              case 'prepare': if(mounted)await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>KaraokePreparationScreen(session:s,track:track,client:_preparation)));
              case 'editor': if(mounted)await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>KaraokeEditor(session:s,track:track)));
              case 'export': await _run(() async { final path=await FilePicker.platform.saveFile(fileName:'${track.id}.plezykaraoke'); if(path!=null) await s.packages.export(track,path); });
              case 'verify': await _run(() async { final missing=await s.packages.verify(track); if(missing.isNotEmpty) throw StateError(missing.join(', ')); });
            }
          },itemBuilder:(_)=>[
            PopupMenuItem(value:'request',child:Text(tr('request'))),
            PopupMenuItem(value:'editor',child:Text(tr('editor'))),
            const PopupMenuItem(value:'prepare',child:Text('Prepare backing, timing and guidance')),
            if(track.assets.isNotEmpty) PopupMenuItem(value:'export',child:Text(tr('export'))),
            if(track.assets.isNotEmpty) PopupMenuItem(value:'verify',child:Text(tr('verify'))),
          ]));
      })),
    ]);
  }
  Widget _queue() => ListView(padding:const EdgeInsets.all(16),children:[
    _singerPicker(),const SizedBox(height:12),
    SwitchListTile(title:Text(tr('fair')),value:s.fairRotation,onChanged:_busy ? null : (v)=>_command('settings',{'fairRotation':v})),
    SwitchListTile(title:Text(tr('approval')),value:s.requireApproval,onChanged:_busy ? null : (v)=>_command('settings',{'requireApproval':v})),
    SwitchListTile(title:Text(tr('explicit')),value:s.allowExplicit,onChanged:_busy ? null : (v)=>_command('settings',{'allowExplicit':v})),
    for(final singer in s.singers) CheckboxListTile(title:Text(singer.name),subtitle:Text(tr('absent')),value:singer.absent,
      onChanged:_busy ? null : (v)=>_command('absent',{'singerId':singer.id,'value':v})),
    const Divider(),
    if(s.current!=null) ListTile(title:Text('${tr('playing')}: ${s.track?.title ?? ''}'),trailing:TextButton(onPressed:_busy ? null :
      ()=>_command(s.hasPerformance ? 'finish' : 'start',s.hasPerformance ? {} : {'requestId':s.current!.id,'resume':true}),
      child:Text(tr(s.hasPerformance ? 'next' : 'resume')))),
    for(final request in [...s.requests.where((r)=>r.state==KaraokeRequestState.pending),...s.rotation])
      ListTile(title:Text(s.catalog[request.trackId]?.title ?? request.trackId),
        subtitle:Text('${request.singers.map((id)=>s.singers.where((p)=>p.id==id).firstOrNull?.name ?? id).join(' + ')} · ${tr(request.state.name)}\n${s.rotationReason(request)} · ~${(s.waitMs(request)/60000).ceil()} min'),
        trailing:Wrap(children:[IconButton(tooltip:tr(request.state==KaraokeRequestState.pending ? 'approve' : 'start'),
          onPressed:_busy || (s.hasPerformance && request.state==KaraokeRequestState.ready) ? null : ()=>_command(request.state==KaraokeRequestState.pending ? 'approve' : 'start',{'requestId':request.id}),
          icon:Icon(request.state==KaraokeRequestState.pending ? Icons.check : Icons.play_arrow)),
          IconButton(tooltip:tr('reject'),onPressed:_busy ? null : ()=>_command('cancel',{'requestId':request.id}),icon:const Icon(Icons.close))])),
  ]);
  Widget _performance() => LayoutBuilder(builder:(context,constraints) {
    final stage=SizedBox(height:constraints.maxHeight*.55,child:KaraokeStage(session:s));
    return ListView(children:[stage,Padding(padding:const EdgeInsets.all(16),child:Column(children:[
      Wrap(spacing:12,runSpacing:8,alignment:WrapAlignment.center,children:[
        FilledButton.icon(onPressed:_busy || !s.hasPerformance ? null : ()=>_command(s.playing ? 'pause' : 'resume'),
          icon:Icon(s.playing ? Icons.pause : Icons.play_arrow),label:Text(tr(s.playing ? 'pause' : 'resume'))),
        OutlinedButton(onPressed:_busy || !s.hasPerformance ? null : ()=>_command('finish'),child:Text(tr('next'))),
        OutlinedButton(onPressed:_busy || !s.hasPerformance ? null : ()=>_run(s.skipToSinging),child:Text(tr('skip'))),
        OutlinedButton(onPressed:_busy || !s.hasPerformance ? null : ()=>_run(s.undoSeek),child:Text(tr('undoSkip'))),
      ]),
      if(s.current case final request?) ...[
        Text('${tr('key')}: ${request.key.toStringAsFixed(0)}'),Slider(min:-12,max:12,divisions:24,value:request.key,
          onChanged:_busy || !s.hasPerformance ? null : (v)=>_command('controls',{'key':v,'tempo':request.tempo})),
        Text('${tr('tempo')}: ${(request.tempo*100).round()}%'),Slider(min:.5,max:2,divisions:30,value:request.tempo,
          onChanged:_busy || !s.hasPerformance ? null : (v)=>_command('controls',{'key':request.key,'tempo':v})),
        TextButton(onPressed:_busy || !s.hasPerformance ? null : ()=>_command('controls',{'key':0,'tempo':1}),child:Text(tr('reset'))),
        ValueListenableBuilder<int>(valueListenable:s.positionMs,builder:(context,position,_)=>Slider(
          min:0,max:s.durationMs>0 ? s.durationMs.toDouble() : 1,value:position.toDouble().clamp(0,s.durationMs>0 ? s.durationMs.toDouble() : 1),
          onChanged:_busy || !s.hasPerformance ? null : (v)=>_command('seek',{'positionMs':v.round()}))),
      ],
      if(s.mixer case final mixer?) ...[
        Text('Vocal mixer',style:Theme.of(context).textTheme.titleLarge),
        for(final stem in mixer.levels.entries) Row(children:[Expanded(child:Text(stem.key)),
          IconButton(tooltip:'Mute stem',onPressed:()=>_run(() async { await mixer.apply({...mixer.levels,stem.key:0});setState((){}); }),icon:const Icon(Icons.volume_off)),
          SizedBox(width:160,child:Slider(min:0,max:2,value:stem.value,onChanged:_busy ? null : (v)=>_run(() async { await mixer.apply({...mixer.levels,stem.key:v});setState((){}); }))),
        ]),
        Wrap(spacing:12,children:[TextButton(onPressed:()=>_run(() async { await mixer.guide(true);setState((){}); }),child:const Text('Guide vocals')),
          TextButton(onPressed:()=>_run(() async { await mixer.guide(false);setState((){}); }),child:const Text('Instrumental'))]),
      ],
      KaraokeAudioPanel(session:s,audio:_audio,singer:_singer),
      Wrap(spacing:12,children:[
        TextButton(onPressed:!s.hasPerformance ? null : ()=>s.setLoop(s.positionMs.value,null),child:Text(tr('loopStart'))),
        TextButton(onPressed:s.loopStartMs==null ? null : ()=>_run(() async { s.setLoop(s.loopStartMs,s.positionMs.value); }),child:Text(tr('loopEnd'))),
        TextButton(onPressed:()=>s.setLoop(null,null),child:Text(tr('clearLoop'))),
      ]),
    ]))]);
  });
}
