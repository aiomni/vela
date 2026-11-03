const test=require('node:test');const assert=require('node:assert/strict');
const core=require('../../Sources/RemoteServer/Web/client-core.js');
test('All virtual display presets work with and without HiDPI, including phone portrait modes',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const html=fs.readFileSync(path.resolve(__dirname,'../../Sources/RemoteServer/Web/index.html'),'utf8');
 const select=html.match(/<select id="virtual-preset">([\s\S]*?)<\/select>/)[1];
 const presets=[...select.matchAll(/<option value="(\d+),(\d+)"/g)].map(match=>({width:Number(match[1]),height:Number(match[2])}));
 assert.equal(presets.length,18);
 assert.ok(presets.filter(p=>p.height>p.width).length>=10);
 for(const preset of presets)for(const hiDPI of [true,false])assert.equal(core.validVirtualDisplay({...preset,hiDPI}),true,JSON.stringify({...preset,hiDPI}));
 assert.match(select,/<option value="3840,2160" selected>/);
});
test('Virtual display validation rotates the HiDPI minimum without exceeding the pixel budget',()=>{
 for(const [width,height,hiDPI] of [[960,1280,true],[1080,2400,true],[1280,960,true],[720,1600,false],[2160,3840,true]]){
  assert.equal(core.validVirtualDisplay({width,height,hiDPI}),true);
 }
 for(const [width,height,hiDPI] of [[958,1280,true],[960,1278,true],[720,1600,true],[1280,958,true],[1081,2400,false],[3840,3840,false],[640,480,true],[Infinity,1920,false]]){
  assert.equal(core.validVirtualDisplay({width,height,hiDPI}),false);
 }
});
test('Four-finger desktop gestures require four coherent fingers and reject ambiguous motion',()=>{
 const origin=new Map(Array.from({length:4},(_,i)=>[i,{x:100+i*35,y:300}]));
 const moved=(dx,dy)=>new Map([...origin].map(([id,p])=>[id,{x:p.x+dx,y:p.y+dy}]));
 assert.equal(core.fourFingerAction(origin,moved(-80,5)),'next');
 assert.equal(core.fourFingerAction(origin,moved(80,-5)),'previous');
 assert.equal(core.fourFingerAction(origin,moved(5,-80)),'overview');
 for(const [dx,dy] of [[0,80],[30,0],[60,60],[0,0]])assert.equal(core.fourFingerAction(origin,moved(dx,dy)),null);
 const partial=moved(-80,0);partial.set(0,origin.get(0));assert.equal(core.fourFingerAction(origin,partial),null);
 const pinch=moved(80,0);pinch.set(0,{x:20,y:300});assert.equal(core.fourFingerAction(origin,pinch),null);
 const missing=moved(-80,0);missing.delete(0);assert.equal(core.fourFingerAction(origin,missing),null);
 const extra=moved(-80,0);extra.set(4,{x:200,y:300});assert.equal(core.fourFingerAction(origin,extra),null);
});
test('Retina pixel mapping and fit preserve aspect ratio without inventing detail',()=>{
  assert.deepEqual(core.surfaceSize(3840,2160,1280,800,'fit',2),{width:1280,height:720});
  assert.deepEqual(core.surfaceSize(3840,2160,1280,800,'1',2),{width:1920,height:1080});
  assert.deepEqual(core.surfaceSize(3840,2160,1280,800,'2',2),{width:3840,height:2160});
  assert.deepEqual(core.point({left:10,top:50,width:1920,height:1080},970,590),{x:.5,y:.5});
  assert.equal(core.point({left:10,top:50,width:1920,height:1080},9,590),null);
  assert.deepEqual(core.point({left:10,top:50,width:1920,height:1080},0,2000,true),{x:0,y:1});
});
test('Upgrade only verified H264 receive profiles in packetization mode 1',()=>{
 const sdp='v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fmtp:111 profile-level-id=42e01f\r\nm=video 9 UDP/TLS/RTP/SAVPF 108 109 110 111\r\na=rtpmap:108 H264/90000\r\na=fmtp:108 profile-level-id=42e01f;packetization-mode=1\r\na=rtpmap:109 H264/90000\r\na=fmtp:109 profile-level-id=64001f;packetization-mode=1\r\na=rtpmap:110 H264/90000\r\na=fmtp:110 profile-level-id=42e01f;packetization-mode=0\r\na=rtpmap:111 VP9/90000\r\na=fmtp:111 profile-level-id=42e01f;packetization-mode=1\r\n';
 assert.equal(core.upgradeH264SDP(sdp,[]),sdp);
 const result=core.upgradeH264SDP(sdp,['42e0','6400']);
 assert.match(result,/fmtp:108 profile-level-id=42e034/);assert.match(result,/fmtp:109 profile-level-id=640034/);
 assert.match(result,/fmtp:110 profile-level-id=42e01f/);assert.match(result,/fmtp:111 profile-level-id=42e01f/);
 assert.equal((result.match(/profile-level-id=42e034/g)||[]).length,1);
});
test('Received bitrate uses byte deltas and resets safely after reconnect',()=>{
 assert.equal(core.bitrate(null,{timestamp:1000,bytesReceived:100000}),null);
 assert.equal(core.bitrate({timestamp:1000,bytesReceived:100000},{timestamp:2000,bytesReceived:1100000}),8);
 assert.equal(core.bitrate({timestamp:2000,bytesReceived:1100000},{timestamp:3000,bytesReceived:10}),null);
});
