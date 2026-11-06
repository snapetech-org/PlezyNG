import 'dart:convert';

/// Provider HTML contains no application copy or credentials.
String extraYoutubePlayerHtml(String id, int position) {
  if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) throw const FormatException('Invalid video ID');
  final videoJson = jsonEncode(id);
  final start = position.clamp(0, 86400);
  return '''<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0;background:#000"><div id="player"></div><script>
var player; function approved(){return player&&player.getVideoData&&player.getVideoData().video_id===$videoJson;} function send(kind,value) {if(window.flutter_inappwebview) window.flutter_inappwebview.callHandler('extras',kind,value);}
function onYouTubeIframeAPIReady(){player=new YT.Player('player',{width:'100%',height:window.innerHeight,videoId:$videoJson,
playerVars:{playsinline:1,rel:0,start:$start,origin:'https://pleazyng.app'},events:{onReady:function(){send('ready',0);},onError:function(e){send('error',e.data);},
onStateChange:function(e){if(e.data===1&&!approved()){player.stopVideo();send('error',1);return;}if(e.data===0&&approved())send('ended',Math.floor(player.getCurrentTime()));}}});}
setInterval(function(){if(approved()&&player.getCurrentTime&&player.getPlayerState()===1)send('position',Math.floor(player.getCurrentTime()));},5000);
window.addEventListener('resize',function(){if(player&&player.setSize)player.setSize(window.innerWidth,window.innerHeight);});
</script><script src="https://www.youtube.com/iframe_api"></script></body></html>''';
}
