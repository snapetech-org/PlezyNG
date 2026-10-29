import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'karaoke_models.dart';
import 'karaoke_preparation.dart';
import 'karaoke_session.dart';

class KaraokeTake {
  KaraokeTake(this.directory,this.metadata);
  final Directory directory;
  final Map<String,dynamic> metadata;
  String get id=>metadata['id'] as String;
  File get dry=>File(p.join(directory.path,'dry.wav'));
  bool get complete=>metadata['complete']==true;
}

class KaraokeTakes {
  KaraokeTakes(this.session);
  final KaraokeSession session;
  Future<List<KaraokeTake>> list() async {
    final root=Directory(p.join((await session.store.directory).path,'takes'));
    if(!await root.exists())return [];
    final takes=<KaraokeTake>[];
    await for(final directory in root.list(followLinks:false)) {
      if(directory is! Directory || takes.length>=1000)continue;
      final file=File(p.join(directory.path,'take.json'));
      if(!await file.exists() || await file.length()>1024*1024)continue;
      try {
        final j=jsonDecode(await file.readAsString()) as Map<String,dynamic>;
        if(j['schema']==1 && j['id']==p.basename(directory.path))takes.add(KaraokeTake(directory,j));
      } on FormatException { continue; }
    }
    takes.sort((a,b)=>(b.metadata['created'] as String? ?? '').compareTo(a.metadata['created'] as String? ?? ''));return takes;
  }
  Future<void> recover(KaraokeTake take) async {
    final size=await take.dry.length();
    if(size<44 || size>2*1024*1024*1024)throw const FormatException('Recording cannot be recovered');
    final source=await take.dry.open();late Uint8List header;
    try {header=await source.read(44);}finally{await source.close();}
    if(ascii.decode(header.sublist(0,4))!='RIFF' || ascii.decode(header.sublist(8,12))!='WAVE')throw const FormatException('Unknown recording container');
    final data=ByteData.sublistView(header);data.setUint32(4,size-8,Endian.little);data.setUint32(40,size-44,Endian.little);
    final pending=File('${take.dry.path}.repair'),sink=pending.openWrite();
    try {sink.add(header);await sink.addStream(take.dry.openRead(44));await sink.flush();}finally{await sink.close();}
    await take.dry.rename('${take.dry.path}.interrupted');await pending.rename(take.dry.path);
    take.metadata['frames']=(size-44)~/2;take.metadata['recovered']=true;take.metadata['complete']=true;
    take.metadata['score']=null;
    await File(p.join(take.directory.path,'take.json')).writeAsString(jsonEncode(take.metadata),flush:true);
  }
  Future<void> saveRecipe(KaraokeTake take,Map<String,dynamic> recipe) async {
    if(jsonEncode(recipe).length>65536)throw const FormatException('Recipe too large');
    await File(p.join(take.directory.path,'recipe.json')).writeAsString(jsonEncode({'schema':1,'recipe':recipe}),flush:true);
  }
  Future<Map<String,dynamic>> render(KaraokeTake take,KaraokePreparation client,Map<String,dynamic> recipe,{File? camera,List<KaraokeTake> partners=const []}) async {
    if(!take.complete)throw StateError('Recover and review the interrupted take first');
    final track=session.catalog[take.metadata['renditionId']];
    if(track==null)throw StateError('Original rendition is missing');
    final backing=track.assets.where((a)=>a.kind==KaraokeAssetKind.instrumental).firstOrNull ?? track.assets.where((a)=>a.kind==KaraokeAssetKind.audio).firstOrNull;
    if(backing==null)throw StateError('Export/download the backing as a local karaoke package before mixing');
    final input=await session.store.asset(track.id,backing.path);
    if(partners.length>3)throw StateError('A group mix supports four isolated takes');
    for(final partner in partners){if(partner.metadata['mergeApproved']!=true || !partner.complete ||
      partner.metadata['renditionId']!=track.id || partner.metadata['key']!=take.metadata['key'] || partner.metadata['tempo']!=take.metadata['tempo'] ||
      (partner.metadata['timeline'] as List? ?? []).isNotEmpty || (take.metadata['timeline'] as List? ?? []).isNotEmpty)throw StateError('Approve matching uninterrupted duet responses before mixing');}
    await saveRecipe(take,recipe);
    final result=await client.submit('render',[input,take.dry,...partners.map((p)=>p.dry),if(camera!=null)camera],{
      ...recipe,'key':take.metadata['key'],'tempo':take.metadata['tempo'],'sourceStartMs':take.metadata['sourceStartMs'],
      'inputOffsetMs':take.metadata['inputOffsetMs'],'timeline':take.metadata['timeline'] ?? [],
      'sampleRate':take.metadata['sampleRate'],'partners':[for(final p in partners){'id':p.id,'sourceStartMs':p.metadata['sourceStartMs'],'inputOffsetMs':p.metadata['inputOffsetMs'],'gain':1}],
      'cameraIndex':camera==null ? null : 2+partners.length,'video':camera!=null,'takeId':take.id,'lyrics':track.lyrics.toJson(),'lyricOffsetMs':track.lyricOffsetMs,
      'durationMs':(recipe['durationMs'] as num?) ?? ((take.metadata['frames'] as int)*1000/(take.metadata['sampleRate'] as int? ?? 48000)),
    },renditionId:track.id);
    take.metadata['renderJobId']=result['id'];await File(p.join(take.directory.path,'take.json')).writeAsString(jsonEncode(take.metadata),flush:true);return result;
  }
  Future<void> export(KaraokeTake take,String destination) async {
    final metadata=File(p.join(take.directory.path,'take.json'));
    final assets=<KaraokeAsset>[];
    for(final entry in [(take.dry,KaraokeAssetKind.audio),(metadata,KaraokeAssetKind.original)]) {
      assets.add(KaraokeAsset(path:p.basename(entry.$1.path),sha256:(await sha256.bind(entry.$1.openRead()).first).toString(),bytes:await entry.$1.length(),kind:entry.$2));
    }
    final track=KaraokeTrack(id:const Uuid().v4(),songId:take.metadata['renditionId'] as String,title:'Private take ${take.id}',assets:assets,tags:const ['private-take']);
    final data=utf8.encode(jsonEncode(track.toJson())),encoder=ZipFileEncoder()..create('$destination.pending');
    try {encoder.addArchiveFile(ArchiveFile('manifest.json',data.length,data));await encoder.addFile(take.dry,'dry.wav');await encoder.addFile(metadata,'take.json');}
    finally {await encoder.close();}
    await File('$destination.pending').rename(destination);
  }
  Future<void> createInvitation(KaraokeTrack track,String destination,{required double key,required double tempo,required String part}) async {
    if(!track.hasLocalAudio || (await session.packages.verify(track)).isNotEmpty)throw StateError('Duet invitations require a verified local backing package');
    if(!key.isFinite || key.abs()>12 || !tempo.isFinite || tempo<.5 || tempo>2 || part.isEmpty || part.length>80)throw const FormatException('Invalid duet settings');
    final id=const Uuid().v4();
    final invitation={'schema':'plezyng.karaoke-duet.v1','id':id,'renditionId':track.id,'songId':track.songId,
      'digests':track.assets.where((a)=>a.kind==KaraokeAssetKind.audio || a.kind==KaraokeAssetKind.instrumental).map((a)=>a.sha256).toList(),
      'title':track.title,'key':key,'tempo':tempo,'part':part,'expires':DateTime.now().toUtc().add(const Duration(days:14)).toIso8601String(),
      'mergeApprovalRequired':true,'private':true};
    await session.store.write('duet-$id',invitation);await File(destination).writeAsString(jsonEncode(invitation),flush:true);
  }
  Future<void> acceptInvitation(String path) async {
    final file=File(path);if(await file.length()>65536)throw const FormatException('Invitation too large');
    final invitation=jsonDecode(await file.readAsString()) as Map<String,dynamic>;
    final id=invitation['id'];
    if(invitation['schema']!='plezyng.karaoke-duet.v1' || id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
      DateTime.parse(invitation['expires'] as String).isBefore(DateTime.now()))throw const FormatException('Invalid or expired duet invitation');
    final track=session.catalog[invitation['renditionId']];
    if(track==null)throw StateError('Import the exact backing package before accepting this invitation');
    final key=(invitation['key'] as num).toDouble(),tempo=(invitation['tempo'] as num).toDouble(),part=invitation['part'] as String;
    if(!key.isFinite || key.abs()>12 || !tempo.isFinite || tempo<.5 || tempo>2 || part.isEmpty || part.length>80)throw const FormatException('Invalid duet settings');
    final digests=track.assets.where((a)=>a.kind==KaraokeAssetKind.audio || a.kind==KaraokeAssetKind.instrumental).map((a)=>a.sha256).toSet();
    if(digests.isEmpty || digests.length!=(invitation['digests'] as List).length || !(invitation['digests'] as List).every(digests.contains) ||
      (await session.packages.verify(track)).isNotEmpty)throw StateError('Invitation backing checksums do not match');
    if(session.hasPerformance)await session.stopPlayback();
    await session.store.write('duet-$id',invitation);session.duetInvitation=invitation;
  }
  Future<KaraokeTake> importResponse(String path) async {
    final result=await session.packages.importFiles([path]);
    try {
      final asset=result.track.assets.where((a)=>a.path=='take.json').firstOrNull;
      if(asset==null || asset.bytes>1024*1024)throw const FormatException('Missing take metadata');
      final metadata=jsonDecode(await (await session.store.asset(result.track.id,'take.json')).readAsString()) as Map<String,dynamic>;
      final invitationId=metadata['invitationId'];
      if(invitationId is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(invitationId))throw const FormatException('Response invitation ID missing');
      final invitation=await session.store.read('duet-$invitationId');
      if(invitation==null || DateTime.parse(invitation['expires'] as String).isBefore(DateTime.now()))throw StateError('Invitation missing or expired');
      if(metadata['complete']!=true || !{16000,48000}.contains(metadata['sampleRate']) || metadata['channels']!=1 ||
        jsonEncode(metadata['digests'])!=jsonEncode(invitation['digests']))throw const FormatException('Invalid take provenance or format');
      if(metadata['invitationId']!=invitationId || metadata['renditionId']!=invitation['renditionId'] || metadata['key']!=invitation['key'] || metadata['tempo']!=invitation['tempo'] || metadata['part']!=invitation['part'])throw const FormatException('Response does not match the fixed duet rendition/settings');
      final id=const Uuid().v4(),dir=await Directory(p.join((await session.store.directory).path,'takes',id)).create(recursive:true);
      await (await session.store.asset(result.track.id,'dry.wav')).copy(p.join(dir.path,'dry.wav'));
      metadata['id']=id;metadata['mergeApproved']=false;metadata['private']=true;metadata['score']=null;
      await File(p.join(dir.path,'take.json')).writeAsString(jsonEncode(metadata),flush:true);return KaraokeTake(dir,metadata);
    } finally {await session.packages.evict(result.track.id,pinned:session.pinned);}
  }
  Future<void> markListened(KaraokeTake take) async {take.metadata['listened']=true;await File(p.join(take.directory.path,'take.json')).writeAsString(jsonEncode(take.metadata),flush:true);}
  Future<void> approveMerge(KaraokeTake take) async {
    if(take.metadata['invitationId']==null || take.metadata['listened']!=true)throw StateError('Listen to the complete response before approving a duet merge');
    take.metadata['mergeApproved']=true;
    await File(p.join(take.directory.path,'take.json')).writeAsString(jsonEncode(take.metadata),flush:true);
  }
}
