import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';
import 'karaoke_collections.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

class KaraokeVenueScreen extends StatefulWidget {
  const KaraokeVenueScreen({super.key,required this.session});
  final KaraokeSession session;
  @override State<KaraokeVenueScreen> createState()=>_KaraokeVenueScreenState();
}
class _KaraokeVenueScreenState extends State<KaraokeVenueScreen> {
  KaraokeSession get s=>widget.session;
  late final collections=KaraokeCollections(s);
  bool busy=false;
  String? message;
  Future<void> run(Future<void> Function() action) async {
    if(busy)return;setState(()=>busy=true);
    try {await action();}catch(e){message=e.toString();}finally{if(mounted)setState(()=>busy=false);}
  }
  Future<String?> text(String title,{String initial='',bool obscure=false}) async {
    final input=TextEditingController(text:initial);
    final value=await showDialog<String>(context:context,builder:(context)=>AlertDialog(title:Text(title),content:TextField(
      controller:input,autofocus:true,obscureText:obscure,maxLength:160,onSubmitted:(v)=>Navigator.pop(context,v)),actions:[
      TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),
      FilledButton(onPressed:()=>Navigator.pop(context,input.text),child:const Text('Save'))]));input.dispose();return value;
  }
  Future<void> editSet(String? existing) async {
    final name=existing ?? await text('Setlist name');if(name==null || name.trim().isEmpty || !mounted)return;
    final selected=(s.setlists[name] ?? []).toSet();
    final saved=await showDialog<bool>(context:context,builder:(context)=>StatefulBuilder(builder:(context,update)=>AlertDialog(
      title:Text(name),content:SizedBox(width:500,height:400,child:ListView(children:[for(final t in s.search(''))CheckboxListTile(
        value:selected.contains(t.id),title:Text(t.title),subtitle:Text(t.artist),onChanged:(v)=>update(()=>v! ? selected.add(t.id) : selected.remove(t.id)))])),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Save setlist'))])));
    if(saved==true)await run(()=>s.host('setlist',{'name':name,'tracks':selected.toList()}).then((_){}));
  }
  Future<void> importCollection() async {
    final files=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['plezycollection','json']);
    final path=files?.files.single.path;if(path==null)return;
    final data=await collections.read(path);if(!mounted)return;
    final incoming=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('Resolve collection conflicts'),
      content:const Text('New singers and setlists will be added. Choose which preferences to keep when the same singer or setlist already exists. Media packages are imported separately.'),actions:[
        TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Keep existing preferences')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Use imported preferences'))]));
    if(incoming!=null)await collections.merge(data,preferIncoming:incoming);
  }
  Future<void> _fillers() async {
    final selected=s.fillerTrackIds.toSet(),choices=s.catalog.values.where((t)=>t.assets.any((a)=>a.kind==KaraokeAssetKind.instrumental)).toList();
    final ids=await showDialog<List<String>>(context:context,builder:(context)=>StatefulBuilder(builder:(context,update)=>AlertDialog(title:const Text('Instrumental filler'),
      content:SizedBox(width:500,height:420,child:ListView(children:[for(final t in choices)CheckboxListTile(title:Text(t.title),subtitle:Text(t.artist),value:selected.contains(t.id),
        onChanged:(v)=>update((){if(v==true && selected.length<16)selected.add(t.id);else if(v==false)selected.remove(t.id);} ))])),actions:[
        TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,selected.toList()),child:const Text('Save'))])));
    if(ids!=null)await run(()=>s.host('fillers',{'trackIds':ids}).then((_){}));
  }
  Future<void> kiosk() async {
    final pin=await text('Create a 4–12 digit kiosk exit PIN',obscure:true);
    if(pin==null)return;if(!RegExp(r'^\d{4,12}$').hasMatch(pin))throw const FormatException('Use 4–12 digits');
    if(!mounted)return;await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>_KaraokeKiosk(session:s,pin:pin)));
  }
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:s,builder:(context,_)=>Scaffold(
    appBar:AppBar(title:const Text('Venue, collections and readiness')),body:ListView(padding:const EdgeInsets.all(16),children:[
      if(busy)const LinearProgressIndicator(),if(message!=null)SelectableText(message!),
      ListTile(title:const Text('Stage banner'),subtitle:Text(s.banner),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:busy ? null : ()=>run(()async{
        final value=await text('Stage banner',initial:s.banner);if(value!=null)await s.host('settings',{'banner':value});}))),
      const Text('Stage text size'),Slider(min:.75,max:2,divisions:25,value:s.stageTextScale,onChanged:busy ? null : (v)=>run(()=>s.host('settings',{'stageTextScale':v}).then((_){}))),
      Text('Display offset: ${s.displayOffsetMs} ms'),Slider(min:-2000,max:2000,divisions:80,value:s.displayOffsetMs.toDouble().clamp(-2000,2000),
        onChanged:busy ? null : (v)=>run(()=>s.host('settings',{'displayOffsetMs':v.round()}).then((_){}))),
      Wrap(spacing:12,children:[for(final color in [0xff101018,0xff001524,0xff210b29,0xff000000])OutlinedButton(
        onPressed:busy ? null : ()=>run(()=>s.host('settings',{'stageColor':color}).then((_){})),child:Icon(Icons.circle,color:Color(color)))]),
      ListTile(title:const Text('Per-singer pending request limit'),trailing:DropdownButton<int>(value:s.perSingerLimit,
        items:[1,2,3,5,10].map((n)=>DropdownMenuItem(value:n,child:Text('$n'))).toList(),onChanged:busy ? null : (v)=>run(()=>s.host('settings',{'perSingerLimit':v}).then((_){})))),
      OutlinedButton(onPressed:busy ? null : ()=>run(kiosk),child:const Text('Open request kiosk')),
      const Text('The kiosk limits this screen to song requests. Use the operating system’s kiosk controls to restrict access to the rest of the device.'),
      const Divider(),Text('Saved sets',style:Theme.of(context).textTheme.titleLarge),
      TextButton(onPressed:busy ? null : ()=>editSet(null),child:const Text('Create a setlist')),
      for(final e in s.setlists.entries)ListTile(title:Text(e.key),subtitle:Text('${e.value.length} songs'),onTap:()=>editSet(e.key),trailing:Wrap(children:[
        IconButton(tooltip:'Queue this setlist',onPressed:busy || s.singers.where((p)=>!p.absent).isEmpty ? null : ()=>run(()=>s.host('requestSetlist',{'name':e.key,'singers':[s.singers.firstWhere((p)=>!p.absent).id]}).then((_){})),icon:const Icon(Icons.playlist_add)),
        IconButton(tooltip:'Audit complete offline assets',onPressed:busy ? null : ()=>run(()async{final errors=await collections.audit(e.value);message=errors.isEmpty ? 'Every rendition has local playback assets with matching checksums.' : errors.join('\n');}),icon:const Icon(Icons.offline_pin)),
        IconButton(tooltip:'Remove setlist',onPressed:busy ? null : ()=>run(()=>s.host('setlist',{'name':e.key,'remove':true}).then((_){})),icon:const Icon(Icons.delete_outline))])),
      const Divider(),Text('Instrumental filler',style:Theme.of(context).textTheme.titleLarge),
      const Text('Play a rotating local instrumental while the next singer prepares. It stops when the next karaoke request starts.'),
      OutlinedButton(onPressed:busy ? null : ()=>_fillers(),child:Text('${s.fillerTrackIds.length} filler renditions selected')),
      const Divider(),Text('Portability',style:Theme.of(context).textTheme.titleLarge),
      Wrap(spacing:12,runSpacing:8,children:[
        OutlinedButton(onPressed:busy ? null : ()=>run(()async{final file=await FilePicker.platform.saveFile(fileName:'karaoke.plezycollection');if(file!=null)await collections.export(file);}),child:const Text('Export singers, favorites and sets')),
        OutlinedButton(onPressed:busy ? null : ()=>run(importCollection),child:const Text('Import collection')),
        for(final format in ['csv','xml','html'])TextButton(onPressed:busy ? null : ()=>run(()async{final file=await FilePicker.platform.saveFile(fileName:'songbook.$format');if(file!=null)await collections.catalog(file,format);}),child:Text(format=='html' ? 'Print-ready songbook' : 'Catalog ${format.toUpperCase()}')),
      ]),
      const Text('Choose an existing synced folder in the system file picker to exchange these files. Imports resolve preferences explicitly; packages retain their rendition IDs and checksums.'),
      const Divider(),Text('Offline storage',style:Theme.of(context).textTheme.titleLarge),
      for(final t in s.catalog.values.where((t)=>t.assets.isNotEmpty))ListTile(title:Text(t.title),subtitle:Text('${(t.assets.fold<int>(0,(n,a)=>n+a.bytes)/1048576).toStringAsFixed(1)} MiB'),
        trailing:TextButton(onPressed:busy || s.pinned.contains(t.id) ? null : ()=>run(()async{await s.packages.evict(t.id,pinned:s.pinned);s.catalog.remove(t.id);await s.host('settings');}),child:const Text('Remove package'))),
      const Divider(),Text('This build',style:Theme.of(context).textTheme.titleLarge),
      const Text('Package import, lyric stage, CD+G, hosting, quizzes, editing and private collection export are implemented in source. Device qualification has not been performed.'),
      Text(PlatformDetector.isAppleTVSync() || PlatformDetector.isTizenBuild() || PlatformDetector.isWebOSBuild()
        ? 'Local microphone capture is unavailable in this TV build. Use external amplification. Key, tempo and stems require an MPV backend.'
        : 'Local microphone capture uses the native record plugin with explicit permission. Key, tempo and stems require an MPV backend. USB devices, Bluetooth latency and capture quality require device validation.'),
      const Text('Separation, alignment, analysis, MIDI rendering and take production require a configured companion with the corresponding dependencies and approved models. KaraFun OEM and public community services are unavailable until their contracts/services are supplied.'),
    ])));
}

class _KaraokeKiosk extends StatefulWidget {
  const _KaraokeKiosk({required this.session,required this.pin});
  final KaraokeSession session;
  final String pin;
  @override State<_KaraokeKiosk> createState()=>_KaraokeKioskState();
}
class _KaraokeKioskState extends State<_KaraokeKiosk> {
  String query='';String? singer,message;bool unlocked=false,busy=false;
  Future<void> unlock() async {
    final input=TextEditingController();final value=await showDialog<String>(context:context,builder:(context)=>AlertDialog(
      title:const Text('Host exit PIN'),content:TextField(controller:input,obscureText:true,keyboardType:TextInputType.number),actions:[
        TextButton(onPressed:()=>Navigator.pop(context,input.text),child:const Text('Unlock'))]));input.dispose();
    if(value==widget.pin && mounted){setState(()=>unlocked=true);WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)Navigator.pop(context);});}
  }
  Future<void> request(KaraokeTrack track) async {
    if(singer==null || busy)return;setState(()=>busy=true);
    try {final s=widget.session;await s.command('kiosk-${DateTime.now().microsecondsSinceEpoch}',s.revision,'request',{'trackId':track.id},guestSinger:singer);message='Request sent to the host';}
    catch(e){message=e.toString();}finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>PopScope(canPop:unlocked,child:Scaffold(appBar:AppBar(automaticallyImplyLeading:false,
    title:const Text('Request a song'),actions:[IconButton(tooltip:'Host unlock',onPressed:unlock,icon:const Icon(Icons.lock))]),body:Column(children:[
      if(message!=null)Padding(padding:const EdgeInsets.all(12),child:Text(message!)),
      DropdownButton<String>(value:singer,hint:const Text('Choose your singer name'),items:widget.session.singers.where((p)=>!p.absent).map((p)=>DropdownMenuItem(value:p.id,child:Text(p.name))).toList(),onChanged:(v)=>setState(()=>singer=v)),
      Padding(padding:const EdgeInsets.all(16),child:TextField(onChanged:(v)=>setState(()=>query=v),decoration:const InputDecoration(labelText:'Search songs'))),
      Expanded(child:ListView(children:[for(final track in widget.session.search(query))ListTile(title:Text(track.title),subtitle:Text(track.artist),
        trailing:FilledButton(onPressed:busy || singer==null ? null : ()=>request(track),child:const Text('Request')))])),
    ])));
}
