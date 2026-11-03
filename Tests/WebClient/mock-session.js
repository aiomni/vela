// Isolated browser fixture. No real display, account, or system input is changed.
window.__inputs=[];window.__requests=[];
const nativeFixtureFetch=window.fetch.bind(window);
window.fetch=async(path,options={})=>{
 if(!String(path).startsWith('/api/'))return nativeFixtureFetch(path,options);
 const key=String(path).split('/api/')[1];window.__requests.push(key);
 const payloads={authentication:{mode:'customPassword',generation:'fixture'},login:{token:'fixture-token'},displays:[{id:1,name:'Main Display',width:4112,height:2658}],offer:{sdp:'fixture-answer',mediaID:'fixture-media'},poll:{mediaID:'fixture-media',inputPermission:true,candidates:[],capture:{sourceWidth:4112,sourceHeight:2658,width:3340,height:2160,fps:30}},display:{ok:true},logout:{ok:true}};
 return new Response(JSON.stringify(payloads[key]||{}),{status:200,headers:{'Content-Type':'application/json'}});
};
window.RTCPeerConnection=class{
 constructor(){this.connectionState='new';this.channels=[];window.__peer=this;}
 addTransceiver(){return {setCodecPreferences(){}};}
 createDataChannel(label){const c={readyState:'open',bufferedAmount:0,send(data){window.__inputs.push({channel:label,...JSON.parse(data)});}};this.channels.push(c);return c;}
 async createOffer(){return {type:'offer',sdp:'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 108\r\na=rtpmap:108 H264/90000\r\na=fmtp:108 profile-level-id=42e01f;packetization-mode=1\r\n'};}
 async setLocalDescription(sdp){this.localDescription=sdp;}
 async setRemoteDescription(){
  const canvas=document.createElement('canvas');canvas.width=3340;canvas.height=2160;const c=canvas.getContext('2d');
  c.fillStyle='#e7ebef';c.fillRect(0,0,3340,2160);c.fillStyle='#f9fbfc';c.fillRect(90,90,3160,1980);c.fillStyle='#e7edf1';c.fillRect(90,90,520,1980);
  c.fillStyle='#16283a';c.font='600 46px sans-serif';c.fillText('WORKSPACE',155,195);c.font='32px sans-serif';for(const [i,text] of ['Overview','Design docs','Project files','Team notes','Archived'].entries()){c.fillStyle=i===1?'#196f64':'#6a7f90';c.fillText(text,155,330+i*110);}
  c.fillStyle='#213548';c.font='600 86px sans-serif';c.fillText('A clearer view of your work.',760,350);c.font='38px sans-serif';c.fillStyle='#61758a';c.fillText('Typography, interface details, and everything in between.',760,445);
  for(let i=0;i<3;i++){c.fillStyle=['#d9e9e3','#e7e1d6','#dce5ee'][i];c.fillRect(760+i*745,570,670,510);c.fillStyle='#324b52';c.font='52px sans-serif';c.fillText(['Design system','Project notes','Weekly review'][i],800+i*745,690);c.font='32px sans-serif';c.fillText('Open workspace  ↗',800+i*745,1000);}
  c.fillStyle='#263c4c';c.font='600 52px sans-serif';c.fillText('Recent activity',760,1250);c.font='35px sans-serif';for(let i=0;i<5;i++){c.fillStyle='#dce3e8';c.fillRect(760,1330+i*110,2160,2);c.fillStyle='#50657a';c.fillText(['Interface guidelines updated','Remote workflow review','Typography & spacing','Interaction notes','Delivery checklist'][i],770,1400+i*110);}
  this.stream=canvas.captureStream(30);this.ontrack?.({track:this.stream.getVideoTracks()[0]});this.connectionState='connected';this.onconnectionstatechange?.();
 }
 async addIceCandidate(){}
 async getStats(){return new Map([['v',{type:'inbound-rtp',kind:'video',frameWidth:3340,frameHeight:2160,framesPerSecond:30,timestamp:performance.now(),bytesReceived:performance.now()*2000}],['c',{type:'candidate-pair',state:'succeeded',nominated:true,currentRoundTripTime:.008}]]);}
 close(){this.connectionState='closed';this.stream?.getTracks().forEach(t=>t.stop());}
};

window.__sessionFixture={state:'local',recovering:false,requiresAccountVerification:false,canEnterPrivacy:true,canManageVirtualDisplay:true,localWakePermission:true,displaySleepRequested:false};
window.__blackoutAttempts=0;window.__restoreRequests=0;
const baseFixtureFetch=window.fetch;
window.fetch=async(path,options={})=>{
 const key=String(path).split('/api/')[1];
 const response=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json'}});
 if(key==='display-capabilities')return response({virtualDisplay:true,privateSession:false,physicalBlackout:true});
 if(key==='poll'){
  const value=await (await baseFixtureFetch(path,options)).json();value.session=window.__sessionFixture;
  value.displays=[{id:1,name:'Vela Virtual Display',width:3840,height:2160,logicalWidth:1920,logicalHeight:1080,isVirtual:true}];value.displayID=1;
  value.inputPermission=!__sessionFixture.requiresAccountVerification&&!__sessionFixture.recovering;
  return response(value);
 }
 if(key==='session/blackout'){
  __blackoutAttempts++;__sessionFixture={state:'blackout',recovering:false,requiresAccountVerification:false,canEnterPrivacy:false,canManageVirtualDisplay:false,localWakePermission:true,displaySleepRequested:true};return response({ok:true});
 }
 if(key==='session/restore-displays'){
  __restoreRequests++;__sessionFixture={state:'local',recovering:false,requiresAccountVerification:false,canEnterPrivacy:true,canManageVirtualDisplay:true,localWakePermission:true,displaySleepRequested:false};return response({ok:true});
 }
 return baseFixtureFetch(path,options);
};
