import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'karaoke_models.dart';
import 'karaoke_preparation.dart';
import 'karaoke_session.dart';

class KaraokePreparationScreen extends StatefulWidget {
  const KaraokePreparationScreen({super.key,required this.session,required this.track,required this.client});
  final KaraokeSession session;
  final KaraokeTrack track;
  final KaraokePreparation client;
  @override State<KaraokePreparationScreen> createState()=>_KaraokePreparationScreenState();
}
class _KaraokePreparationScreenState extends State<KaraokePreparationScreen> {
  List<Map<String,dynamic>> _jobs=[];
  bool _busy=false;
  String? _error;
  Timer? _timer;
  @override void initState() { super.initState(); unawaited(_restore());_timer=Timer.periodic(const Duration(seconds:4),(_){if(!_busy)unawaited(_refresh());}); }
  @override void dispose() { _timer?.cancel();super.dispose(); }
  Future<void> _restore() async { try { await widget.client.restore();await _refresh(); } catch(e) {if(mounted)setState(()=>_error=e.toString());} }
  Future<void> run(Future<void> Function() action) async {
    if(_busy)return;setState((){_busy=true;_error=null;});
    try { await action();await _refresh(); } catch(e) {if(mounted)setState(()=>_error=e.toString());}
    finally {if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _refresh() async {
    try {
      final jobs=await widget.client.jobs();
      for(final j in jobs.where((j)=>j['renditionId']==widget.track.id && j['endpoint']==widget.client.endpoint.toString() && {'running','queued'}.contains(j['status']))) {
        await widget.client.refresh((j['request'] as Map)['id'] as String);
      }
      final updated=await widget.client.jobs();if(mounted)setState(()=>_jobs=updated.where((j)=>j['renditionId']==widget.track.id).toList().reversed.toList());
    } catch(e) {if(mounted)setState(()=>_error=e.toString());}
  }
  Future<void> configure() async {
    final url=TextEditingController(text:widget.client.endpoint?.toString() ?? 'http://127.0.0.1:59892'),token=TextEditingController();
    final apply=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('Preparation companion'),
      content:SizedBox(width:500,child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('Run the PlezyNG karaoke companion on your computer. HTTPS is required for a remote host. The token is saved in the OS credential store.'),
        TextField(controller:url,decoration:const InputDecoration(labelText:'Companion URL')),
        TextField(controller:token,obscureText:true,decoration:const InputDecoration(labelText:'Token')),
      ])),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Connect'))]));
    if(apply==true)await run(()=>widget.client.configure(url.text,token.text));url.dispose();token.dispose();
  }
  Future<void> submit(String kind)=>run(() async {
    final song=widget.track;
    final sources=song.assets.where((a)=>{KaraokeAssetKind.audio,KaraokeAssetKind.leadVocal,KaraokeAssetKind.video,KaraokeAssetKind.instrumental,KaraokeAssetKind.midi}.contains(a.kind)).toList();
    File? input;
    if(sources.isNotEmpty) {
      final asset=await showDialog<KaraokeAsset>(context:context,builder:(context)=>SimpleDialog(title:const Text('Choose the source asset'),
        children:sources.map((a)=>SimpleDialogOption(onPressed:()=>Navigator.pop(context,a),child:Text('${a.kind.name} · ${a.path}'))).toList()));
      if(asset==null)return;
      if(kind=='reference' && asset.kind!=KaraokeAssetKind.leadVocal && asset.kind!=KaraokeAssetKind.duetVocal)throw StateError('Pitch proposals require an isolated vocal stem');
      input=await widget.session.store.asset(song.id,asset.path);
    } else {
      final selection=await FilePicker.platform.pickFiles();final path=selection?.files.single.path;if(path==null)return;input=File(path);
      if(kind=='reference')throw StateError('Import an isolated vocal as a package stem first');
    }
    await widget.client.submit(kind,[input],{
      if(kind=='align')'lyrics':song.lyrics.lines.map((l)=>l.text).join('\n'),
      if(kind=='align')'language':song.language.isEmpty ? 'en' : song.language,
      if(kind=='reference')'isolatedVocal':true,
    },renditionId:song.id);
  });
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('Prepare ${widget.track.title}'),actions:[
    IconButton(tooltip:'Companion settings',onPressed:_busy ? null : configure,icon:const Icon(Icons.settings)),
  ]),body:ListView(padding:const EdgeInsets.all(16),children:[
    if(_busy)const LinearProgressIndicator(),if(_error!=null)Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
    const Text('Preparation runs between performances. Originals stay unchanged. Generated backing, alignment and pitch proposals must be auditioned and reviewed.'),
    if(widget.client.endpoint==null)FilledButton(onPressed:configure,child:const Text('Configure companion')),
    Wrap(spacing:12,runSpacing:8,children:[for(final entry in const {
      'separate':'Prepare backing + lead vocals','align':'Align approved lyrics','reference':'Propose notes from isolated vocals',
      'analyze':'Analyze key, tempo, chords','waveform':'Generate waveform','midi':'Render MIDI with approved soundfont',
    }.entries)OutlinedButton(onPressed:_busy || widget.client.endpoint==null || widget.session.hasPerformance ? null : ()=>submit(entry.key),child:Text(entry.value))]),
    const Divider(),
    for(final job in _jobs)Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('${(job['request'] as Map)['kind']} · ${job['status']}',style:Theme.of(context).textTheme.titleMedium),
      if((job['result'] as Map?)?['error']!=null)Text('${(job['result'] as Map)['error']}'),
      Wrap(spacing:8,children:[
        if({'queued','running'}.contains(job['status']))TextButton(onPressed:_busy ? null : ()=>run(()=>widget.client.cancel((job['request'] as Map)['id'] as String)),child:const Text('Cancel')),
        if({'failed','canceled','interrupted','submitting'}.contains(job['status']))TextButton(onPressed:_busy ? null : ()=>run(()=>widget.client.retry(job)),child:const Text('Retry / reconnect')),
        if({'completed','failed','canceled','interrupted'}.contains(job['status']))TextButton(onPressed:_busy ? null : ()=>run(()=>widget.client.remove((job['request'] as Map)['id'] as String)),child:const Text('Remove companion job')),
        if(job['status']=='completed')TextButton(onPressed:_busy ? null : ()=>run(() async {
          await widget.client.apply(widget.session.catalog[widget.track.id] ?? widget.track,Map<String,dynamic>.from(job['result'] as Map));
        }),child:const Text('Download / apply for review')),
      ]),
    ]))),
  ]));
}
