import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

/// User-selected files are the transport. Credentials, room grants, recordings
/// and media-server locators never enter portable collection metadata.
class KaraokeCollections {
  KaraokeCollections(this.session);
  final KaraokeSession session;
  String digest(KaraokeTrack track)=>sha256.convert(utf8.encode(jsonEncode(
    (track.assets.map((a)=>'${a.path}:${a.sha256}').toList()..sort())))).toString();
  Map<String,dynamic> snapshot()=>{'schema':'plezyng.karaoke-collection.v1','id':const Uuid().v4(),
    'created':DateTime.now().toUtc().toIso8601String(),'singers':session.singers.map((s)=>s.toJson()).toList(),
    'setlists':session.setlists,'catalog':[for(final t in session.catalog.values){'id':t.id,'songId':t.songId,
      'title':t.title,'artist':t.artist,'language':t.language,'genre':t.genre,'year':t.year,'difficulty':t.difficulty,
      'producer':t.producer,'parts':t.parts.toList(),'packageDigest':digest(t)}]};
  Future<void> export(String destination) async {
    await File('$destination.pending').writeAsString(jsonEncode(snapshot()),flush:true);
    await File('$destination.pending').rename(destination);
  }
  Future<Map<String,dynamic>> read(String path) async {
    final file=File(path);if(await file.length()>8*1024*1024)throw const FormatException('Collection exceeds 8 MiB');
    final data=jsonDecode(await file.readAsString()) as Map<String,dynamic>;
    if(data['schema']!='plezyng.karaoke-collection.v1')throw const FormatException('Unsupported collection');
    final people=data['singers'] as List,lists=data['setlists'] as Map,tracks=data['catalog'] as List;
    if(people.length>64 || lists.length>100 || tracks.length>2000)throw const FormatException('Collection limits exceeded');
    final ids=<String>{};
    for(final raw in people){final s=KaraokeSinger.fromJson(Map<String,dynamic>.from(raw as Map));
      if(!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(s.id) || !ids.add(s.id) || s.name.isEmpty || s.name.length>80 ||
        s.favorites.length>2000 || s.history.length>500 || s.keys.length>2000 || s.tempos.length>2000 ||
        s.keys.values.any((v)=>!v.isFinite || v.abs()>12) || s.tempos.values.any((v)=>!v.isFinite || v<.5 || v>2))throw const FormatException('Invalid singer preferences');}
    for(final e in lists.entries){if(e.key is! String || (e.key as String).isEmpty || (e.key as String).length>100 || e.value is! List ||
      (e.value as List).length>256 || (e.value as List).any((v)=>v is! String))throw const FormatException('Invalid setlist');}
    for(final raw in tracks){final t=raw as Map,local=session.catalog[t['id']];
      if(local!=null && digest(local)!=t['packageDigest'])throw StateError('Rendition ${t['title']} has different assets. Import it as a separate rendition first.');}
    return data;
  }
  Future<void> merge(Map<String,dynamic> data,{required bool preferIncoming}) async {
    if(session.hasPerformance)throw StateError('Import collection preferences between performances');
    await session.store.write('collection-before-import',snapshot());
    for(final raw in data['singers'] as List){final incoming=KaraokeSinger.fromJson(Map<String,dynamic>.from(raw as Map));
      final index=session.singers.indexWhere((s)=>s.id==incoming.id);
      if(index<0){if(session.singers.length>=64)throw StateError('Room singer limit reached');session.singers.add(incoming);}
      else if(preferIncoming){session.singers[index]=incoming;}}
    for(final e in (data['setlists'] as Map).entries){if(preferIncoming || !session.setlists.containsKey(e.key))session.setlists[e.key as String]=List<String>.from(e.value as List);}
    await session.host('settings');
  }
  Future<void> catalog(String destination,String format) async {
    final songs=session.search('');
    const columns=['Rendition','Title','Artist','Language','Genre','Year','Difficulty','Producer','Parts','Package assets','Reviewed chart'];
    final rows=[columns,for(final s in songs)[s.id,s.title,s.artist,s.language,s.genre,'${s.year ?? ''}','${s.difficulty ?? ''}',
      s.producer,s.parts.join(' / '),'${s.assets.length}',s.canScore ? 'Yes' : 'No']];
    String xml(String s)=>const HtmlEscape(HtmlEscapeMode.element).convert(s);
    String csv(String s){if(RegExp(r'^[=+@\-\t\r]').hasMatch(s))s="'$s";return '"${s.replaceAll('"','""')}"';}
    final output=switch(format){
      'csv'=>rows.map((r)=>r.map(csv).join(',')).join('\r\n'),
      'xml'=>'<?xml version="1.0" encoding="UTF-8"?><songbook version="1">${songs.map((s)=>'<song id="${s.id}"><title>${xml(s.title)}</title><artist>${xml(s.artist)}</artist><language>${xml(s.language)}</language><genre>${xml(s.genre)}</genre><year>${s.year ?? ''}</year><difficulty>${s.difficulty ?? ''}</difficulty><producer>${xml(s.producer)}</producer></song>').join()}</songbook>',
      'html'=>'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Karaoke songbook</title><style>body{font:14px system-ui;margin:24px}table{border-collapse:collapse;width:100%}th,td{text-align:left;border-bottom:1px solid #bbb;padding:8px}thead{display:table-header-group}tr{break-inside:avoid}@media print{body{margin:0}td:first-child,th:first-child{display:none}}</style><h1>${xml(session.banner.isEmpty ? 'Karaoke songbook' : session.banner)}</h1><p>${songs.length} renditions · ${DateTime.now().toIso8601String().substring(0,10)}</p><table><thead><tr>${columns.map((v)=>'<th>${xml(v)}</th>').join()}</tr></thead><tbody>${rows.skip(1).map((r)=>'<tr>${r.map((v)=>'<td>${xml(v)}</td>').join()}</tr>').join()}</tbody></table>',
      _=>throw UnsupportedError('Catalog format unavailable'),
    };
    await File(destination).writeAsString(output,flush:true);
  }
  Future<List<String>> audit(Iterable<String> ids) async {
    final problems=<String>[];
    for(final id in ids.toSet()){
      final song=session.catalog[id];if(song==null){problems.add('$id: rendition missing');continue;}
      if(song.assets.isEmpty){problems.add('${song.title}: source requires its server');continue;}
      for(final error in await session.packages.verify(song)){problems.add('${song.title}: $error');}
      if(!song.hasLocalAudio && !song.assets.any((a)=>a.kind==KaraokeAssetKind.video))problems.add('${song.title}: render MIDI before offline performance');
    }
    return problems;
  }
}
