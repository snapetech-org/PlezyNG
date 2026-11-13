import 'dart:convert';

import 'karaoke_strings.dart';

/// Self-contained LAN songbook/display. No external scripts, analytics or media
/// credentials. Mic access is a separate explicit action on a secure context.
const karaokeGuestHtml = r'''<!doctype html>
<html lang="__KARAOKE_LOCALE__"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title data-copy="webAppTitle">Pleazyng Karaoke</title><style>
:root{color-scheme:dark;font:17px system-ui;background:#11131a;color:#f4f4fa}*{box-sizing:border-box}body{margin:0 auto;max-width:1000px;padding:20px}h1{font-size:1.6rem}button,input,select{font:inherit;border-radius:10px;padding:12px;border:1px solid #687082;background:#242937;color:inherit}button{cursor:pointer;min-height:46px}button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid #f7cf58;outline-offset:2px}button:disabled{opacity:.4}input{max-width:100%}label{display:block;margin:12px 0}nav,.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}.song{padding:16px 0;border-bottom:1px solid #394051;display:flex;gap:12px;justify-content:space-between;align-items:center}.muted{color:#b5bdcf}.error{color:#ffbaba;white-space:pre-wrap}#stage{text-align:center;min-height:60vh;display:grid;align-content:center;padding:3vw}#lyric{font-size:clamp(24px,5vw,64px);font-weight:750;white-space:pre-wrap}#lyric ruby{ruby-position:over;ruby-align:center}#lyric rt{font-size:.4em;font-weight:500}#next{font-size:clamp(19px,3vw,38px);color:#b5bdcf;white-space:pre-wrap}#stage small{font-size:1rem}#pronunciation,#translation{display:block;min-height:1.2em}.accent{color:#f7cf58}.part-two{color:#65e6ff}[hidden]{display:none!important}.queue{padding:14px 0;border-bottom:1px solid #394051}progress{width:100%}#message{min-height:1.5em}#query{flex:1}body.display{max-width:none}body.display header,body.display nav{opacity:.6}a{color:#9bd3ff}
</style><header><h1 data-copy="webAppTitle">Pleazyng Karaoke</h1></header>
<p id="message" role="status" aria-live="polite"></p>
<section id="join"><p data-copy="webJoinIntro">Join this karaoke room. Microphone access is optional and separate.</p><form id="joinForm"><label><span data-copy="webYourName">Your name</span> <input id="name" maxlength="80" autocomplete="nickname" required></label><button data-copy="webJoinRoom">Join room</button></form></section>
<main id="room" hidden><nav data-aria-label="webViewNavigation"><button data-view="book" data-copy="webSongbook">Songbook</button><button data-view="waiting" data-copy="webQueue">Queue</button><button data-view="stage" data-copy="webStage">Stage</button><button data-view="input" data-copy="webMicrophone">Microphone</button><button id="leave" data-copy="webLeave">Leave</button></nav>
<section id="book"><h2 data-copy="webChooseSong">Choose a song</h2><form id="search" class="row"><input id="query" data-aria-label="webTitleOrArtist" data-placeholder="webTitleOrArtist" aria-label="Title or artist" placeholder="Title or artist" maxlength="200"><button data-copy="webSearch">Search</button></form><label><span data-copy="webKey">Key</span> <select id="key" data-aria-label="webKeySemitones" aria-label="Key in semitones"></select></label><div id="songs"></div><button id="more" data-copy="webMoreSongs" hidden>More songs</button>
<div id="myMissing" aria-live="polite"></div><details id="missingSuggestion"><summary data-copy="webMissingSummary">Can't find a song?</summary><form id="missingForm"><label><span data-copy="webSongTitle">Song title</span> <input id="missingTitle" maxlength="160" required></label><label><span data-copy="webArtist">Artist</span> <input id="missingArtist" maxlength="120"></label><label><span data-copy="webLanguage">Language</span> <input id="missingLanguage" maxlength="32"></label><button data-copy="webSuggestSong">Suggest it to the host</button></form></details></section>
<section id="waiting" hidden><div id="quiz"></div><h2 data-copy="webSingerRotation">Singer rotation</h2><div id="queue"></div><section id="host" hidden><div class="row"><button data-command="pause" data-copy="pause">Pause</button><button data-command="resume" data-copy="resume">Resume</button><button data-command="restart" data-copy="webRestart">Restart</button><button data-command="finish" data-copy="webFinishSong">Finish song</button><button data-command="end" data-copy="webEndPerformance">End performance</button></div><h3 data-copy="webMissingSuggestions">Missing song suggestions</h3><div id="missingQueue"></div></section></section>
<section id="stage" hidden><p id="banner"></p><p id="title" class="muted"></p><div id="lyric" dir="auto"></div><p id="next" dir="auto"></p><small id="pronunciation"></small><small id="translation"></small><progress id="progress" value="0" max="1" data-aria-label="webSongProgress" aria-label="Song progress"></progress><p><button id="fullscreen" data-copy="webFullScreen">Full screen</button></p></section>
<section id="input" hidden><h2 id="inputTitle"></h2><p id="inputHelp"></p><p id="inputReason"></p><label><input id="recordPhone" type="checkbox"> <span id="recordPhoneLabel" data-copy="webPrivateTake">Send raw audio for a private take</span></label><button id="microphone"></button><p id="pitch" role="status"></p><progress id="meter" max="1" value="0"></progress></section>
<button id="retry" data-copy="webRetry" hidden>Retry last action</button></main>
<script>
'use strict';
const payload=__KARAOKE_STRINGS__,micCopy=payload.microphone,uiCopy=payload.ui;
const $=id=>document.getElementById(id), message=(text,error=false)=>{$('message').textContent=text;$('message').className=error?'error':'';};
const t=(key,value)=>{const text=uiCopy[key]||key;return value===undefined?text:text.replace('__VALUE__',String(value));};
for(const el of document.querySelectorAll('[data-copy]'))el.textContent=uiCopy[el.dataset.copy]||el.textContent;
for(const el of document.querySelectorAll('[data-placeholder]'))el.placeholder=uiCopy[el.dataset.placeholder]||el.placeholder;
for(const el of document.querySelectorAll('[data-aria-label]'))el.setAttribute('aria-label',uiCopy[el.dataset.ariaLabel]||el.getAttribute('aria-label')||'');
document.title=t('webAppTitle');
for(const [id,key] of [['inputTitle','phoneTitle'],['inputHelp','phoneHelp'],['recordPhoneLabel','recordPhoneLabel']])$(id).textContent=micCopy[key];
$('microphone').textContent=micCopy.enablePhoneMicrophone;$('meter').setAttribute('aria-label',micCopy.microphoneLevel);
const uuid=()=>{const b=new Uint8Array(16);crypto.getRandomValues(b);return Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');};
let credentials=null,state=null,pending=null,invite=location.hash.slice(1),lyrics=[],lyricKey='',anchor=0,anchorPosition=0,offset=0,view='book',busy=false;
try{credentials=JSON.parse(sessionStorage.getItem('plezy-room'));pending=JSON.parse(sessionStorage.getItem('plezy-pending'));}catch{}
history.replaceState(null,'',location.pathname);
async function api(path,body){const started=performance.now();const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),8000);try{
 const r=await fetch(path,{method:body?'POST':'GET',headers:{...(body?{'Content-Type':'application/json'}:{}),...(credentials?{'Authorization':'Bearer '+credentials.token}:{})},body:body?JSON.stringify(body):undefined,signal:controller.signal,cache:'no-store'});
 const data=await r.json();if(!r.ok){const e=new Error(data.error||t('webRoomRequestFailed'));e.status=r.status;throw e;}return {data,rtt:performance.now()-started};
}finally{clearTimeout(timeout);}}
function node(tag,text){const el=document.createElement(tag);if(text!=null)el.textContent=text;return el;}
function button(text,click){const b=node('button',text);b.onclick=click;return b;}
function selectView(name){view=name;for(const id of ['book','waiting','stage','input'])$(id).hidden=id!==name;}
for(const b of document.querySelectorAll('[data-view]'))b.onclick=()=>selectView(b.dataset.view);
for(let i=-12;i<=12;i++){const o=node('option',(i>0?'+':'')+i);o.value=i;o.selected=i===0;$('key').append(o);}
async function pair(event){event.preventDefault();if(busy)return;busy=true;try{
 if(!invite)throw new Error(t('webOpenInvitation'));
 const pairKey='plezy-pair-'+invite;let id=sessionStorage.getItem(pairKey);if(!id){id=uuid();sessionStorage.setItem(pairKey,id);}
 credentials=(await api('/api/pair',{invite,name:$('name').value.trim(),id})).data;
 sessionStorage.setItem('plezy-room',JSON.stringify(credentials));await enter();message(t('webConnected'));
}catch(e){message(e.message,true);}finally{busy=false;}}
$('joinForm').onsubmit=pair;
async function enter(){ $('join').hidden=true;$('room').hidden=false;$('host').hidden=credentials.role!=='host';
 $('missingSuggestion').hidden=credentials.role!=='singer';
 if(credentials.role==='display'){document.body.classList.add('display');selectView('stage');}
 await refresh();if(credentials.role!=='display')await search(true);$('retry').hidden=!pending;
}
async function command(action,payload){if(busy)return;pending={id:uuid(),revision:state.revision,action,payload};sessionStorage.setItem('plezy-pending',JSON.stringify(pending));await sendPending();}
async function sendPending(){if(!pending||busy)return;busy=true;$('retry').hidden=true;try{
 await api('/api/command',pending);pending=null;sessionStorage.removeItem('plezy-pending');message(t('webActionAcknowledged'));await refresh();
}catch(e){if(e.status===409||e.status===400||e.status===403){pending=null;sessionStorage.removeItem('plezy-pending');await refresh();message(e.message+' '+t('webCheckQueueBeforeRetry'),true);}else{message(e.message+' '+t('webRetrySafely'),true);$('retry').hidden=false;}}finally{busy=false;}}
$('retry').onclick=sendPending;
async function search(reset){try{if(reset){offset=0;$('songs').replaceChildren();}const result=(await api('/api/catalog?q='+encodeURIComponent($('query').value)+'&offset='+offset)).data;
 for(const song of result.songs){const row=node('div');row.className='song';const detail=node('div');detail.append(node('strong',song.title),node('p',song.artist));
 if(song.explicit)detail.append(node('small',t('webExplicit')));
 if(song.singAlongOnly)detail.append(node('small',t('webSingAlongOnly')));
 if(!song.scored)detail.append(node('small',t('webNoReviewedScore')));
 row.append(detail);
 const actions=node('div');actions.className='row';let part=null;if(song.parts.length>1){part=node('select');part.setAttribute('aria-label',t('webDuetPart'));part.append(node('option',t('webAllParts')));part.firstChild.value='';for(const p of song.parts){const o=node('option',p);o.value=p;part.append(o);}actions.append(part);}
 if(credentials.role==='singer'){const favorite=button(song.favorite?'★':'☆',()=>command('favorite',{trackId:song.id,value:!song.favorite}));favorite.setAttribute('aria-label',t(song.favorite?'webRemoveFavorite':'webAddFavorite'));actions.append(button(t('webRequest'),()=>command('request',{trackId:song.id,key:Number($('key').value),part:part&&part.value||null})),favorite);}
 row.append(actions);$('songs').append(row);}offset+=result.songs.length;$('more').hidden=offset>=result.total;
}catch(e){message(e.message,true);}}
$('search').onsubmit=e=>{e.preventDefault();search(true);};$('more').onclick=()=>search(false);
$('missingForm').onsubmit=e=>{e.preventDefault();command('missingSong',{title:$('missingTitle').value,artist:$('missingArtist').value,language:$('missingLanguage').value});};
async function refresh(){if(!credentials)return;try{const result=await api('/api/state');state=result.data;if(mic && (!state.playing || state.epoch!==mic.epoch || !state.phoneInput.activeSinger))await stopMic();
 $('inputReason').textContent=!window.isSecureContext || !state.phoneInput.available?micCopy.phoneCaptureRequiresTrustedHTTPS:!state.phoneInput.activeSinger?micCopy.phoneInputNeedsAssignedSinger:micCopy.phoneInputUncalibratedPracticeOnly;
 $('microphone').disabled=!mic && (!window.isSecureContext || !state.phoneInput.available || !state.phoneInput.activeSinger);anchor=performance.now();anchorPosition=state.positionMs+(state.playing?result.rtt*.5*state.tempo:0);
 $('title').textContent=state.track?state.track.title+' · '+state.track.artist:t('webWaitingNextSinger');$('banner').textContent=state.banner;
 const key=(state.track?.id||'')+':'+state.revision;if(key!==lyricKey){lyricKey=key;lyrics=state.track?(await api('/api/lyrics')).data.lines:[];}
 $('quiz').replaceChildren();const question=state.party?.question;if(question){$('quiz').append(node('h2',question.prompt));
 for(let i=0;i<question.options.length;i++){const b=button(question.options[i],()=>command('party',{operation:'answer',data:{index:question.index,option:i}}));
 b.disabled=question.revealed||Date.now()>question.closesMs||credentials.role!=='singer';$('quiz').append(b);}
 if(question.revealed)$('quiz').append(node('p',t('webAnswer',question.options[question.answer])));}
 $('queue').replaceChildren();for(const r of state.queue){const row=node('div');row.className='queue';const queueState=({pending:t('webPending'),ready:t('webReady'),playing:t('webPlaying'),completed:t('webCompleted'),skipped:t('webSkipped'),rejected:t('webRejected')})[r.state]||r.state;row.append(node('strong',r.title),node('p',r.singers.join(' + ')+' · '+queueState+' · '+t('webWaitMinutes',Math.ceil(r.waitMs/60000))));
 if(r.mine&&['pending','ready'].includes(r.state))row.append(button(t('webCancel'),()=>command('cancel',{requestId:r.id})));
 if(credentials.role==='singer'&&state.allowVotes&&['pending','ready'].includes(r.state)){
  const up=button(t('webUpvote',r.votes),()=>command('vote',{requestId:r.id,value:r.myVote===1?0:1}));up.setAttribute('aria-pressed',r.myVote===1?'true':'false');
  const down=button(t('webDownvote'),()=>command('vote',{requestId:r.id,value:r.myVote===-1?0:-1}));down.setAttribute('aria-pressed',r.myVote===-1?'true':'false');row.append(up,down,node('small',t('webNetScore',r.voteScore)));
 }
 if(credentials.role==='host'&&['pending','ready'].includes(r.state)){row.append(button(r.state==='pending'?t('webApprove'):t('webStart'),()=>command(r.state==='pending'?'approve':'start',{requestId:r.id})),button(t('webReject'),()=>command('cancel',{requestId:r.id})));}$('queue').append(row);}
 if(credentials.role==='host'){$('missingQueue').replaceChildren();for(const suggestion of state.missingSongs||[]){const row=node('div');row.className='queue';const suggestionState=({open:t('webMissingOpen'),found:t('webMissingFound'),dismissed:t('webMissingDismissed')})[suggestion.status]||suggestion.status;row.append(node('strong',suggestion.title),node('p',(suggestion.artist||t('webArtistUnknown'))+' · '+suggestion.singer+' · '+(suggestion.language||t('webLanguageUnspecified'))+' · '+suggestionState));
  if(suggestion.status==='open')row.append(button(t('webMarkSourced'),()=>command('missingSongStatus',{suggestionId:suggestion.id,status:'found'})),button(t('webDismiss'),()=>command('missingSongStatus',{suggestionId:suggestion.id,status:'dismissed'})));
  else row.append(button(t('webReopen'),()=>command('missingSongStatus',{suggestionId:suggestion.id,status:'open'})));$('missingQueue').append(row);}}
 if(credentials.role==='singer'){$('myMissing').replaceChildren();for(const suggestion of state.missingSongs||[])$('myMissing').append(node('p',t('webYourSuggestion',suggestion.title)+' · '+({open:t('webMissingOpen'),found:t('webMissingFound'),dismissed:t('webMissingDismissed')})[suggestion.status]));}
 }catch(e){message(e.message,true);if(e.status===401){credentials=null;sessionStorage.removeItem('plezy-room');$('join').hidden=false;$('room').hidden=true;}}}
for(const b of document.querySelectorAll('[data-command]'))b.onclick=()=>command(b.dataset.command,{});
$('leave').onclick=async()=>{await stopMic();credentials=null;sessionStorage.removeItem('plezy-room');sessionStorage.removeItem('plezy-pending');location.reload();};
 $('fullscreen').onclick=async()=>{try{await $('stage').requestFullscreen();}catch(e){message(t('webFullScreenUnavailable'),true);}};

let mic=null,micStarting=false;
function estimate(samples){let mean=0,energy=0;for(const v of samples)mean+=v;mean/=samples.length;
 const s=Float32Array.from(samples,v=>v-mean);for(const v of s)energy+=v*v;const rms=Math.sqrt(energy/s.length);
 if(rms<.008)return {rms,midi:null,confidence:0};const c=new Float32Array(248);let best=0;
 for(let lag=13;lag<247;lag++){let xy=0,x2=0,y2=0;for(let i=0;i<s.length-lag;i++){xy+=s[i]*s[i+lag];x2+=s[i]*s[i];y2+=s[i+lag]*s[i+lag];}c[lag]=xy/Math.sqrt(Math.max(1e-20,x2*y2));best=Math.max(best,c[lag]);}
 for(let lag=14;lag<246;lag++){if(c[lag]>=Math.max(.78,best*.95)&&c[lag]>c[lag-1]&&c[lag]>=c[lag+1])return {rms,midi:69+12*Math.log2(16000/lag/440),confidence:Math.min(1,c[lag])};}
 return {rms,midi:null,confidence:Math.max(0,Math.min(1,best))};
}
async function stopMic(){const active=mic;mic=null;if(active){active.stopping=true;active.stream.getTracks().forEach(t=>t.stop());active.node.port.onmessage=null;active.node.port.close();active.source.disconnect();active.node.disconnect();await active.context.close().catch(()=>{});
 try{await active.sending;}catch{}try{await api('/api/microphone',{operation:'stop'});}catch{} }
 $('microphone').textContent=micCopy.enablePhoneMicrophone;$('recordPhone').disabled=false;$('meter').value=0;}
async function sendFrames(active){if(active.sendingNow)return;active.sendingNow=true;try{while((mic===active||active.stopping)&&active.queue.length){const frame=active.queue.shift();
 try{await api('/api/microphone',frame);}catch(first){if(first.status)throw first;await api('/api/microphone',frame);} }}
 catch(e){message(micCopy.phoneInputStopped.replace('__ERROR__',e.message),true);setTimeout(()=>stopMic(),0);}finally{active.sendingNow=false;}}
$('microphone').onclick=async()=>{if(mic){await stopMic();return;}if(micStarting)return;micStarting=true;let stream=null,context=null;
 try{if(!window.isSecureContext||!navigator.mediaDevices?.getUserMedia)throw new Error(micCopy.phoneInputRequiresSecureContext);
 stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false});
 context=new AudioContext({sampleRate:16000});if(context.sampleRate!==16000||!context.audioWorklet)throw new Error(micCopy.phoneInputRequires16kHzCapture);
 await context.audioWorklet.addModule('/capture-worklet.js');await context.resume();
 if(document.hidden||!state?.playing)throw new Error(micCopy.phoneInputNeedsActivePerformance);
 const record=$('recordPhone').checked,lease=(await api('/api/microphone',{operation:'start',record})).data;
 const source=context.createMediaStreamSource(stream),node=new AudioWorkletNode(context,'plezy-capture'),active={stream,context,source,node,id:lease.lease,sequence:lease.nextSequence,epoch:state.epoch,record,queue:[],sendingNow:false,sending:Promise.resolve()};mic=active;
 node.port.onmessage=e=>{if(mic!==active)return;if(active.queue.length>=4){message(micCopy.phoneInputNetworkFellBehind,true);stopMic();return;}
  const samples=e.data,pitch=estimate(samples.subarray(samples.length-2048)),sourceMs=Math.round(anchorPosition+(performance.now()-anchor)*state.tempo);
  const frame={operation:'frame',lease:active.id,sequence:active.sequence++,epoch:active.epoch,sourceMs,...pitch};
  if(record){const bytes=new Uint8Array(samples.length*2),view=new DataView(bytes.buffer);for(let i=0;i<samples.length;i++)view.setInt16(i*2,Math.round(Math.max(-1,Math.min(1,samples[i]))*32767),true);frame.pcm=btoa(String.fromCharCode(...bytes));}
  $('meter').value=Math.min(1,pitch.rms*4);$('pitch').textContent=pitch.midi===null?micCopy.noConfidentPitch:micCopy.pitchMIDIPracticeOnly.replace('__PITCH__',pitch.midi.toFixed(1));
  active.queue.push(frame);if(!active.sendingNow)active.sending=sendFrames(active);
 };
 stream.getAudioTracks()[0].onended=()=>stopMic();context.onstatechange=()=>{if(context.state!=='running'&&mic===active)stopMic();};
 source.connect(node);node.connect(context.destination);$('microphone').textContent=micCopy.muteAndSave;$('recordPhone').disabled=true;
 }catch(e){stream?.getTracks().forEach(t=>t.stop());if(context)await context.close().catch(()=>{});message(e.message,true);try{await api('/api/microphone',{operation:'stop'});}catch{}}
 finally{micStarting=false;}
};
document.addEventListener('visibilitychange',()=>{if(document.hidden)stopMic();});window.addEventListener('pagehide',()=>{if(mic)mic.stream.getTracks().forEach(t=>t.stop());});

let lastFrame=0;function draw(now){requestAnimationFrame(draw);if(view!=='stage'||!state||now-lastFrame<80)return;lastFrame=now;
 const pos=Math.min(state.durationMs||Infinity,anchorPosition+(state.playing?(now-anchor)*state.tempo:0)),time=pos+(state.track?.offsetMs||0);
 $('progress').value=state.durationMs>0?pos/state.durationMs:0;let active=[],next=[];
 for(let i=0;i<lyrics.length;i++){const l=lyrics[i];if(l.startMs==null)continue;const following=lyrics.slice(i+1).find(n=>n.part===l.part&&n.startMs!=null);const end=l.endMs??following?.startMs??state.durationMs;
 if(l.startMs<=time&&end>time)active.push(l);if(l.startMs>time&&next.length<2)next.push(l);}
 $('lyric').replaceChildren();for(const l of active.slice(0,4)){const row=node('div');row.dir='auto';if(l.part)row.append(node('small',l.part+' · '));if(l.spans?.length){for(const span of l.spans){const part=span.part||l.part;if(span.part&&span.part!==l.part)row.append(node('small',span.part+' · '));const el=node('span',span.text);if(time>=span.startMs)el.className=part==='2'?'part-two':'accent';if(span.pronunciation?.trim()){const ruby=node('ruby');ruby.append(el,node('rt',span.pronunciation));row.append(ruby);}else row.append(el);}}else row.append(node('span',l.text));$('lyric').append(row);}
 if(!active.length&&next.length)$('lyric').textContent=t('webGetReady',Math.max(0,Math.ceil((next[0].startMs-time)/1000)));
 if(!lyrics.length&&state.track)$('lyric').textContent=t('webWatchHostLyrics');
 $('next').textContent=next.map(l=>l.text).join('\n');$('pronunciation').textContent=active.filter(l=>!l.spans?.some(span=>span.pronunciation?.trim())).map(l=>l.pronunciation||'').filter(Boolean).join('\n');$('translation').textContent=active.map(l=>l.translation||'').join('\n');}
requestAnimationFrame(draw);setInterval(()=>{if(!busy)refresh();},1000);
if(credentials)enter().catch(e=>message(e.message,true));else if(!invite)message(t('webOpenInvitation'),true);
</script></html>''';

String karaokeGuestHtmlFor(Map<String, String> microphoneStrings, {String locale = 'en'}) {
  final resolvedLocale = karaokeTranslations.containsKey(locale) ? locale : 'en';
  final encoded =
      jsonEncode({
            'microphone': microphoneStrings,
            'ui': karaokeTranslations[resolvedLocale] ?? karaokeTranslations['en']!,
          })
          .replaceAll('<', r'\u003c')
          .replaceAll('>', r'\u003e')
          .replaceAll('&', r'\u0026')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
  return karaokeGuestHtml
      .replaceFirst('__KARAOKE_LOCALE__', resolvedLocale)
      .replaceFirst('__KARAOKE_STRINGS__', encoded);
}

/// Fixed 16 kHz context: the browser resamples native input before the worklet.
/// Zero output prevents feedback. Raw data only leaves after explicit opt-in.
const karaokeCaptureWorklet = r'''
class PlezyCapture extends AudioWorkletProcessor {
 constructor(){super();this.samples=new Float32Array(2400);this.at=0;}
 process(inputs,outputs){for(const output of outputs)for(const channel of output)channel.fill(0);
  const input=inputs[0]?.[0];if(!input)return true;
  for(const sample of input){this.samples[this.at++]=sample;if(this.at===2400){const copy=this.samples;this.port.postMessage(copy,[copy.buffer]);this.samples=new Float32Array(2400);this.at=0;}}
  return true;
 }
}
registerProcessor('plezy-capture',PlezyCapture);
''';
