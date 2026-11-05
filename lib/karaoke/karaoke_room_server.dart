import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'karaoke_models.dart';
import 'karaoke_phone_input.dart';
import 'karaoke_integrations.dart';
import 'karaoke_session.dart';
import 'karaoke_web.dart';

enum KaraokeRoomRole { singer, display, host }
class _Grant {
  _Grant(this.role,this.expires,{this.singer});
  final KaraokeRoomRole role;
  final DateTime expires;
  final String? singer;
}

/// LAN-only room service. It never serves media files, source URLs, server
/// identifiers or provider credentials. Invitations and bearer grants are
/// memory-only, scoped to this room, revocable, and bounded by an expiry.
class KaraokeRoomServer extends ChangeNotifier {
  KaraokeRoomServer(this.session) { session.addListener(_sessionChanged); }
  final KaraokeSession session;
  late final phoneInputs=KaraokePhoneInputs(session);
  bool _secure=false;
  Timer? _inputExpiry;
  HttpServer? _server;
  String? _address;
  final _random=Random.secure();
  final Map<String,_Grant> _invites={},_grants={};
  final Map<String,({int second,int count})> _rates={};
  final Map<String,Map<String,dynamic>> _pairs={};
  Future<void> _pairSerial=Future.value();
  Timer? _expiry;
  bool _disposed=false;
  int _inflight=0;
  bool get running=>_server!=null;
  String? get origin=>_server==null ? null : '${_secure ? 'https' : 'http'}://$_address:${_server!.port}';
  int get guestCount=>_grants.values.where((g)=>g.role==KaraokeRoomRole.singer).length;
  String _token()=>base64UrlEncode(List.generate(32,(_)=>_random.nextInt(256))).replaceAll('=','');
  static Future<List<String>> addresses() async => [
    for(final interface in await NetworkInterface.list(type:InternetAddressType.IPv4,includeLoopback:false))
      for(final a in interface.addresses) if(_private(a.address)) a.address,
  ];
  static bool _private(String address) {
    final p=address.split('.').map(int.tryParse).toList();
    return p.length==4 && p.every((n)=>n!=null && n>=0 && n<=255) &&
      (p[0]==10 || p[0]==127 || (p[0]==192 && p[1]==168) || (p[0]==172 && p[1]!>=16 && p[1]!<=31) || (p[0]==169 && p[1]==254));
  }
  Future<void> start(String address,{SecurityContext? security}) async {
    await session.ready;
    if(!{...await addresses(),'127.0.0.1'}.contains(address)) throw ArgumentError('Choose a local IPv4 address');
    await stop();
    final server=security==null ? await HttpServer.bind(InternetAddress(address),0,shared:false) : await HttpServer.bindSecure(InternetAddress(address),0,security,shared:false);
    _secure=security!=null;
    server.idleTimeout=const Duration(seconds:15); _server=server; _address=address;
    server.listen((r)=>unawaited(_handle(r)),onError:(Object e)=>session.report(e));
    _expiry=Timer.periodic(const Duration(minutes:1),(_) {
      final now=DateTime.now(); _invites.removeWhere((_,g)=>g.expires.isBefore(now)); _grants.removeWhere((_,g)=>g.expires.isBefore(now));
      _rates.clear(); if(!_disposed)notifyListeners();
    });
    _inputExpiry=Timer.periodic(const Duration(seconds:1),(_)=>unawaited(phoneInputs.expire(_grants.keys.toSet(),stopAll:!session.playing).catchError(session.report)));
    notifyListeners();
  }
  String invitation(KaraokeRoomRole role) {
    if(!running)throw StateError('Open the guest songbook first');
    if(_invites.length>=32)throw StateError('Revoke old invitations before creating more');
    final token=_token(); _invites[token]=_Grant(role,DateTime.now().add(const Duration(minutes:30)));
    return '$origin/#$token';
  }
  void revokeGuests() { _grants.clear(); _invites.clear(); _pairs.clear();unawaited(phoneInputs.expire({},stopAll:true).catchError(session.report));notifyListeners(); }
  Future<void> stop() async {
    _expiry?.cancel(); _expiry=null;_inputExpiry?.cancel();_inputExpiry=null;await phoneInputs.expire({},stopAll:true);final server=_server; _server=null; _address=null;
    _grants.clear(); _invites.clear(); _pairs.clear(); _rates.clear();
    await server?.close(force:true); if(!_disposed)notifyListeners();
  }
  void _sessionChanged() { if(!_disposed)notifyListeners(); }
  Future<Map<String,dynamic>> _body(HttpRequest r) async {
    if(r.headers.contentType?.mimeType!='application/json') throw const FormatException('JSON required');
    if(r.contentLength>16384) throw const FormatException('Request too large');
    final data=<int>[];
    await for(final chunk in r.timeout(const Duration(seconds:8))) { if(data.length+chunk.length>16384)throw const FormatException('Request too large'); data.addAll(chunk); }
    final value=jsonDecode(utf8.decode(data));
    if(value is! Map<String,dynamic>)throw const FormatException('JSON object required');
    return value;
  }
  bool _allow(String key) {
    if(_rates.length>=512 && !_rates.containsKey(key))return false;
    final second=DateTime.now().millisecondsSinceEpoch~/1000, prior=_rates[key];
    final count=prior?.second==second ? prior!.count+1 : 1;
    _rates[key]=(second:second,count:count);
    return count<=12;
  }
  Future<void> _handle(HttpRequest r) async {
    final response=r.response;
    if(_inflight>=48){response.statusCode=503;await response.close();return;}_inflight++;
    response.headers.set('Cache-Control','no-store');
    response.headers.set('X-Content-Type-Options','nosniff');
    response.headers.set('Referrer-Policy','no-referrer');
    response.headers.set('Content-Security-Policy',"default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    response.headers.set('Permissions-Policy','camera=(), microphone=(self)');
    try {
      final remote=r.connectionInfo?.remoteAddress.address ?? '';
      final expected=origin;
      final host=r.headers.value('host');
      if(expected==null || !_private(remote) || host!=Uri.parse(expected).authority ||
          (r.headers.value('origin')!=null && r.headers.value('origin')!=expected)) {
        response.statusCode=403; response.write('Room origin rejected'); return;
      }
      if(!_allow('ip:$remote')) { response.statusCode=429; return; }
      final path=r.uri.path;
      if(r.method=='GET' && path=='/capture-worklet.js'){response.headers.contentType=ContentType('application','javascript');response.write(karaokeCaptureWorklet);return;}
      if(r.method=='GET' && path=='/') {
        response.headers.contentType=ContentType.html; response.write(karaokeGuestHtml); return;
      }
      response.headers.contentType=ContentType.json;
      if(r.method=='POST' && path=='/api/pair') {
        final body=await _body(r);
        final result=_pairSerial.then((_)=>_pair(body));
        _pairSerial=result.then<void>((_){}).catchError((Object _){});
        response.write(jsonEncode(await result)); return;
      }
      final token=r.headers.value('authorization')?.replaceFirst(RegExp(r'^Bearer '),'');
      final grant=_grants[token];
      if(grant==null || grant.expires.isBefore(DateTime.now())) { response.statusCode=401; response.write(jsonEncode({'error':'Invitation expired or revoked'})); return; }
      if(!_allow('grant:$token')) { response.statusCode=429; return; }
      if(r.method=='POST' && path=='/api/microphone'){
        if((!_secure && _address!='127.0.0.1') || grant.role!=KaraokeRoomRole.singer || grant.singer==null){response.statusCode=403;response.write(jsonEncode({'error':'Phone input requires HTTPS and a singer grant'}));return;}
        response.write(jsonEncode(await phoneInputs.command(token!,grant.singer!,await _body(r))));return;
      }
      if(path=='/api/integration') {
        if(grant.role!=KaraokeRoomRole.host){response.statusCode=403;return;}
        final bridge=KaraokeIntegrationBridge(session);
        if(r.method=='GET'){response.write(jsonEncode(bridge.hello()));return;}
        if(r.method=='POST'){response.write(jsonEncode(await bridge.execute(await _body(r),hostAuthorized:true)));return;}
      }
      if(r.method=='GET' && path=='/api/lyrics') { response.write(jsonEncode(session.track?.lyrics.toJson() ?? {'synced':false,'lines':[]})); return; }
      if(r.method=='GET' && path=='/api/state') { response.write(jsonEncode(_state(grant))); return; }
      if(r.method=='GET' && path=='/api/catalog') {
        final offset=(int.tryParse(r.uri.queryParameters['offset'] ?? '') ?? 0).clamp(0,2000);
        final query=r.uri.queryParameters['q'] ?? '';
        if(query.length>200)throw const FormatException('Search too long');
        final found=session.search(query,singerId:grant.singer).where((t)=>session.allowExplicit || !t.explicit).toList();
        response.write(jsonEncode({'revision':session.revision,'total':found.length,'songs':found.skip(offset).take(100).map((t)=>{
          'id':t.id,'title':t.title,'artist':t.artist,'language':t.language,'parts':t.parts.toList(),'explicit':t.explicit,
          'singAlongOnly':t.singAlongOnly,'scored':t.canScore,
          'favorite':session.singers.where((s)=>s.id==grant.singer).firstOrNull?.favorites.contains(t.id)==true,
        }).toList()})); return;
      }
      if(r.method=='POST' && path=='/api/command') {
        if(grant.role==KaraokeRoomRole.display) { response.statusCode=403; return; }
        final body=await _body(r),action=body['action'] as String;
        if(grant.role==KaraokeRoomRole.host && !{'request','cancel','approve','absent','reorder','start','pause','resume','restart','seek','finish','end','controls','settings','favorite','party','missingSongStatus'}.contains(action)) {
          response.statusCode=403; return;
        }
        final result=await session.command(body['id'] as String,body['revision'] as int,action,
          Map<String,dynamic>.from(body['payload'] as Map),guestSinger:grant.role==KaraokeRoomRole.singer ? grant.singer : null);
        response.write(jsonEncode(result)); return;
      }
      response.statusCode=404; response.write(jsonEncode({'error':'Unknown room operation'}));
    } on KaraokeConflict catch(e) { response.statusCode=409; response.write(jsonEncode({'error':e.toString(),'revision':e.revision})); }
      on FormatException catch(e) { response.statusCode=400; response.write(jsonEncode({'error':e.message})); }
      on StateError catch(e) { response.statusCode=409; response.write(jsonEncode({'error':e.message,'revision':session.revision})); }
      catch(_) { response.statusCode=500; response.write(jsonEncode({'error':'Room operation failed'})); }
    finally { _inflight--;await response.close(); }
  }
  Future<Map<String,dynamic>> _pair(Map<String,dynamic> body) async {
    final invite=body['invite'] as String, id=body['id'] as String;
    if(!RegExp(r'^[a-zA-Z0-9_-]{8,128}$').hasMatch(id)) throw const FormatException('Invalid pairing ID');
    final key='$invite:$id',name=(body['name'] as String? ?? '').trim();
    if(_pairs[key] case final prior?) {
      if(prior['name']!=name)throw StateError('Pairing ID reused');
      return prior;
    }
    final grant=_invites[invite];
    if(grant==null || grant.expires.isBefore(DateTime.now()))throw StateError('Invitation expired or revoked');
    if(_grants.length>=96 || _pairs.length>=128)throw StateError('Room guest limit reached');
    String? singer;
    if(grant.role==KaraokeRoomRole.singer) {
      final result=await session.host('singer',{'name':name}); singer=result['singerId'] as String;
    }
    final token=_token(),expires=DateTime.now().add(const Duration(hours:8));
    _grants[token]=_Grant(grant.role,expires,singer:singer);
    final result=<String,dynamic>{'token':token,'role':grant.role.name,'singerId':singer,'expires':expires.toUtc().toIso8601String(),'name':name};
    _pairs[key]=result;
    // Display and host handover links are single-use; singer links are shared QR.
    if(grant.role!=KaraokeRoomRole.singer)_invites.remove(invite);
    notifyListeners(); return result;
  }
  Map<String,dynamic> _state(_Grant grant) {
    final s=session,t=s.track;
    final missing=s.missingSongs.where((m)=>grant.role==KaraokeRoomRole.host || m.singerId==grant.singer).toList()
      ..sort((a,b) {
        final openOrder=(b.status=='open'?1:0).compareTo(a.status=='open'?1:0);
        return openOrder!=0 ? openOrder : b.createdMs.compareTo(a.createdMs);
      });
    return {'schema':1,'revision':s.revision,'epoch':s.epoch,'authority':s.authority,
      'serverTimeMs':DateTime.now().millisecondsSinceEpoch,'playing':s.playing,'positionMs':s.positionMs.value,'durationMs':s.durationMs,
      'allowVotes':s.allowVotes,
      'key':s.current?.key ?? 0,'tempo':s.current?.tempo ?? 1,'banner':s.banner,'stageColor':s.stageColor,
      'track':t==null ? null : {'id':t.id,'title':t.title,'artist':t.artist,'offsetMs':t.lyricOffsetMs+s.displayOffsetMs},
      'role':grant.role.name,'singerId':grant.singer,'phoneInput':{'available':_secure || _address=='127.0.0.1','activeSinger':s.current?.singers.contains(grant.singer)==true,'meters':grant.role==KaraokeRoomRole.host ? phoneInputs.meters : []},'party':s.party.view(),
      'singers':grant.role==KaraokeRoomRole.host ? s.singers.map((p)=>{'id':p.id,'name':p.name,'absent':p.absent}).toList() : null,
      'missingSongs':[for(final request in missing.take(320)) {
        'id':request.id,'title':request.title,'artist':request.artist,'language':request.language,'status':request.status,
        'createdMs':request.createdMs,'singer':s.singers.where((p)=>p.id==request.singerId).firstOrNull?.name ?? 'Singer',
      }],
      'queue':[for(final r in [if(s.current?.state==KaraokeRequestState.playing)s.current!,...s.rotation,...s.requests.where((r)=>r.state==KaraokeRequestState.pending)]) {
        'id':r.id,'title':s.catalog[r.trackId]?.title ?? '', 'singers':r.singers.map((id)=>s.singers.where((p)=>p.id==id).firstOrNull?.name ?? '').toList(),
        'state':r.state.name,'mine':grant.singer!=null && r.singers.contains(grant.singer),'waitMs':s.waitMs(r),
        'votes':r.votes.length,'voteScore':r.voteScore,'myVote':grant.singer==null ? 0 : r.votes[grant.singer] ?? 0,
      }],
    };
  }
  @override void dispose() { _disposed=true; session.removeListener(_sessionChanged); unawaited(stop()); super.dispose(); }
}
