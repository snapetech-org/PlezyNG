import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../media/lyrics.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

/// Explicitly configured companion; token stays in the OS credential store.
/// Redirects, insecure remote HTTP, guest-supplied URLs and unbounded responses
/// are not accepted. No requests run until configuration or a job is chosen.
class KaraokePreparation {
  KaraokePreparation(this.session);
  final KaraokeSession session;
  final HttpClient _client=HttpClient()..connectionTimeout=const Duration(seconds:10);
  final _secure=const FlutterSecureStorage();
  Uri? endpoint;
  String? _token;
  Map<String,dynamic>? capabilities;
  String get _secretKey=>'karaoke-companion-${sha256.convert(utf8.encode(session.store.profileId))}';
  Future<void> restore() async {
    final settings=await session.store.read('preparation');
    if(settings?['endpoint'] case final String url) { endpoint=_endpoint(url);_token=await _secure.read(key:_secretKey); }
  }
  static Uri _endpoint(String value) {
    final uri=Uri.parse(value.trim());
    if(!uri.hasAuthority || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment || (uri.path.isNotEmpty && uri.path!='/') ||
      (uri.scheme!='https' && !(uri.scheme=='http' && {'127.0.0.1','localhost','::1'}.contains(uri.host)))) {
      throw const FormatException('Use an HTTPS companion URL, or HTTP on localhost');
    }
    return uri.replace(path:'');
  }
  Future<void> configure(String url,String token) async {
    if(token.length<32 || token.length>512 || token.contains('\n'))throw const FormatException('Invalid companion token');
    final oldEndpoint=endpoint,oldToken=_token;endpoint=_endpoint(url);_token=token;
    try { capabilities=await jsonRequest('GET','/v1/capabilities'); }
    catch(_) { endpoint=oldEndpoint;_token=oldToken;rethrow; }
    await _secure.write(key:_secretKey,value:token);
    final settings=await session.store.read('preparation') ?? <String,dynamic>{};settings['endpoint']=endpoint.toString();
    await session.store.write('preparation',settings);
  }
  Future<HttpClientRequest> _request(String method,String path) async {
    if(endpoint==null || _token==null)throw StateError('Configure a karaoke companion first');
    final request=await _client.openUrl(method,endpoint!.replace(path:path));
    request.followRedirects=false;request.headers.set(HttpHeaders.authorizationHeader,'Bearer $_token');return request;
  }
  Future<Map<String,dynamic>> _json(HttpClientResponse response) async {
    final bytes=<int>[];
    await for(final chunk in response.timeout(const Duration(seconds:30))) {
      if(bytes.length+chunk.length>8*1024*1024)throw const FormatException('Companion response too large');bytes.addAll(chunk);
    }
    final value=jsonDecode(utf8.decode(bytes)) as Map<String,dynamic>;
    if(response.statusCode<200 || response.statusCode>=300)throw StateError(value['error'] as String? ?? 'Companion request failed');
    return value;
  }
  Future<Map<String,dynamic>> jsonRequest(String method,String path,[Map<String,dynamic>? body]) async {
    final r=await _request(method,path);
    if(body!=null) { final data=utf8.encode(jsonEncode(body));r.headers.contentType=ContentType.json;r.contentLength=data.length;r.add(data); }
    return _json(await r.close().timeout(const Duration(seconds:30)));
  }
  Future<String> upload(File file) async {
    final size=await file.length();if(size>512*1024*1024)throw const FormatException('Companion input limit is 512 MiB');
    final digest=(await sha256.bind(file.openRead()).first).toString();
    final request=await _request('POST','/v1/assets');request.contentLength=size;request.headers.contentType=ContentType.binary;
    await request.addStream(file.openRead());final result=await _json(await request.close());
    if(result['id']!=digest || result['bytes']!=size)throw const FormatException('Upload identity mismatch');return digest;
  }
  Future<Map<String,dynamic>> submit(String kind,List<File> inputs,Map<String,dynamic> params,{String? renditionId}) async {
    if(session.hasPerformance)throw StateError('Prepare audio between performances');
    final assets=<String>[];for(final file in inputs) { assets.add(await upload(file)); }
    final id=const Uuid().v4();
    final request={'id':id,'kind':kind,'assets':assets,'params':params};
    // Save the exact request before submission, so reconnect retries reuse it.
    final settings=await session.store.read('preparation') ?? <String,dynamic>{};
    final jobs=List<Map<String,dynamic>>.from((settings['jobs'] as List? ?? []).map((j)=>Map<String,dynamic>.from(j as Map)));
    jobs.add({'request':request,'renditionId':renditionId,'endpoint':endpoint.toString(),'status':'submitting'});
    if(jobs.length>100)jobs.removeAt(0);settings['jobs']=jobs;await session.store.write('preparation',settings);
    final result=await jsonRequest('POST','/v1/jobs',request);await remember(result);return result;
  }
  Future<void> remember(Map<String,dynamic> result) async {
    final settings=await session.store.read('preparation') ?? <String,dynamic>{};
    for(final job in settings['jobs'] as List? ?? []) {
      if((job['request'] as Map)['id']==result['id']) { job['status']=result['status'];job['result']=result; }
    }
    await session.store.write('preparation',settings);
  }
  Future<List<Map<String,dynamic>>> jobs() async => [for(final j in (await session.store.read('preparation'))?['jobs'] as List? ?? [])Map<String,dynamic>.from(j as Map)];
  Future<Map<String,dynamic>> refresh(String id) async { final result=await jsonRequest('GET','/v1/jobs/$id');await remember(result);return result; }
  Future<void> cancel(String id) async { await remember(await jsonRequest('DELETE','/v1/jobs/$id')); }
  Future<void> retry(Map<String,dynamic> job) async {
    if(job['endpoint']!=endpoint.toString())throw StateError('Restore this job’s original companion connection');
    final request=Map<String,dynamic>.from(job['request'] as Map);
    if({'failed','canceled','interrupted'}.contains(job['status']))request['id']=const Uuid().v4();
    final result=await jsonRequest('POST','/v1/jobs',request);
    final settings=await session.store.read('preparation') ?? <String,dynamic>{};
    final values=settings['jobs'] as List? ?? [];values.add({...job,'request':request,'status':result['status'],'result':result});settings['jobs']=values;
    await session.store.write('preparation',settings);
  }
  Future<Directory> download(Map<String,dynamic> result) async {
    if(result['status']!='completed')throw StateError('Preparation is not complete');
    final id=result['id'] as String;if(!RegExp(r'^[a-zA-Z0-9_-]{8,128}$').hasMatch(id))throw const FormatException('Invalid result ID');
    final directory=await Directory(p.join((await session.store.directory).path,'prepared',id)).create(recursive:true);
    final files=(result['result'] as Map)['files'] as List;
    if(files.length>32)throw const FormatException('Too many result files');
    var total=0;
    for(final raw in files) {
      final j=Map<String,dynamic>.from(raw as Map),name=j['name'] as String,size=j['bytes'] as int,hash=j['sha256'] as String;
      if(!RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(name) || name.startsWith('.') || size<0 || size>1024*1024*1024 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))throw const FormatException('Invalid prepared asset');
      total+=size;if(total>2*1024*1024*1024)throw const FormatException('Prepared output too large');
      final file=File(p.join(directory.path,name));
      if(await file.exists() && await file.length()==size && (await sha256.bind(file.openRead()).first).toString()==hash)continue;
      final request=await _request('GET','/v1/jobs/$id/files/$name'),response=await request.close();
      if(response.statusCode!=200)throw StateError('Could not fetch prepared asset');
      final temp=File('${file.path}.pending'),sink=temp.openWrite();var received=0;
      try {
        await for(final data in response.timeout(const Duration(seconds:30))) { received+=data.length;if(received>size)throw const FormatException('Prepared asset overflow');sink.add(data); }
        await sink.flush();await sink.close();
        if(received!=size || (await sha256.bind(temp.openRead()).first).toString()!=hash)throw const FormatException('Prepared asset checksum mismatch');
        await temp.rename(file.path);
      } catch(_) { await sink.close();if(await temp.exists())await temp.delete();rethrow; }
    }
    await File(p.join(directory.path,'provenance.json')).writeAsString(jsonEncode(result),flush:true);return directory;
  }
  Future<KaraokeTrack> apply(KaraokeTrack track,Map<String,dynamic> result) async {
    final dir=await download(result),kind=result['kind'];
    if(kind=='align') {
      final lyrics=Lyrics.fromJson(jsonDecode(await File(p.join(dir.path,'lyrics.json')).readAsString()) as Map<String,dynamic>);
      final value=track.withLyrics(lyrics,reviewed:false);await session.addTrack(value);return value;
    }
    if(kind=='reference') {
      final j=jsonDecode(await File(p.join(dir.path,'notes.json')).readAsString()) as Map<String,dynamic>;
      final notes=(j['notes'] as List).map((n)=>KaraokeNote.fromJson(Map<String,dynamic>.from(n as Map))).toList();
      final value=track.withLyrics(track.lyrics,chart:notes,reviewed:false);await session.addTrack(value);return value;
    }
    if(kind=='separate' || kind=='midi') {
      if(track.media!=null)throw StateError('Attach original audio as a local package before publishing stems');
      final id=const Uuid().v4(),staging=await Directory(p.join(dir.path,'package-$id')).create();
      final assets=<KaraokeAsset>[];
      for(final asset in track.assets.where((a)=>!{KaraokeAssetKind.instrumental,KaraokeAssetKind.leadVocal,KaraokeAssetKind.backingVocal,KaraokeAssetKind.duetVocal}.contains(a.kind))) {
        final destination=File(p.join(staging.path,asset.path));await destination.parent.create(recursive:true);
        await (await session.store.asset(track.id,asset.path)).copy(destination.path);assets.add(asset);
      }
      for(final name in [if(kind=='separate')'lead.wav','instrumental.wav']) {
        final file=await File(p.join(dir.path,name)).copy(p.join(staging.path,'generated-$name'));
        assets.add(KaraokeAsset(path:p.basename(file.path),sha256:(await sha256.bind(file.openRead()).first).toString(),bytes:await file.length(),
          kind:name=='lead.wav' ? KaraokeAssetKind.leadVocal : KaraokeAssetKind.instrumental,clockId:id));
      }
      final provenance=await File(p.join(dir.path,'provenance.json')).copy(p.join(staging.path,'preparation.json'));
      assets.add(KaraokeAsset(path:'preparation.json',sha256:(await sha256.bind(provenance.openRead()).first).toString(),bytes:await provenance.length(),kind:KaraokeAssetKind.original));
      final value=KaraokeTrack.fromJson(track.toJson()..['id']=id..['assets']=assets.map((a)=>a.toJson()).toList()..['chartReviewed']=false
        ..['tags']=[...track.tags,'generated-backing','review-required']);
      await File(p.join(staging.path,'manifest.json')).writeAsString(jsonEncode(value.toJson()));
      // Feed the same bounded package validation path used by user imports.
      final archive=p.join(dir.path,'package-$id.plezykaraoke');
      final encoder=ZipFileEncoder()..create(archive);
      try { await encoder.addDirectory(staging,includeDirName:false,followLinks:false); } finally { await encoder.close(); }
      final imported=await session.packages.importFiles([archive]);await session.addTrack(imported.track);return imported.track;
    }
    return track;
  }
  void dispose()=>_client.close(force:true);
}
