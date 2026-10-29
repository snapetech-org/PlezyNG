import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../mpv/mpv.dart';
import '../sources/network_media_stream_server.dart';
import 'subtitle_overlay_service.dart';

/// Explicit, expiring, read-only subtitle sharing. No media URL, credentials,
/// playback command, filesystem path, microphone or automatic room broadcast.
class SubtitleHandoffService {
  SubtitleHandoffService._();
  static final instance = SubtitleHandoffService._();
  HttpServer? _server;
  Timer? _expiry, _guard;
  Player? _player;
  SubtitleOverlaySession? _session;
  List<SubtitleOverlayTrack> _tracks = [];
  List<String> _addresses = [];
  String? _token;
  DateTime? expires;
  int _generation = 0, _inflight = 0, _requests = 0;
  DateTime _rateWindow = DateTime.now();
  final Map<int, ({int delay, List<int> bytes})> _vtt = {};
  bool get running => _server != null;
  List<String> get urls => _server == null ? [] : [for (final address in _addresses)
    Uri(scheme: 'http', host: address, port: _server!.port, path: '/$_token/').toString()];
  bool get _current {
    try { return _session?.current == true && _tracks.isNotEmpty && _tracks.every((t) => _session!.lanes.contains(t) && t.isCurrent()); }
    catch (_) { return false; }
  }

  Future<void> start(Player player, List<SubtitleOverlayTrack> tracks) async {
    await stop();
    if (tracks.isEmpty || tracks.length > 2) throw ArgumentError('Choose one or two subtitle overlays.');
    final epoch = ++_generation;
    final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
    if (epoch != _generation) return;
    _addresses = {for (final interface in interfaces) for (final address in interface.addresses)
      if (NetworkMediaStreamPolicy.isPrivateIPv4(address)) address.address}.toList();
    if (_addresses.isEmpty) throw const SocketException('No private IPv4 network is available.');
    _player = player; _session = SubtitleOverlayService.forPlayer(player); _tracks = List.unmodifiable(tracks);
    if (!_current) { await stop(); throw StateError('The selected subtitle session changed.'); }
    // Preflight both derived assets before opening a listener.
    for (var i = 0; i < tracks.length; i++) { _asset(i); }
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: false);
    if (epoch != _generation || !_current) { await server.close(force: true); return; }
    _token = base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    _server = server; expires = DateTime.now().add(const Duration(hours: 1));
    _requests = 0; _rateWindow = DateTime.now();
    server.listen((request) => unawaited(_serve(request)), onError: (_) {});
    _expiry = Timer(const Duration(hours: 1), () => unawaited(stop()));
    _guard = Timer.periodic(const Duration(seconds: 1), (_) { if (!_current) unawaited(stop()); });
  }
  Future<void> stop() async {
    ++_generation;
    _expiry?.cancel(); _guard?.cancel(); _expiry = null; _guard = null;
    final server = _server; _server = null;
    _player = null; _session = null; _tracks = []; _addresses = []; _token = null; expires = null; _vtt.clear();
    await server?.close(force: true);
  }
  static String _time(int ms) => '${(ms ~/ 3600000).toString().padLeft(2, '0')}:'
    '${(ms ~/ 60000 % 60).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.'
    '${(ms % 1000).toString().padLeft(3, '0')}';
  List<int> _asset(int index) {
    final track = _tracks[index], offset = _player!.timelineOffset.inMilliseconds;
    final cached = _vtt[index];
    if (cached != null && cached.delay == track.delayMs) return cached.bytes;
    final output = StringBuffer('WEBVTT\n\nNOTE Plain text from a reviewed PlezyNG overlay. Times follow the open file.\n\n');
    for (final cue in track.cues) {
      final start = cue.startMs + track.delayMs - offset, end = cue.endMs + track.delayMs - offset;
      if (end <= 0) continue;
      final text = SubtitleOverlayTrack.plain(cue.text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
          .replaceAll(RegExp(r'\r\n?'), '\n').replaceAll(RegExp(r'\n\s*\n'), '\n');
      output.write('${cue.stableId}\n${_time(max(0, start))} --> ${_time(end)}\n$text\n\n');
      if (output.length > 5 * 1024 * 1024) throw const FormatException('Shared subtitle exceeds 5 MiB.');
    }
    final bytes = utf8.encode(output.toString());
    if (bytes.length > 5 * 1024 * 1024) throw const FormatException('Shared subtitle exceeds 5 MiB.');
    _vtt[index] = (delay: track.delayMs, bytes: bytes);
    return bytes;
  }
  Future<void> _serve(HttpRequest request) async {
    _inflight++;
    final response = request.response;
    try {
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('X-Frame-Options', 'DENY');
      if (DateTime.now().difference(_rateWindow).inSeconds >= 1) { _requests = 0; _rateWindow = DateTime.now(); }
      if (_inflight > 16 || ++_requests > 80) { response.statusCode = 429; return; }
      final server = _server, parts = request.uri.pathSegments;
      if (server == null || !_current || !const {'GET', 'HEAD'}.contains(request.method) || parts.isEmpty || parts.first != _token ||
          !NetworkMediaStreamPolicy.allowsHostAndPeer(hostHeader: request.headers.value('host'),
            advertisedAddresses: _addresses, port: server.port, peer: request.connectionInfo?.remoteAddress)) {
        response.statusCode = 403; return;
      }
      final endpoint = parts.skip(1).where((s) => s.isNotEmpty).join('/');
      final asset = RegExp(r'^track/([01])\.vtt$').firstMatch(endpoint);
      final origin = request.headers.value('origin');
      final ownOrigin = 'http://${request.headers.value('host')}';
      if (asset == null && origin != null && origin != ownOrigin) { response.statusCode = 403; return; }
      if (asset != null) {
        final index = int.parse(asset.group(1)!);
        if (index >= _tracks.length) { response.statusCode = 404; return; }
        response.headers.set('Access-Control-Allow-Origin', '*'); // receiver VTT fetch only
        response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
        final bytes = _asset(index); response.contentLength = bytes.length;
        if (request.method == 'GET') response.add(bytes);
      } else if (endpoint == 'state') {
        final player = _player!, position = player.currentPosition.inMilliseconds;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'version': 1, 'positionMs': position, 'playing': player.state.playing,
          'expires': expires!.toIso8601String(), 'tracks': [for (var i = 0; i < _tracks.length; i++) {
            'id': i, 'title': _tracks[i].title, 'language': _tracks[i].language,
            'active': [for (final cue in _tracks[i].at(position)) SubtitleOverlayTrack.plain(cue.text)],
            // Read-only local context; no future dialogue is exposed in state.
            'recent': [for (final cue in _tracks[i].cues.where((c) => c.startMs + _tracks[i].delayMs <= position &&
              c.endMs + _tracks[i].delayMs >= position - 30000).take(12))
              {'timeMs': cue.startMs + _tracks[i].delayMs, 'text': SubtitleOverlayTrack.plain(cue.text)}],
          }]}));
      } else if (endpoint.isEmpty) {
        response.headers.contentType = ContentType.html;
        response.headers.set('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'");
        response.write(_page);
      } else { response.statusCode = 404; }
    } catch (_) { response.statusCode = 503; }
    finally { try { await response.close(); } catch (_) {} _inflight--; }
  }

  static const _page = r'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PlezyNG subtitles</title><style>body{background:#121418;color:#eee;font:18px system-ui;margin:auto;max-width:56rem;padding:1.5rem}button,select,a{font:inherit;color:inherit}button,select{background:#26303b;border:1px solid #7d8b9c;padding:.5rem;border-radius:.4rem}article{padding:1.2rem 0;border-bottom:1px solid #445}p{white-space:pre-wrap}.caption{font-size:clamp(24px,4vw,42px);min-height:3em}small{color:#bac3ce}a{display:block;margin:.8rem 0}</style>
<h1>Subtitles</h1><p id="status" role="status">Connecting…</p><label>Visible track <select id="choice"><option value="all">Both</option><option value="0">First</option><option value="1">Second</option><option value="none">Hide captions</option></select></label>
<p><label>Text size <input id="size" type="range" min="20" max="64" value="36"></label> <label><input id="history" type="checkbox">Recent transcript</label></p><main id="tracks"></main>
<small>Read-only companion. Playback and your subtitle choices stay on their own devices. Downloads contain the whole chosen track and may reveal future dialogue. Links expire when sharing stops, the session changes, or after one hour.</small>
<script>const tracks=document.querySelector('#tracks'),status=document.querySelector('#status'),choice=document.querySelector('#choice'),size=document.querySelector('#size'),historyBox=document.querySelector('#history');let latest=null,failures=0;function draw(){tracks.replaceChildren();if(!latest)return;for(const t of latest.tracks){if(choice.value==='none'||choice.value!=='all'&&choice.value!==String(t.id))continue;const a=document.createElement('article'),h=document.createElement('h2'),p=document.createElement('p'),download=document.createElement('a');h.textContent=t.title;p.className='caption';p.style.fontSize=size.value+'px';p.textContent=t.active.join('\n');download.href='track/'+t.id+'.vtt';download.download='subtitles-'+t.id+'.vtt';download.textContent='Download this text track';a.append(h,p,download);if(historyBox.checked){for(const c of t.recent){const line=document.createElement('p');line.textContent=Math.floor(c.timeMs/1000)+'s · '+c.text;a.append(line);}}tracks.append(a);}}choice.onchange=size.oninput=historyBox.onchange=draw;async function poll(){let delay=400;try{const response=await fetch('state',{cache:'no-store',signal:AbortSignal.timeout(2500)});if(response.status===403||response.status===404){latest=null;draw();status.textContent='Sharing ended or this link expired.';return;}if(!response.ok)throw Error();latest=await response.json();failures=0;status.textContent=(latest.playing?'Playing':'Paused')+' · '+Math.floor(latest.positionMs/1000)+'s';draw();}catch(_){latest=null;draw();status.textContent='Connection lost. Reconnecting…';delay=Math.min(5000,500*2**Math.min(++failures,4));}setTimeout(poll,delay);}poll();</script></html>''';
}
