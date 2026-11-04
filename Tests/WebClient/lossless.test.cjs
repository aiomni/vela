const test=require('node:test'),assert=require('node:assert/strict');
const {LosslessReceiver}=require('../../Sources/RemoteServer/Web/lossless.js');
const core=require('../../Sources/RemoteServer/Web/client-core.js');
const marker={type:'frame',epoch:'fixture',version:1,width:1920,height:1080,rtpTimestamp:100};
function png(w=2,h=2){const b=Buffer.alloc(24);Buffer.from([137,80,78,71,13,10,26,10]).copy(b);b.writeUInt32BE(w,16);b.writeUInt32BE(h,20);return b;}
function packet(extra={}){return {...marker,type:'tile',x:0,y:0,tileWidth:2,tileHeight:2,part:0,count:1,data:png().toString('base64'),...extra};}
function fixture(decode=async()=>({width:2,height:2})){const drawn=[];let clears=0;const receiver=new LosslessReceiver({decode,draw:(...args)=>drawn.push(args),clear:()=>clears++});return {receiver,drawn,get clears(){return clears;}};}

test('only a matching displayed frame permits lossless tiles',async()=>{
 const f=fixture();await f.receiver.receive(marker);await f.receiver.receive(packet());assert.equal(f.drawn.length,0);
 f.receiver.present(100,1920,1080);await f.receiver.receive(packet());assert.equal(f.drawn.length,1);
 f.receiver.present(101,1920,1080);assert.equal(f.receiver.current,null);assert.equal(f.receiver.tiles.size,0);
 await f.receiver.receive(packet());assert.equal(f.drawn.length,1);
});
test('unordered marker arrival safely restores association and newer versions invalidate old images',async()=>{
 const f=fixture();f.receiver.present(100,1920,1080);await f.receiver.receive(marker);await f.receiver.receive(packet());
 assert.equal(f.drawn.length,1);
 await f.receiver.receive({...marker,version:2,rtpTimestamp:101});f.receiver.present(101,1920,1080);
 await f.receiver.receive(packet());assert.equal(f.receiver.tiles.size,0);
 await f.receiver.receive(packet({version:2}));assert.equal(f.receiver.tiles.size,1);
 f.receiver.reset();assert.equal(f.receiver.markers.size,0);assert.equal(f.receiver.tiles.size,0);
});
test('an asynchronous image decode cannot revive a superseded or disconnected scene',async()=>{
 let finish;const f=fixture(()=>new Promise(resolve=>finish=resolve));await f.receiver.receive(marker);f.receiver.present(100,1920,1080);
 const pending=f.receiver.receive(packet());f.receiver.reset();let closed=false;finish({width:2,height:2,close:()=>closed=true});await pending;
 assert.equal(f.drawn.length,0);assert.equal(closed,true);
});
test('bounded reassembly accepts reordered parts and rejects invalid geometry and image dimensions',async()=>{
 const f=fixture();await f.receiver.receive(marker);f.receiver.present(100,1920,1080);
 const b=png();await f.receiver.receive(packet({part:1,count:2,data:b.subarray(12).toString('base64')}));
 await f.receiver.receive(packet({part:0,count:2,data:b.subarray(0,12).toString('base64')}));assert.equal(f.drawn.length,1);
 const g=fixture();await g.receiver.receive(marker);g.receiver.present(100,1920,1080);
 for(const extra of [{tileWidth:513},{x:1919},{count:17},{data:png(512,512).toString('base64')},{data:'invalid'},{version:2}])await g.receiver.receive(packet(extra));
 assert.equal(g.drawn.length,0);
});
test('receiver feedback uses interval decode time and resets across SSRC changes',()=>{
 const previous={id:'v',timestamp:1000,framesDecoded:100,framesDropped:2,totalDecodeTime:1};
 const current={id:'v',timestamp:2000,framesDecoded:120,framesDropped:4,totalDecodeTime:1.2};
 const result=core.receiverFeedback(previous,current);assert.ok(Math.abs(result.decodeMilliseconds-10)<1e-8);assert.equal(result.droppedFrameRatio,2/22);
 assert.deepEqual(core.receiverFeedback(previous,{...current,id:'new'}),{});
 assert.deepEqual(core.receiverFeedback(previous,{...current,framesDecoded:0,framesDropped:0,totalDecodeTime:0}),{});
});

const {velaFrameIdentity}=require('../../Sources/RemoteServer/Web/frame-identity-worker.js');
test('H264 SEI identity is associated with the received RTP timestamp instead of the encoder clock',()=>{
 const uuid=Buffer.from([86,101,108,97,70,114,97,109,101,73,68,45,118,49,0,1]);
 const payload=Buffer.concat([uuid,Buffer.from(JSON.stringify({...marker,rtpTimestamp:123}))]);
 const accessUnit=Buffer.concat([Buffer.from([0,0,0,1,6,5,payload.length]),payload,Buffer.from([128,0,0,0,1,101,1,2,3])]);
 const result=velaFrameIdentity(accessUnit.buffer.slice(accessUnit.byteOffset,accessUnit.byteOffset+accessUnit.byteLength),0xfffffff0);
 assert.equal(result.rtpTimestamp,0xfffffff0);assert.equal(result.epoch,'fixture');assert.equal(result.version,1);
 assert.equal(velaFrameIdentity(Uint8Array.from([0,0,1,6,5,255]).buffer,1),null);
});

test('HEVC preference requires verified hardware-efficient WebRTC decode and compatible main profile',()=>{
 const main={mimeType:'video/H265',sdpFmtpLine:'profile-id=1;tier-flag=0;level-id=180;tx-mode=SRST'};
 const main10={mimeType:'video/H265',sdpFmtpLine:'profile-id=2;tier-flag=0;level-id=180;tx-mode=SRST'};
 const h264={mimeType:'video/H264',sdpFmtpLine:'profile-level-id=42e01f'};
 assert.deepEqual(core.verifiedHEVCCodecs([main,main10,h264],{supported:true,powerEfficient:true}),[main]);
 for(const verification of [undefined,{supported:false,powerEfficient:true},{supported:true,powerEfficient:false},{supported:true}])assert.deepEqual(core.verifiedHEVCCodecs([main],verification),[]);
 assert.deepEqual(core.verifiedHEVCCodecs([{...main,sdpFmtpLine:'profile-id=1;tx-mode=MRST'}],{supported:true,powerEfficient:true}),[]);
});
