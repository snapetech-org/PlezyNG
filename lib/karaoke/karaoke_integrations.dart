import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

/// A provider is advertised only after a real adapter negotiates these
/// capabilities. Registration does not grant catalog or performance rights.
enum KaraokeProviderCapability { catalog, authentication, entitlement, playback, download, stems, syllables, notes, reporting }
class KaraokeProviderOffer {
  const KaraokeProviderOffer({required this.track,required this.entitled,required this.expires,required this.capabilities});
  final KaraokeTrack track;
  final bool entitled;
  final DateTime? expires;
  final Set<KaraokeProviderCapability> capabilities;
  bool get playable=>entitled && capabilities.contains(KaraokeProviderCapability.playback) && (expires==null || expires!.isAfter(DateTime.now()));
}
abstract interface class KaraokeProvider {
  String get id;
  int get contractVersion;
  Future<Set<KaraokeProviderCapability>> negotiate();
  Future<List<KaraokeProviderOffer>> search(String query,{required int offset,required int limit});
  Future<KaraokeProviderOffer> entitlement(String renditionId);
  Future<Uri> authorizePlayback(String renditionId);
  Future<Map<String,dynamic>> authorizeDownload(String renditionId);
  Future<void> reportPerformance(String renditionId,String idempotencyKey,Duration played);
  Future<void> signOut();
}
class KaraokeProviders {
  final Map<String,KaraokeProvider> _providers={};
  final Map<String,Set<KaraokeProviderCapability>> _capabilities={};
  Future<void> register(KaraokeProvider provider) async {
    if(provider.contractVersion!=1 || !RegExp(r'^[a-z0-9_-]{1,80}$').hasMatch(provider.id))throw const FormatException('Unsupported provider contract');
    final capabilities=await provider.negotiate();_providers[provider.id]=provider;_capabilities[provider.id]=Set.unmodifiable(capabilities);
  }
  Future<List<KaraokeProviderOffer>> search(String query) async {
    final results=<KaraokeProviderOffer>[];
    for(final entry in _providers.entries) {
      if(_capabilities[entry.key]?.contains(KaraokeProviderCapability.catalog)!=true)continue;
      results.addAll((await entry.value.search(query,offset:0,limit:100)).where((offer)=>offer.playable));
    }
    return results;
  }
  Future<Uri> playback(String providerId,String renditionId) async {
    final provider=_providers[providerId];if(provider==null)throw StateError('Provider adapter is unavailable');
    if(!(await provider.entitlement(renditionId)).playable)throw StateError('This rendition is not currently entitled');
    final uri=await provider.authorizePlayback(renditionId);
    if(uri.scheme!='https' || uri.userInfo.isNotEmpty)throw const FormatException('Provider returned an unsafe playback URL');return uri;
  }
  Map<String,dynamic> get status=>{
    for(final e in _capabilities.entries)e.key:{'version':1,'capabilities':e.value.map((v)=>v.name).toList()},
    if(!_providers.containsKey('karafun'))'karafun':{'available':false,'reason':'OEM contract, SDK and credentials have not been supplied'},
  };
}

/// SeerrNG/relay transport-independent bridge. The host remains the sole queue
/// authority. An adapter may forward these envelopes over an authenticated
/// channel; tokens and media URLs never belong in them.
class KaraokeIntegrationBridge {
  KaraokeIntegrationBridge(this.session);
  final KaraokeSession session;
  static const protocol='plezyng.karaoke.v1';
  Map<String,dynamic> hello()=>{'protocol':protocol,'authority':'plezyng','revision':session.revision,'epoch':session.epoch,
    'commands':['request','cancel','approve','reorder','start','pause','resume','finish','seek','end'],
    'catalog':[for(final t in session.catalog.values){'songId':t.songId,'renditionId':t.id,'title':t.title,'artist':t.artist,
      'packageDigest':sha256.convert(utf8.encode(jsonEncode(t.assets.map((a)=>a.toJson()).toList()))).toString(),
      'readiness':t.assets.isEmpty ? 'source-dependent' : 'local-unverified'}]};
  Future<Map<String,dynamic>> execute(Map<String,dynamic> envelope,{required bool hostAuthorized}) async {
    if(!hostAuthorized)throw StateError('An authenticated host capability is required');
    if(envelope['protocol']!=protocol || envelope['authority']!='plezyng')throw const FormatException('Protocol/queue-authority mismatch');
    final action=envelope['command'] as String;
    if(!{'request','cancel','approve','reorder','start','pause','resume','finish','seek','end'}.contains(action))throw const FormatException('Unsupported integration command');
    final result=await session.command(envelope['id'] as String,envelope['expectedRevision'] as int,action,
      Map<String,dynamic>.from(envelope['payload'] as Map));
    return {'protocol':protocol,'id':envelope['id'],'ack':result,'playback':{'epoch':session.epoch,'playing':session.playing,
      'sourcePositionMs':session.positionMs.value,'renditionId':session.track?.id}};
  }
}

/// Playback epochs reject stale remote state. A receiver must own the same
/// authorized rendition locally; this protocol never mixes internet vocals.
class KaraokeRemoteClock {
  int epoch=-1,revision=-1;
  double roundTripMs=0,offsetMs=0;
  void sample({required int sentMs,required int receivedMs,required int serverMs}) {
    final rtt=receivedMs-sentMs;if(rtt<0 || rtt>10000)throw const FormatException('Invalid clock sample');
    if(roundTripMs==0 || rtt<roundTripMs*1.5){roundTripMs=rtt.toDouble();offsetMs=serverMs-(sentMs+receivedMs)/2;}
  }
  int? accept(Map<String,dynamic> state,{required String renditionId,required int localNowMs}) {
    final nextEpoch=state['epoch'] as int,nextRevision=state['revision'] as int;
    if(nextEpoch<epoch || (nextEpoch==epoch && nextRevision<revision))return null;
    if((state['track'] as Map?)?['id']!=renditionId)throw StateError('Remote rendition differs; load the exact authorized local package');
    final tempo=(state['tempo'] as num).toDouble();if(!tempo.isFinite || tempo<.5 || tempo>2)throw const FormatException('Invalid remote tempo');
    epoch=nextEpoch;revision=nextRevision;
    final elapsed=state['playing']==true ? ((localNowMs+offsetMs-(state['serverTimeMs'] as int))*tempo).round() : 0;
    return ((state['positionMs'] as int)+elapsed).clamp(0,state['durationMs'] as int);
  }
}
