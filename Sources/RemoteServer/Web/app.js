'use strict';
const $=id=>document.getElementById(id), Core=RemoteClientCore, t=(...args)=>VelaI18n.t(...args);
let authentication=null, token=null, peer=null, control=null, pointer=null, mediaID=null;
let candidates=[],candidateOffset=0,polling=null,statsTimer=null,retryTimer=null;
let sequence=0,connected=false,inputAllowed=false,connecting=false,connectionEpoch=0;
let lastMove=null,moveFrame=null,retryCount=0,deliberateClose=false,viewOnly=false;
let displays=[],captureInfo={},previousStats=null,noticeTimer=null,activePanel=null,dragging=false;
let virtualSupported=false,virtualBusy=false;
let blackoutSupported=false,privacyBusy=false,sessionInfo=null;
let lastPoint={x:.5,y:.5},touches=new Map(),touchGesture=null,longPressTimer=null;
const heldKeys=new Set(),heldModifiers=new Set(),mouseButtons=new Set();
const modifierName=Core.modifierName;
function message(text='',persistent=false){
  clearTimeout(noticeTimer);$('message').textContent=t(text);$('message').hidden=!text;
  if(text&&!persistent)noticeTimer=setTimeout(()=>{$('message').hidden=true;},8000);
}
function state(text,live=false){$('connection').textContent=text;$('connection').classList.toggle('live',live);updateControlState();}
function canInput(){return connected&&inputAllowed&&!viewOnly&&control?.readyState==='open';}
function updateControlState(){
  const ready=canInput();
  $('control-state').textContent=!connected?t("Connecting…"):sessionInfo?.requiresAccountVerification?t("Current user session unavailable"):sessionInfo?.recovering?t("Restoring video…"):!inputAllowed?t("View only · Access not granted"):viewOnly?t("View only"):ready?(dragging?t("Dragging · Click to release"):sessionInfo?.state==='locked'?t("System locked · Password entry available"):sessionInfo?.state==='blackout'?t("Virtual display only · Control ready"):t("Control ready · Keyboard and mouse available")):t("Connecting control channel…");
  document.querySelectorAll('[data-remote-input]').forEach(button=>button.disabled=!ready);
  $('input-hint').hidden=!ready||!!activePanel;
  const locked=sessionInfo?.state==='locked';
  $('text').hidden=locked;$('lock-text').hidden=!locked;
  $('text-submit').textContent=locked?t("Send to password field ↗"):t("Send text ↗");
  $('lock-text-note').hidden=!locked;
  updateVirtualControls();
  updatePrivacyControls();
}
function updateVirtualControls(){
  const current=displays.find(display=>display.isVirtual);
  const manageable=virtualSupported&&sessionInfo?.canManageVirtualDisplay!==false;
  $('create-virtual').disabled=!manageable||virtualBusy||privacyBusy||!connected||!mediaID||viewOnly;
  $('create-virtual').textContent=virtualBusy?t("Updating…"):current?t("Update and switch"):t("Create and switch");
  $('remove-virtual').hidden=!current;$('remove-virtual').disabled=!manageable||virtualBusy||privacyBusy||!connected||!mediaID||viewOnly;
  for(const id of ['virtual-preset','virtual-width','virtual-height','virtual-hidpi'])$(id).disabled=virtualBusy||!virtualSupported;
}
function updatePrivacyControls(){
  const isOff=sessionInfo?.state==='blackout',local=sessionInfo?.state==='local';
  $('begin-privacy').disabled=!blackoutSupported||!connected||!mediaID||privacyBusy||virtualBusy||viewOnly||!local||!sessionInfo?.canEnterPrivacy||sessionInfo?.localWakePermission===false||sessionInfo?.recovering;
  $('begin-privacy').textContent=privacyBusy?t("Turning off physical displays…"):isOff?t("Physical displays are off"):t("Turn off physical displays, keep virtual display");
  $('restore-physical').hidden=!isOff;$('restore-physical').disabled=privacyBusy||!connected||viewOnly;
  $('display').disabled=isOff||virtualBusy;$('quality').disabled=isOff||virtualBusy;
  const labels={local:t("Local session · Physical displays can show the desktop"),locked:t("System locked · Unlock in the on-screen password field"),detached:t("Return to this user session on the host Mac"),blackout:t("Physical displays are off · Local input restores them"),unavailable:t("Current user session unavailable")};
  let hint=labels[sessionInfo?.state]||t("Reading display status…");
  if(local&&!sessionInfo?.canEnterPrivacy)hint+=t(" · Create and select a virtual display first");
  if(local&&sessionInfo?.localWakePermission===false)hint+=t(" · Grant Vela Input Monitoring access on the host Mac");
  $('privacy-status').textContent=blackoutSupported?hint:t("This system does not support disabling physical displays.");
}
function renderSessionOverlay(){
  if(!connected)return;
  const blocked=!!sessionInfo?.requiresAccountVerification||sessionInfo?.state==='unavailable';
  const recovering=!!sessionInfo?.recovering;
  $('screen-overlay').hidden=!blocked&&!recovering;
  if(blocked){$('overlay-title').textContent=t("Current user session unavailable");$('overlay-detail').textContent=t("The connection is retained. Return to this account on the host Mac to continue.");}
  else if(recovering){$('overlay-title').textContent=sessionInfo?.state==='locked'?t("Connecting to the system lock screen"):t("Restoring session video");$('overlay-detail').textContent=sessionInfo?.state==='locked'?t("When the video is ready, click the system password field and enter the password."):t("Video and input pause briefly while displays switch.");}
}
$('privacy-form').addEventListener('submit',async event=>{
  event.preventDefault();if(privacyBusy||!connected||!mediaID||viewOnly)return;
  release();privacyBusy=true;updateControlState();
  const epoch=connectionEpoch;
  try{
    await api('session/blackout',{mediaID,videoReady:$('video').videoWidth>0&&$('video').currentTime>0});
    if(epoch===connectionEpoch){message(t("Physical displays are off. Remote control continues on the virtual display. Local input restores physical displays."));closePanels();}
  }catch(error){if(epoch===connectionEpoch)message(error.message);}
  finally{privacyBusy=false;updateControlState();}
});
$('restore-physical').addEventListener('click',async()=>{release();try{await api('session/restore-displays',{mediaID});message(t("Physical displays restored. Remote control can continue."));}catch(error){message(error.message);}});
function updateVirtualSummary(){
  const width=Number($('virtual-width').value),height=Number($('virtual-height').value),scale=$('virtual-hidpi').checked?2:1;
  $('virtual-summary').textContent=t("Desktop {0} × {1}, output {2} × {3} pixels.", width/scale, height/scale, width, height);
}
function setDisplays(value,selected){
  displays=value;$('display').replaceChildren(...displays.map(display=>new Option(`${t(display.name)} · ${display.width}×${display.height}`,String(display.id))));
  if(selected!==undefined&&displays.some(display=>String(display.id)===String(selected)))$('display').value=String(selected);
  updateVirtualControls();renderQuality();
}
$('virtual-preset').addEventListener('change',()=>{if($('virtual-preset').value!=='custom'){const [width,height]=$('virtual-preset').value.split(',');$('virtual-width').value=width;$('virtual-height').value=height;}updateVirtualSummary();});
for(const id of ['virtual-width','virtual-height'])$(id).addEventListener('input',()=>{$('virtual-preset').value='custom';updateVirtualSummary();});
$('virtual-hidpi').addEventListener('change',updateVirtualSummary);
async function changeVirtualDisplay(remove=false){
  if(virtualBusy||!connected||!mediaID||viewOnly)return;
  const configuration={width:Number($('virtual-width').value),height:Number($('virtual-height').value),hiDPI:$('virtual-hidpi').checked};
  if(!remove){
    const {width,height,hiDPI}=configuration;
    if(!Number.isInteger(width)||!Number.isInteger(height)||width<640||height<480||width>3840||height>3840||width%2||height%2||width*height>3840*2160||(hiDPI&&(width<1280||height<960))){message(t("Enter valid even dimensions with at most 3840×2160 total pixels. HiDPI requires at least 1280×960 pixels."));return;}
  }
  release();virtualBusy=true;updateVirtualControls();$('display').disabled=true;$('quality').disabled=true;
  const epoch=connectionEpoch;
  try{
    const result=await api(remove?'virtual-display/remove':'virtual-display',{mediaID,...(!remove?{configuration}:{})});
    if(epoch!==connectionEpoch)return;
    setDisplays(result.displays,result.displayID);captureInfo={};previousStats=null;renderQuality();layoutVideo();centerView();
    $('virtual-status').textContent=remove?t("Virtual display closed."):t("Virtual display connected. It closes when this session ends.");
    message(remove?t("Returned to another display."):t("Switched to the virtual display. Move windows into it from another Mac display."));
  }catch(error){if(epoch===connectionEpoch)message(error.message);}
  finally{virtualBusy=false;updateVirtualControls();$('display').disabled=false;$('quality').disabled=false;}
}
$('create-virtual').addEventListener('click',()=>changeVirtualDisplay());$('remove-virtual').addEventListener('click',()=>changeVirtualDisplay(true));
async function api(path,body,method=body===undefined?'GET':'POST'){
  const headers={};if(token)headers.Authorization=`Bearer ${token}`;
  if(body!==undefined)headers['Content-Type']='application/json';
  const response=await fetch(`/api/${path}`,{method,headers,body:body===undefined?undefined:JSON.stringify(body),credentials:'omit',cache:'no-store',signal:AbortSignal.timeout(20000)});
  let value;try{value=await response.json();}catch{throw new Error(t("The host returned an invalid response. Reconnect."));}
  if(!response.ok){const error=new Error(value.error||t("Request failed ({0})", response.status));error.status=response.status;throw error;}return value;
}
async function refreshAuthentication(){
  authentication=null;$('login-button').disabled=true;
  try{
    const value=await api('authentication');if(!['customPassword','macOSAccount'].includes(value.mode)||!value.generation)throw new Error(t("Invalid host authentication method."));
    authentication=value;const system=value.mode==='macOSAccount';
    $('password').autocomplete=system?'off':'current-password';$('password-label').textContent=system?t("Mac account login password"):t("Vela custom password");
    $('authentication-hint').textContent=system?t("Connecting to account {0}. Use this Mac account's password; it is never saved.", value.account):t("Enter the access password set on the host Mac to continue your work.");$('password').value='';
  }catch(error){message(error.message,true);}finally{$('login-button').disabled=!authentication;}
}
function modifiers(event={}){
  return [...new Set([...(event.shiftKey?['shift']:[]),...(event.ctrlKey?['control']:[]),...(event.altKey?['alt']:[]),...(event.metaKey?['meta']:[]),...[...heldModifiers].map(key=>modifierName[key])])];
}
function send(input,moving=false){
  if(!canInput())return false;const channel=moving?pointer:control;
  if(channel?.readyState!=='open')return false;
  if(channel.bufferedAmount>65536){if(!moving)scheduleReconnect(t("Control channel congested. Recovering…"));return false;}
  channel.send(JSON.stringify(input));return true;
}
function updateModifierButtons(){
  document.querySelectorAll('.modifier').forEach(button=>{const selected=heldModifiers.has(button.dataset.key);button.classList.toggle('selected',selected);button.setAttribute('aria-pressed',String(selected));});
}
function release({preserveTouches=false}={}){
  $('lock-text').value='';
  if(control?.readyState==='open')control.send(JSON.stringify({type:'release'}));
  heldKeys.clear();heldModifiers.clear();mouseButtons.clear();dragging=false;lastMove=null;
  clearTimeout(longPressTimer);if(!preserveTouches){touches.clear();touchGesture=null;}
  if(moveFrame)cancelAnimationFrame(moveFrame);moveFrame=null;
  $('drag-toggle').setAttribute('aria-pressed','false');updateModifierButtons();updateControlState();
}
function closePeer(){
  release();connected=false;inputAllowed=false;clearInterval(polling);polling=null;clearInterval(statsTimer);statsTimer=null;
  if(peer){peer.onconnectionstatechange=null;peer.onicecandidate=null;peer.close();}
  peer=null;control=null;pointer=null;mediaID=null;candidates=[];candidateOffset=0;previousStats=null;captureInfo={};
  sessionInfo=null;
  $('video').srcObject=null;$('screen-overlay').hidden=false;updateControlState();
}
function layoutVideo(){
  const size=Core.surfaceSize($('video').videoWidth,$('video').videoHeight,$('screen').clientWidth,$('screen').clientHeight,$('zoom').value,window.devicePixelRatio);
  $('surface').style.width=`${size.width}px`;$('surface').style.height=`${size.height}px`;
  $('surface').style.marginTop=`${Math.max(0,($('screen').clientHeight-size.height)/2)}px`;
}
new ResizeObserver(layoutVideo).observe($('screen'));
new ResizeObserver(()=>{if(activePanel==='keyboard-panel')$('desktop').style.setProperty('--keyboard-space',`${$('keyboard-panel').offsetHeight+20}px`);}).observe($('keyboard-panel'));
$('video').addEventListener('resize',layoutVideo);$('video').addEventListener('loadedmetadata',layoutVideo);
$('zoom').addEventListener('change',()=>{release();layoutVideo();centerView();});
function centerView(){$('screen').scrollLeft=($('screen').scrollWidth-$('screen').clientWidth)/2;$('screen').scrollTop=($('screen').scrollHeight-$('screen').clientHeight)/2;}
$('center-view').addEventListener('click',centerView);
function closePanels(focus=true){
  $('lock-text').value='';
  document.querySelectorAll('.panel').forEach(panel=>panel.hidden=true);
  document.querySelectorAll('[data-panel]').forEach(button=>button.setAttribute('aria-expanded','false'));
  activePanel=null;$('desktop').classList.remove('keyboard-open');updateControlState();if(focus)$('screen').focus({preventScroll:true});
}
function openPanel(id){
  const closing=activePanel===id;release();closePanels(false);if(closing){$('screen').focus({preventScroll:true});return;}
  activePanel=id;$(id).hidden=false;$('desktop').classList.toggle('keyboard-open',id==='keyboard-panel');if(id==='keyboard-panel')$('desktop').style.setProperty('--keyboard-space',`${$('keyboard-panel').offsetHeight+20}px`);document.querySelectorAll(`[data-panel="${id}"]`).forEach(button=>button.setAttribute('aria-expanded','true'));updateControlState();
}
document.querySelectorAll('[data-panel]').forEach(button=>button.addEventListener('click',()=>openPanel(button.dataset.panel)));
document.querySelectorAll('[data-close-panel]').forEach(button=>button.addEventListener('click',()=>{release();closePanels();}));
function collapseToolbar(collapse){closePanels();$('desktop').classList.toggle('toolbar-collapsed',collapse);$('show-toolbar').hidden=!collapse;layoutVideo();}
$('collapse-toolbar').addEventListener('click',()=>collapseToolbar(true));$('show-toolbar').addEventListener('click',()=>collapseToolbar(false));
async function toggleFullscreen(){
  release();
  try{
    if(document.fullscreenElement)await document.exitFullscreen();
    else if($('desktop').classList.contains('pseudo-fullscreen'))$('desktop').classList.remove('pseudo-fullscreen');
    else if($('desktop').requestFullscreen)await $('desktop').requestFullscreen();
    else{$('desktop').classList.add('pseudo-fullscreen');message(t("System full screen is unavailable. Filling the browser page instead."));}
  }catch(error){message(t("Unable to enter full screen: {0}", t(error.message)));}
  updateFullscreen();
}
function updateFullscreen(){const full=!!document.fullscreenElement||$('desktop').classList.contains('pseudo-fullscreen');$('fullscreen').querySelector('span').textContent=full?t("Exit full screen"):t("Full screen");$('fullscreen').title=full?t("Exit full screen"):t("Enter full screen");layoutVideo();}
$('fullscreen').addEventListener('click',toggleFullscreen);document.addEventListener('fullscreenchange',()=>{release();updateFullscreen();});
async function flushCandidates(epoch){
  if(!mediaID||epoch!==connectionEpoch)return;const pending=candidates;candidates=[];
  for(const candidate of pending){if(epoch!==connectionEpoch)return;await api('candidate',{mediaID,candidate});}
}
async function desktopOffer(current){
  const offer=await current.createOffer(),profiles=[];
  for(const prefix of ['42e0','6400','640c']){
    if(!offer.sdp.includes(`profile-level-id=${prefix}`))continue;
    try{const result=await navigator.mediaCapabilities?.decodingInfo({type:'webrtc',video:{contentType:`video/H264;profile-level-id=${prefix}34;packetization-mode=1`,width:3840,height:2160,bitrate:48000000,framerate:30}});if(result?.supported)profiles.push(prefix);}catch{}
  }
  const upgraded={type:'offer',sdp:Core.upgradeH264SDP(offer.sdp,profiles)};
  try{await current.setLocalDescription(upgraded);}catch{await current.setLocalDescription(offer);}
}
async function startPeer(){
  if(connecting||!token)return;connecting=true;deliberateClose=false;clearTimeout(retryTimer);retryTimer=null;
  const epoch=++connectionEpoch;closePeer();state(t("Connecting"));$('overlay-title').textContent=t("Establishing a live connection");$('overlay-detail').textContent=t("Preparing encrypted video and control channels…");
  try{
    const selected=$('display').value,available=await api('displays');if(epoch!==connectionEpoch)return;
    if(!available.length)throw new Error(t("The host Mac has no display available for capture."));
    setDisplays(available,available.some(display=>String(display.id)===selected)?selected:available[0].id);
    const current=new RTCPeerConnection({iceServers:[],bundlePolicy:'max-bundle'});peer=current;
    const transceiver=current.addTransceiver('video',{direction:'recvonly'});
    const codecs=RTCRtpReceiver.getCapabilities('video')?.codecs.filter(codec=>codec.mimeType.toLowerCase()==='video/h264'&&codec.sdpFmtpLine?.includes('packetization-mode=1')&&/profile-level-id=(42e0|6400|640c)/i.test(codec.sdpFmtpLine));
    if(codecs?.length&&transceiver.setCodecPreferences)transceiver.setCodecPreferences(codecs.sort((a,b)=>Number(b.sdpFmtpLine.includes('=64'))-Number(a.sdpFmtpLine.includes('=64'))));
    control=current.createDataChannel('control',{ordered:true});pointer=current.createDataChannel('pointer',{ordered:false,maxRetransmits:0});
    control.onopen=updateControlState;control.onclose=()=>{release();updateControlState();};
    current.ontrack=event=>{if(epoch===connectionEpoch){$('video').srcObject=new MediaStream([event.track]);$('video').play().catch(()=>message(t("Click the screen to start playback.")));}};
    current.onicecandidate=event=>{if(!event.candidate||epoch!==connectionEpoch)return;candidates.push(event.candidate.toJSON());if(mediaID)flushCandidates(epoch).catch(error=>message(error.message));};
    current.onconnectionstatechange=()=>{
      if(epoch!==connectionEpoch)return;connected=current.connectionState==='connected';
      if(connected){retryCount=0;state(t("Connected"),true);renderSessionOverlay();message();layoutVideo();}
      if(['failed','disconnected'].includes(current.connectionState)){release();scheduleReconnect(t("Connection interrupted. Recovering…"));}
    };
    await desktopOffer(current);if(epoch!==connectionEpoch)return;
    const answer=await api('offer',{sdp:current.localDescription.sdp,displayID:Number($('display').value),quality:$('quality').value});
    if(epoch!==connectionEpoch)return;mediaID=answer.mediaID;await current.setRemoteDescription({type:'answer',sdp:answer.sdp});await flushCandidates(epoch);
    let pollBusy=false;
    const poll=async()=>{
      if(pollBusy||epoch!==connectionEpoch)return;pollBusy=true;
      try{
        const result=await api('poll');if(epoch!==connectionEpoch)return;
        if((inputAllowed&&!result.inputPermission)||sessionInfo?.state!==result.session?.state){release();$('text').value='';}
        inputAllowed=result.inputPermission;sessionInfo=result.session||null;
        if(Array.isArray(result.displays)){
          const selected=result.displayID??$('display').value;
          if(JSON.stringify(result.displays)!==JSON.stringify(displays)||String(selected)!==$('display').value)setDisplays(result.displays,selected);
        }
        updateControlState();renderSessionOverlay();
        if(result.mediaID!==mediaID)throw new Error(result.message||t("Remote session ended"));
        for(const candidate of result.candidates.slice(candidateOffset))await current.addIceCandidate(candidate);
        candidateOffset=result.candidates.length;captureInfo=result.capture||{};renderQuality();
      }catch(error){if(epoch!==connectionEpoch)return;if(error.status===401){await logout(false);message(error.message);}else scheduleReconnect(error.message);}finally{pollBusy=false;}
    };
    await poll();if(epoch!==connectionEpoch||!token||current.connectionState==='closed')return;
    polling=setInterval(poll,1500);statsTimer=setInterval(()=>updateStats(current,epoch).catch(()=>{}),1500);
  }catch(error){if(epoch!==connectionEpoch)return;closePeer();if(error.status===401)await logout(false);else state(t("Connection failed"));$('overlay-title').textContent=t("Temporarily unable to connect");$('overlay-detail').textContent=t(error.message);message(error.message);}
  finally{if(epoch===connectionEpoch)connecting=false;}
}
function renderQuality(){
  const display=displays.find(d=>String(d.id)===$('display').value);
  $('source-size').textContent=display?`${display.width} × ${display.height}`:'—';
  $('capture-size').textContent=captureInfo.width?`${captureInfo.width} × ${captureInfo.height}`:'—';
  const low=captureInfo.width&&display&&$('quality').value==='native'&&captureInfo.width* captureInfo.height<Math.min(display.width*display.height,3840*2160)*.45;
  $('quality-warning').hidden=!low;$('quality-warning').textContent=t("Capture is below the selected quality limit, possibly due to browser H.264 negotiation. Try updating the browser or using Vela Connect.");
}
async function updateStats(current,epoch){
  if(current.connectionState!=='connected')return;const report=await current.getStats();if(epoch!==connectionEpoch)return;
  let video,rtt;report.forEach(stat=>{if(stat.type==='inbound-rtp'&&(stat.kind==='video'||stat.mediaType==='video'))video=stat;if(stat.type==='candidate-pair'&&stat.state==='succeeded'&&stat.nominated)rtt=stat.currentRoundTripTime;});
  if(!video)return;const width=video.frameWidth||$('video').videoWidth,height=video.frameHeight||$('video').videoHeight;
  const mbps=Core.bitrate(previousStats,video);previousStats={timestamp:video.timestamp,bytesReceived:video.bytesReceived};
  const fps=Math.round(video.framesPerSecond||0);$('received-size').textContent=width?`${width} × ${height}`:t("Waiting for video");$('fps-value').textContent=`${fps} FPS`;$('bitrate-value').textContent=mbps===null?'—':`${mbps.toFixed(1)} Mbps`;$('rtt-value').textContent=Number.isFinite(rtt)?`${Math.round(rtt*1000)} ms`:'—';
  $('stats').textContent=`${width||'—'} × ${height||'—'} · ${fps} FPS${Number.isFinite(rtt)?` · ${Math.round(rtt*1000)} ms`:''}`;
}
function scheduleReconnect(reason){
  if(deliberateClose||!token||retryTimer)return;release();connected=false;state(t("Reconnecting"));message(reason);$('screen-overlay').hidden=false;$('overlay-title').textContent=t("Restoring connection");$('overlay-detail').textContent=t(reason);
  if(retryCount>=5){state(t("Connection interrupted"));message(t("Automatic reconnection failed. Reconnect using the toolbar."),true);return;}
  retryTimer=setTimeout(()=>{retryTimer=null;if(connecting){scheduleReconnect(reason);return;}retryCount++;startPeer();},Math.min(10000,1500*2**retryCount));
}
async function logout(notify=true){
  deliberateClose=true;++connectionEpoch;connecting=false;clearTimeout(retryTimer);retryTimer=null;release();
  const oldToken=token;token=null;closePeer();closePanels(false);
  if(notify&&oldToken){try{await fetch('/api/logout',{method:'POST',headers:{Authorization:`Bearer ${oldToken}`,'Content-Type':'application/json'},body:'{}',credentials:'omit',signal:AbortSignal.timeout(3000)});}catch{}}
  if(document.fullscreenElement){try{await document.exitFullscreen();}catch{}}
  document.querySelector('main').append($('message'));$('desktop').classList.remove('pseudo-fullscreen','toolbar-collapsed');$('show-toolbar').hidden=true;
  state(t("Not connected"));$('desktop').hidden=true;$('login').hidden=false;document.body.classList.remove('session');$('password').value='';$('stats').textContent='';
}
$('login-form').addEventListener('submit',async event=>{
  event.preventDefault();$('login-button').disabled=true;message();
  try{
    if(!authentication)throw new Error(t("Read the host authentication method first."));const password=$('password').value;$('password').value='';
    const result=await api('login',{password,mode:authentication.mode,generation:authentication.generation});token=result.token;
    const available=await api('displays');if(!available.length)throw new Error(t("The host Mac has no display available for capture."));
    setDisplays(available);
    const capabilities=await api('display-capabilities');virtualSupported=capabilities.virtualDisplay===true;blackoutSupported=capabilities.physicalBlackout===true;
    $('virtual-status').textContent=virtualSupported?t("An independent remote display can be created."):t("This system does not support virtual displays.");updateVirtualControls();
    $('login').hidden=true;$('desktop').hidden=false;document.body.classList.add('session');$('desktop').append($('message'));retryCount=0;layoutVideo();renderQuality();await startPeer();
  }catch(error){if(token)await logout(true);await refreshAuthentication();message(error.message,true);}
  finally{$('password').value='';$('login-button').disabled=!authentication;}
});
$('disconnect').addEventListener('click',()=>logout());$('reconnect').addEventListener('click',()=>{retryCount=0;startPeer();});
let displayChanging=false;
async function changeDisplay(){
  if(displayChanging||virtualBusy||!mediaID)return;displayChanging=true;release();$('display').disabled=true;$('quality').disabled=true;
  try{await api('display',{mediaID,displayID:Number($('display').value),quality:$('quality').value});captureInfo={};renderQuality();layoutVideo();message(t("Quality updated. Live dimensions appear when video arrives."));}
  catch(error){message(error.message);}finally{displayChanging=false;$('display').disabled=false;$('quality').disabled=false;}
}
$('display').addEventListener('change',changeDisplay);$('quality').addEventListener('change',changeDisplay);
$('release').addEventListener('click',()=>{release();message(t("All keys released."));});$('emergency-release').addEventListener('click',()=>{release();$('screen').blur();message(t("Input released."));});
$('control-state').addEventListener('click',()=>{if(dragging){release();return;}if(sessionInfo?.requiresAccountVerification){openPanel('privacy-panel');return;}if(!inputAllowed)message(t("Check the session status and Accessibility access on the host Mac."));else{$('screen').focus({preventScroll:true});}});
$('view-only').addEventListener('click',()=>{release();viewOnly=!viewOnly;$('view-only').setAttribute('aria-pressed',String(viewOnly));$('view-only').textContent=viewOnly?t("Resume keyboard and mouse control"):t("Switch to view only");updateControlState();});
function tapKey(code){for(const action of ['down','up'])send({type:'key',code,action,modifiers:modifiers()});}
function shortcut(codes,preserveTouches=false){
  release({preserveTouches});const down=[];for(const code of codes){down.push(code);send({type:'key',code,action:'down',modifiers:down.map(c=>modifierName[c]).filter(Boolean)});}
  for(const code of [...codes].reverse()){down.splice(down.indexOf(code),1);send({type:'key',code,action:'up',modifiers:down.map(c=>modifierName[c]).filter(Boolean)});}
}
const keyRows=[
  [['Escape','Esc'],...Array.from({length:12},(_,i)=>[`F${i+1}`,`F${i+1}`])],
  [['Backquote','`'],...Array.from({length:10},(_,i)=>[`Digit${(i+1)%10}`,`${(i+1)%10}`]),['Minus','−'],['Equal','='],['Backspace','⌫','wide-key']],
  [['Tab','Tab','wide-key'],...'QWERTYUIOP'.split('').map(k=>[`Key${k}`,k]),['BracketLeft','['],['BracketRight',']'],['Backslash','\\']],
  [['CapsLock','⇪','wide-key'],...'ASDFGHJKL'.split('').map(k=>[`Key${k}`,k]),['Semicolon',';'],['Quote',"'"],['Enter','↵','wide-key']],
  [['ShiftLeft','⇧','wide-key'],...'ZXCVBNM'.split('').map(k=>[`Key${k}`,k]),['Comma',','],['Period','.'],['Slash','/'],['ArrowUp','↑'],['Delete','Del']],
  [['ControlLeft','⌃'],['AltLeft','⌥'],['MetaLeft','⌘'],['Space',t("Space"),'space-key'],['Home','↖'],['End','↘'],['ArrowLeft','←'],['ArrowDown','↓'],['ArrowRight','→']]
];
for(const [index,row] of keyRows.entries()){
  const container=document.createElement('div');container.className=`keyboard-row${index===0?' functions':''}`;
  for(const [code,label,style] of row){const button=document.createElement('button');button.textContent=label;button.dataset.key=code;button.dataset.remoteInput='';button.className=style||'';button.title=code;button.setAttribute('aria-label',code);
    if(modifierName[code]){button.classList.add('modifier');button.setAttribute('aria-pressed','false');}
    button.addEventListener('click',()=>{if(modifierName[code]){if(heldModifiers.has(code))heldModifiers.delete(code);else heldModifiers.add(code);send({type:'key',code,action:heldModifiers.has(code)?'down':'up',modifiers:modifiers()});updateModifierButtons();}else tapKey(code);});container.append(button);
  }$('virtual-keyboard').append(container);
}
document.querySelectorAll('[data-shortcut]').forEach(button=>button.addEventListener('click',()=>shortcut(button.dataset.shortcut.split(','))));
const desktopActions={previous:{code:'ArrowLeft',label:t("Previous desktop")},next:{code:'ArrowRight',label:t("Next desktop")},overview:{code:'ArrowUp',label:t("Mission Control")}};
function desktopAction(action,preserveTouches=false){
  if(!canInput()||!desktopActions[action])return;
  shortcut(['ControlLeft',desktopActions[action].code],preserveTouches);
  message(t("Sent the {0} shortcut.", t(desktopActions[action].label)));
}
document.querySelectorAll('[data-desktop-action]').forEach(button=>button.addEventListener('click',()=>desktopAction(button.dataset.desktopAction)));
$('text').addEventListener('focus',release);$('lock-text').addEventListener('focus',release);
$('text-form').addEventListener('submit',event=>{
  event.preventDefault();const locked=sessionInfo?.state==='locked',field=$(locked?'lock-text':'text'),text=field.value;if(!canInput()){message(t("Input is unavailable. Check the connection and Accessibility access."));return;}
  if(new TextEncoder().encode(text).byteLength>8192){message(t("Send at most 8192 bytes at a time. Split longer text into smaller parts."));return;}
  if(text&&send({type:'text',text})){field.value='';message(locked?t("Sent to the system password field. Press Enter on the remote keyboard to unlock."):t("Text sent."));}
});
function setPoint(point){lastPoint=point;$('remote-cursor').style.left=`${point.x*100}%`;$('remote-cursor').style.top=`${point.y*100}%`;}
function pointerInput(action,point=lastPoint,button=0,event={}){setPoint(point);return {type:'pointer',action,...point,button,displayID:Number($('display').value),sequence:++sequence,modifiers:modifiers(event)};}
function move(point,event={}){lastMove=pointerInput('move',point,0,event);if(!moveFrame)moveFrame=requestAnimationFrame(()=>{if(lastMove)send(lastMove,true);lastMove=null;moveFrame=null;});}
function clickAt(button){for(const action of ['down','up'])send(pointerInput(action,lastPoint,button));}
$('left-click').addEventListener('click',()=>clickAt(0));$('right-click').addEventListener('click',()=>clickAt(2));
$('drag-toggle').addEventListener('click',()=>{dragging=!dragging;send(pointerInput(dragging?'down':'up'));$('drag-toggle').setAttribute('aria-pressed',String(dragging));updateControlState();if(dragging)closePanels();});
$('touch-mode').addEventListener('change',()=>{release();$('touch-help').textContent=$('touch-mode').value==='trackpad'?t("Slide one finger to move the pointer, tap to click, long-press to right-click, and scroll with two fingers. Enable Drag to drag items."):t("Tap the matching position on screen, hold and move to drag, long-press to right-click, and scroll with two fingers.");});
function touchStart(event){
  touches.set(event.pointerId,{x:event.clientX,y:event.clientY});
  if(touches.size>1){
    clearTimeout(longPressTimer);
    if(!touchGesture?.multi){
      if(touchGesture?.down||dragging)send(pointerInput('up'));
      dragging=false;$('drag-toggle').setAttribute('aria-pressed','false');
      lastMove=null;if(moveFrame)cancelAnimationFrame(moveFrame);moveFrame=null;
      touchGesture={multi:true,peak:touches.size,scrollAfter:performance.now()+120};updateControlState();
    }
    touchGesture.peak=Math.max(touchGesture.peak,touches.size);
    touchGesture.lastY=[...touches.values()].reduce((sum,p)=>sum+p.y,0)/touches.size;
    if(touches.size===4&&!touchGesture.finished)touchGesture.origin=new Map(touches);
    if(touches.size>4)touchGesture.finished=true;
    return;
  }
  const direct=$('touch-mode').value==='direct',point=Core.point($('surface').getBoundingClientRect(),event.clientX,event.clientY,true);
  touchGesture={x:event.clientX,y:event.clientY,startX:event.clientX,startY:event.clientY,moved:false,down:false};
  if(direct&&point)setPoint(point);
  $('remote-cursor').hidden=false;
  longPressTimer=setTimeout(()=>{if(!touchGesture||touchGesture.moved||touchGesture.multi)return;if(touchGesture.down)send(pointerInput('up'));clickAt(2);touchGesture.long=true;touchGesture.down=false;},600);
}
function touchMove(event){
  if(!touches.has(event.pointerId)||!touchGesture)return;touches.set(event.pointerId,{x:event.clientX,y:event.clientY});
  if(touchGesture.multi){
    if(touchGesture.finished)return;
    if(touches.size===4&&touchGesture.origin){
      const action=Core.fourFingerAction(touchGesture.origin,touches);
      if(action){touchGesture.finished=true;desktopAction(action,true);}
    }else if(touches.size===2&&touchGesture.peak===2){
      const y=[...touches.values()].reduce((sum,p)=>sum+p.y,0)/2;
      if(performance.now()>=touchGesture.scrollAfter)send({type:'scroll',deltaX:0,deltaY:Math.max(-2000,Math.min(2000,(touchGesture.lastY-y)*2)),displayID:Number($('display').value),modifiers:modifiers()});
      touchGesture.lastY=y;
    }
    return;
  }
  const dx=event.clientX-touchGesture.x,dy=event.clientY-touchGesture.y;
  if(Math.hypot(event.clientX-touchGesture.startX,event.clientY-touchGesture.startY)>5){touchGesture.moved=true;clearTimeout(longPressTimer);}
  if($('touch-mode').value==='direct'&&touchGesture.moved&&!touchGesture.down&&!touchGesture.long&&!dragging){send(pointerInput('down'));touchGesture.down=true;}
  const rect=$('surface').getBoundingClientRect();let point;
  if($('touch-mode').value==='direct')point=Core.point(rect,event.clientX,event.clientY,true);
  else point={x:Math.max(0,Math.min(1,lastPoint.x+dx/Math.max(1,rect.width))),y:Math.max(0,Math.min(1,lastPoint.y+dy/Math.max(1,rect.height)))};
  if(point)move(point);touchGesture.x=event.clientX;touchGesture.y=event.clientY;
}
function touchEnd(event){
  clearTimeout(longPressTimer);if(!touches.has(event.pointerId))return;
  touches.delete(event.pointerId);
  if(touchGesture?.multi){touchGesture.finished=true;if(!touches.size)touchGesture=null;return;}
  if(touchGesture&&!touchGesture.multi&&!touchGesture.long){if(touchGesture.down)send(pointerInput('up'));else if(!touchGesture.moved&&!dragging)clickAt(0);}
  if(!touches.size)touchGesture=null;
}
$('screen').addEventListener('pointerdown',event=>{
  if(!canInput())return;const point=Core.point($('surface').getBoundingClientRect(),event.clientX,event.clientY);if(!point&&!(event.pointerType==='touch'&&$('touch-mode').value==='trackpad'))return;
  event.preventDefault();if(activePanel){release();closePanels(false);}$('screen').focus({preventScroll:true});$('screen').setPointerCapture(event.pointerId);
  if(event.pointerType==='touch'){touchStart(event);return;}$('remote-cursor').hidden=true;mouseButtons.add(event.button);send(pointerInput('down',point,Math.min(2,event.button),event));
});
$('screen').addEventListener('pointermove',event=>{
  if(event.pointerType==='touch'){if(touches.has(event.pointerId)){event.preventDefault();touchMove(event);}return;}
  const point=Core.point($('surface').getBoundingClientRect(),event.clientX,event.clientY,mouseButtons.size>0);if(point)move(point,event);
});
$('screen').addEventListener('pointerup',event=>{
  if(event.pointerType==='touch'){event.preventDefault();touchEnd(event);return;}
  if(!mouseButtons.has(event.button))return;mouseButtons.delete(event.button);const point=Core.point($('surface').getBoundingClientRect(),event.clientX,event.clientY,true);if(point)send(pointerInput('up',point,Math.min(2,event.button),event));
});
$('screen').addEventListener('pointercancel',release);$('screen').addEventListener('lostpointercapture',event=>{if(mouseButtons.size||touches.has(event.pointerId))release();});
$('screen').addEventListener('contextmenu',event=>event.preventDefault());
$('screen').addEventListener('wheel',event=>{
  if(!canInput()||event.ctrlKey||event.metaKey)return;event.preventDefault();const point=Core.point($('surface').getBoundingClientRect(),event.clientX,event.clientY);if(point)send(pointerInput('move',point,0,event));
  const scale=event.deltaMode===1?16:event.deltaMode===2?500:1;send({type:'scroll',deltaX:Math.max(-2000,Math.min(2000,event.deltaX*scale)),deltaY:Math.max(-2000,Math.min(2000,event.deltaY*scale)),displayID:Number($('display').value),modifiers:modifiers(event)});
},{passive:false});
$('screen').addEventListener('keydown',event=>{
  if(event.ctrlKey&&event.altKey&&event.shiftKey){event.preventDefault();release();$('screen').blur();message(t("Keyboard and mouse released. Click the screen to resume."));return;}
  if(event.isComposing||event.key==='Process')return;if(event.key==='Escape'&&document.fullscreenElement){release();return;}
  if(!canInput())return;event.preventDefault();heldKeys.add(event.code);send({type:'key',action:'down',code:event.code,modifiers:modifiers(event)});
});
$('screen').addEventListener('keyup',event=>{if(!heldKeys.has(event.code))return;event.preventDefault();heldKeys.delete(event.code);send({type:'key',action:'up',code:event.code,modifiers:modifiers(event)});});
$('screen').addEventListener('blur',release);
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&activePanel){event.preventDefault();release();closePanels();}});
window.addEventListener('blur',release);document.addEventListener('visibilitychange',()=>{if(document.hidden)release();});window.addEventListener('pagehide',()=>{release();if(peer)peer.close();});
VelaI18n.ready.then(()=>{VelaI18n.apply();updateControlState();refreshAuthentication();});
window.addEventListener('vela-language-change',()=>{updateControlState();updateVirtualSummary();updateFullscreen();renderQuality();if(connected)renderSessionOverlay();});
