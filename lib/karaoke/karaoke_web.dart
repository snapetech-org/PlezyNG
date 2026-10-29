/// Self-contained LAN songbook/display. No external scripts, analytics or media
/// credentials. Mic access is a separate explicit action on a secure context.
const karaokeGuestHtml=r'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PlezyNG Karaoke</title><style>
:root{color-scheme:dark;font:17px system-ui;background:#11131a;color:#f4f4fa}*{box-sizing:border-box}body{margin:0 auto;max-width:1000px;padding:20px}h1{font-size:1.6rem}button,input,select{font:inherit;border-radius:10px;padding:12px;border:1px solid #687082;background:#242937;color:inherit}button{cursor:pointer;min-height:46px}button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid #f7cf58;outline-offset:2px}button:disabled{opacity:.4}input{max-width:100%}label{display:block;margin:12px 0}nav,.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}.song{padding:16px 0;border-bottom:1px solid #394051;display:flex;gap:12px;justify-content:space-between;align-items:center}.muted{color:#b5bdcf}.error{color:#ffbaba;white-space:pre-wrap}#stage{text-align:center;min-height:60vh;display:grid;align-content:center;padding:3vw}#lyric{font-size:clamp(24px,5vw,64px);font-weight:750;white-space:pre-wrap}#next{font-size:clamp(19px,3vw,38px);color:#b5bdcf;white-space:pre-wrap}#stage small{font-size:1rem}.accent{color:#f7cf58}[hidden]{display:none!important}.queue{padding:14px 0;border-bottom:1px solid #394051}progress{width:100%}#message{min-height:1.5em}#query{flex:1}body.display{max-width:none}body.display header,body.display nav{opacity:.6}a{color:#9bd3ff}
</style><header><h1>PlezyNG Karaoke</h1></header>
<p id="message" role="status" aria-live="polite"></p>
<section id="join"><p>Join this karaoke room. Microphone access is optional and separate.</p><form id="joinForm"><label>Your name <input id="name" maxlength="80" autocomplete="nickname" required></label><button>Join room</button></form></section>
<main id="room" hidden><nav aria-label="Karaoke views"><button data-view="book">Songbook</button><button data-view="waiting">Queue</button><button data-view="stage">Stage</button><button data-view="input">Microphone</button><button id="leave">Leave</button></nav>
<section id="book"><h2>Choose a song</h2><form id="search" class="row"><input id="query" aria-label="Title or artist" placeholder="Title or artist" maxlength="200"><button>Search</button></form><label>Key <select id="key" aria-label="Key in semitones"></select></label><div id="songs"></div><button id="more" hidden>More songs</button>
<div id="myMissing" aria-live="polite"></div><details id="missingSuggestion"><summary>Can't find a song?</summary><form id="missingForm"><label>Song title <input id="missingTitle" maxlength="160" required></label><label>Artist <input id="missingArtist" maxlength="120"></label><label>Language <input id="missingLanguage" maxlength="32"></label><button>Suggest it to the host</button></form></details></section>
<section id="waiting" hidden><div id="quiz"></div><h2>Singer rotation</h2><div id="queue"></div><section id="host" hidden><div class="row"><button data-command="pause">Pause</button><button data-command="resume">Resume</button><button data-command="restart">Restart</button><button data-command="finish">Finish song</button><button data-command="end">End performance</button></div><h3>Missing song suggestions</h3><div id="missingQueue"></div></section></section>
<section id="stage" hidden><p id="banner"></p><p id="title" class="muted"></p><div id="lyric" dir="auto"></div><p id="next" dir="auto"></p><small id="translation"></small><progress id="progress" value="0" max="1" aria-label="Song progress"></progress><p><button id="fullscreen">Full screen</button></p></section>
<section id="input" hidden><h2>Phone pitch and private recording</h2><p>Use headphones. This input provides pitch feedback and an optional private dry recording on the host. It does not amplify your voice through the stage speakers.</p><p id="inputReason"></p><label><input id="recordPhone" type="checkbox"> Send raw vocal audio to save a private take on the host</label><button id="microphone">Enable phone microphone</button><p id="pitch" role="status"></p><progress id="meter" max="1" value="0" aria-label="Microphone level"></progress></section>
<button id="retry" hidden>Retry last action</button></main>
<script>
'use strict';
const $=id=>document.getElementById(id), message=(text,error=false)=>{$('message').textContent=text;$('message').className=error?'error':'';};
const uuid=()=>{const b=new Uint8Array(16);crypto.getRandomValues(b);return Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');};
let credentials=null,state=null,pending=null,invite=location.hash.slice(1),lyrics=[],lyricKey='',anchor=0,anchorPosition=0,offset=0,view='book',busy=false;
try{credentials=JSON.parse(sessionStorage.getItem('plezy-room'));pending=JSON.parse(sessionStorage.getItem('plezy-pending'));}catch{}
history.replaceState(null,'',location.pathname);
async function api(path,body){const started=performance.now();const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),8000);try{
 const r=await fetch(path,{method:body?'POST':'GET',headers:{...(body?{'Content-Type':'application/json'}:{}),...(credentials?{'Authorization':'Bearer '+credentials.token}:{})},body:body?JSON.stringify(body):undefined,signal:controller.signal,cache:'no-store'});
 const data=await r.json();if(!r.ok){const e=new Error(data.error||'Room request failed');e.status=r.status;throw e;}return {data,rtt:performance.now()-started};
}finally{clearTimeout(timeout);}}
function node(tag,text){const el=document.createElement(tag);if(text!=null)el.textContent=text;return el;}
function button(text,click){const b=node('button',text);b.onclick=click;return b;}
function selectView(name){view=name;for(const id of ['book','waiting','stage','input'])$(id).hidden=id!==name;}
for(const b of document.querySelectorAll('[data-view]'))b.onclick=()=>selectView(b.dataset.view);
for(let i=-12;i<=12;i++){const o=node('option',(i>0?'+':'')+i);o.value=i;o.selected=i===0;$('key').append(o);}
async function pair(event){event.preventDefault();if(busy)return;busy=true;try{
 if(!invite)throw new Error('Open a new QR invitation from the host.');
 const pairKey='plezy-pair-'+invite;let id=sessionStorage.getItem(pairKey);if(!id){id=uuid();sessionStorage.setItem(pairKey,id);}
 credentials=(await api('/api/pair',{invite,name:$('name').value.trim(),id})).data;
 sessionStorage.setItem('plezy-room',JSON.stringify(credentials));await enter();message('Connected');
}catch(e){message(e.message,true);}finally{busy=false;}}
$('joinForm').onsubmit=pair;
async function enter(){ $('join').hidden=true;$('room').hidden=false;$('host').hidden=credentials.role!=='host';
 $('missingSuggestion').hidden=credentials.role!=='singer';
 if(credentials.role==='display'){document.body.classList.add('display');selectView('stage');}
 await refresh();if(credentials.role!=='display')await search(true);$('retry').hidden=!pending;
}
async function command(action,payload){if(busy)return;pending={id:uuid(),revision:state.revision,action,payload};sessionStorage.setItem('plezy-pending',JSON.stringify(pending));await sendPending();}
async function sendPending(){if(!pending||busy)return;busy=true;$('retry').hidden=true;try{
 await api('/api/command',pending);pending=null;sessionStorage.removeItem('plezy-pending');message('Action acknowledged by host');await refresh();
}catch(e){if(e.status===409||e.status===400||e.status===403){pending=null;sessionStorage.removeItem('plezy-pending');await refresh();message(e.message+' Check the queue before trying again.',true);}else{message(e.message+' You can retry safely.',true);$('retry').hidden=false;}}finally{busy=false;}}
$('retry').onclick=sendPending;
async function search(reset){try{if(reset){offset=0;$('songs').replaceChildren();}const result=(await api('/api/catalog?q='+encodeURIComponent($('query').value)+'&offset='+offset)).data;
 for(const song of result.songs){const row=node('div');row.className='song';const detail=node('div');detail.append(node('strong',song.title),node('p',song.artist));
 if(song.explicit)detail.append(node('small','Explicit'));
 if(song.singAlongOnly)detail.append(node('small','Sing-along only · original audio'));
 if(!song.scored)detail.append(node('small',' · no reviewed score chart'));
 row.append(detail);
 const actions=node('div');actions.className='row';let part=null;if(song.parts.length>1){part=node('select');part.setAttribute('aria-label','Duet part');part.append(node('option','All parts'));part.firstChild.value='';for(const p of song.parts){const o=node('option',p);o.value=p;part.append(o);}actions.append(part);}
 if(credentials.role==='singer'){actions.append(button('Request',()=>command('request',{trackId:song.id,key:Number($('key').value),part:part&&part.value||null})),button(song.favorite?'★':'☆',()=>command('favorite',{trackId:song.id,value:!song.favorite})));}
 row.append(actions);$('songs').append(row);}offset+=result.songs.length;$('more').hidden=offset>=result.total;
}catch(e){message(e.message,true);}}
$('search').onsubmit=e=>{e.preventDefault();search(true);};$('more').onclick=()=>search(false);
$('missingForm').onsubmit=e=>{e.preventDefault();command('missingSong',{title:$('missingTitle').value,artist:$('missingArtist').value,language:$('missingLanguage').value});};
async function refresh(){if(!credentials)return;try{const result=await api('/api/state');state=result.data;if(mic && (!state.playing || state.epoch!==mic.epoch || !state.phoneInput.activeSinger))await stopMic();
 $('inputReason').textContent=!window.isSecureContext || !state.phoneInput.available?'Phone capture requires the host HTTPS room with a certificate trusted by this phone. The ordinary LAN songbook remains available.':!state.phoneInput.activeSinger?'The host must start a request assigned to your singer before you enable input.':'Phone timing is uncalibrated. Feedback is for practice and does not enter competitive leaderboards.';
 $('microphone').disabled=!mic && (!window.isSecureContext || !state.phoneInput.available || !state.phoneInput.activeSinger);anchor=performance.now();anchorPosition=state.positionMs+(state.playing?result.rtt*.5*state.tempo:0);
 $('title').textContent=state.track?state.track.title+' · '+state.track.artist:'Waiting for the next singer';$('banner').textContent=state.banner;
 const key=(state.track?.id||'')+':'+state.revision;if(key!==lyricKey){lyricKey=key;lyrics=state.track?(await api('/api/lyrics')).data.lines:[];}
 $('quiz').replaceChildren();const question=state.party?.question;if(question){$('quiz').append(node('h2',question.prompt));
 for(let i=0;i<question.options.length;i++){const b=button(question.options[i],()=>command('party',{operation:'answer',data:{index:question.index,option:i}}));
 b.disabled=question.revealed||Date.now()>question.closesMs||credentials.role!=='singer';$('quiz').append(b);}
 if(question.revealed)$('quiz').append(node('p','Answer: '+question.options[question.answer]));}
 $('queue').replaceChildren();for(const r of state.queue){const row=node('div');row.className='queue';row.append(node('strong',r.title),node('p',r.singers.join(' + ')+' · '+r.state+' · ~'+Math.ceil(r.waitMs/60000)+' min'));
 if(r.mine&&['pending','ready'].includes(r.state))row.append(button('Cancel',()=>command('cancel',{requestId:r.id})));
 if(credentials.role==='singer'&&state.allowVotes&&['pending','ready'].includes(r.state)){
  const up=button('Upvote ('+r.votes+')',()=>command('vote',{requestId:r.id,value:r.myVote===1?0:1}));up.setAttribute('aria-pressed',r.myVote===1?'true':'false');
  const down=button('Downvote',()=>command('vote',{requestId:r.id,value:r.myVote===-1?0:-1}));down.setAttribute('aria-pressed',r.myVote===-1?'true':'false');row.append(up,down,node('small','Net score '+r.voteScore));
 }
 if(credentials.role==='host'&&['pending','ready'].includes(r.state)){row.append(button(r.state==='pending'?'Approve':'Start',()=>command(r.state==='pending'?'approve':'start',{requestId:r.id})),button('Reject',()=>command('cancel',{requestId:r.id})));}$('queue').append(row);}
 if(credentials.role==='host'){$('missingQueue').replaceChildren();for(const suggestion of state.missingSongs||[]){const row=node('div');row.className='queue';row.append(node('strong',suggestion.title),node('p',(suggestion.artist||'Artist unknown')+' · '+suggestion.singer+' · '+(suggestion.language||'Language unspecified')+' · '+suggestion.status));
  if(suggestion.status==='open')row.append(button('Mark sourced',()=>command('missingSongStatus',{suggestionId:suggestion.id,status:'found'})),button('Dismiss',()=>command('missingSongStatus',{suggestionId:suggestion.id,status:'dismissed'})));
  else row.append(button('Reopen',()=>command('missingSongStatus',{suggestionId:suggestion.id,status:'open'})));$('missingQueue').append(row);}}
 if(credentials.role==='singer'){$('myMissing').replaceChildren();for(const suggestion of state.missingSongs||[])$('myMissing').append(node('p','Your suggestion: '+suggestion.title+' · '+suggestion.status));}
 }catch(e){message(e.message,true);if(e.status===401){credentials=null;sessionStorage.removeItem('plezy-room');$('join').hidden=false;$('room').hidden=true;}}}
for(const b of document.querySelectorAll('[data-command]'))b.onclick=()=>command(b.dataset.command,{});
$('leave').onclick=async()=>{await stopMic();credentials=null;sessionStorage.removeItem('plezy-room');sessionStorage.removeItem('plezy-pending');location.reload();};
$('fullscreen').onclick=async()=>{try{await $('stage').requestFullscreen();}catch(e){message('Full screen is unavailable on this display.',true);}};

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
 $('microphone').textContent='Enable phone microphone';$('recordPhone').disabled=false;$('meter').value=0;}
async function sendFrames(active){if(active.sendingNow)return;active.sendingNow=true;try{while((mic===active||active.stopping)&&active.queue.length){const frame=active.queue.shift();
 try{await api('/api/microphone',frame);}catch(first){if(first.status)throw first;await api('/api/microphone',frame);} }}
 catch(e){message('Phone input stopped: '+e.message,true);setTimeout(()=>stopMic(),0);}finally{active.sendingNow=false;}}
$('microphone').onclick=async()=>{if(mic){await stopMic();return;}if(micStarting)return;micStarting=true;let stream=null,context=null;
 try{if(!window.isSecureContext||!navigator.mediaDevices?.getUserMedia)throw new Error('A trusted HTTPS connection is required.');
 stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false});
 context=new AudioContext({sampleRate:16000});if(context.sampleRate!==16000||!context.audioWorklet)throw new Error('This browser cannot supply the required 16 kHz capture path.');
 await context.audioWorklet.addModule('/capture-worklet.js');await context.resume();
 if(document.hidden||!state?.playing)throw new Error('Return to an active performance before enabling capture.');
 const record=$('recordPhone').checked,lease=(await api('/api/microphone',{operation:'start',record})).data;
 const source=context.createMediaStreamSource(stream),node=new AudioWorkletNode(context,'plezy-capture'),active={stream,context,source,node,id:lease.lease,sequence:lease.nextSequence,epoch:state.epoch,record,queue:[],sendingNow:false,sending:Promise.resolve()};mic=active;
 node.port.onmessage=e=>{if(mic!==active)return;if(active.queue.length>=4){message('Phone input stopped because the network fell behind.',true);stopMic();return;}
  const samples=e.data,pitch=estimate(samples.subarray(samples.length-2048)),sourceMs=Math.round(anchorPosition+(performance.now()-anchor)*state.tempo);
  const frame={operation:'frame',lease:active.id,sequence:active.sequence++,epoch:active.epoch,sourceMs,...pitch};
  if(record){const bytes=new Uint8Array(samples.length*2),view=new DataView(bytes.buffer);for(let i=0;i<samples.length;i++)view.setInt16(i*2,Math.round(Math.max(-1,Math.min(1,samples[i]))*32767),true);frame.pcm=btoa(String.fromCharCode(...bytes));}
  $('meter').value=Math.min(1,pitch.rms*4);$('pitch').textContent=pitch.midi===null?'No confident pitch':'Pitch MIDI '+pitch.midi.toFixed(1)+' · practice only';
  active.queue.push(frame);if(!active.sendingNow)active.sending=sendFrames(active);
 };
 stream.getAudioTracks()[0].onended=()=>stopMic();context.onstatechange=()=>{if(context.state!=='running'&&mic===active)stopMic();};
 source.connect(node);node.connect(context.destination);$('microphone').textContent='Mute and save';$('recordPhone').disabled=true;
 }catch(e){stream?.getTracks().forEach(t=>t.stop());if(context)await context.close().catch(()=>{});message(e.message,true);try{await api('/api/microphone',{operation:'stop'});}catch{}}
 finally{micStarting=false;}
};
document.addEventListener('visibilitychange',()=>{if(document.hidden)stopMic();});window.addEventListener('pagehide',()=>{if(mic)mic.stream.getTracks().forEach(t=>t.stop());});

let lastFrame=0;function draw(now){requestAnimationFrame(draw);if(view!=='stage'||!state||now-lastFrame<80)return;lastFrame=now;
 const pos=Math.min(state.durationMs||Infinity,anchorPosition+(state.playing?(now-anchor)*state.tempo:0)),time=pos+(state.track?.offsetMs||0);
 $('progress').value=state.durationMs>0?pos/state.durationMs:0;let active=[],next=[];
 for(let i=0;i<lyrics.length;i++){const l=lyrics[i];if(l.startMs==null)continue;const following=lyrics.slice(i+1).find(n=>n.part===l.part&&n.startMs!=null);const end=l.endMs??following?.startMs??state.durationMs;
 if(l.startMs<=time&&end>time)active.push(l);if(l.startMs>time&&next.length<2)next.push(l);}
 $('lyric').replaceChildren();for(const l of active.slice(0,4)){const row=node('div');row.dir='auto';if(l.part)row.append(node('small',l.part+' · '));if(l.spans?.length){for(const span of l.spans){const el=node('span',span.text);if(time>=span.startMs)el.className='accent';row.append(el);}}else row.append(node('span',l.text));$('lyric').append(row);}
 if(!active.length&&next.length)$('lyric').textContent='Get ready · '+Math.max(0,Math.ceil((next[0].startMs-time)/1000));
 if(!lyrics.length&&state.track)$('lyric').textContent='Watch the host display for authored video/CD+G lyrics.';
 $('next').textContent=next.map(l=>l.text).join('\n');$('translation').textContent=active.map(l=>l.translation||'').join('\n');}
requestAnimationFrame(draw);setInterval(()=>{if(!busy)refresh();},1000);
if(credentials)enter().catch(e=>message(e.message,true));else if(!invite)message('Scan the QR invitation on the host.',true);
</script></html>''';

/// Fixed 16 kHz context: the browser resamples native input before the worklet.
/// Zero output prevents feedback. Raw data only leaves after explicit opt-in.
const karaokeCaptureWorklet=r'''
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
