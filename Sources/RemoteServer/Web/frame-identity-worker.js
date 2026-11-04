'use strict';
// Read only Vela's user-data SEI. Encoded video is always forwarded unchanged.
function velaFrameIdentity(buffer,rtpTimestamp){
  const bytes=new Uint8Array(buffer,0,Math.min(buffer.byteLength,65536));
  const uuid=[86,101,108,97,70,114,97,109,101,73,68,45,118,49,0,1],starts=[];
  for(let i=0;i+3<bytes.length;){
    if(bytes[i]===0&&bytes[i+1]===0&&bytes[i+2]===1){starts.push([i,i+3]);i+=3;}
    else if(bytes[i]===0&&bytes[i+1]===0&&bytes[i+2]===0&&bytes[i+3]===1){starts.push([i,i+4]);i+=4;}
    else i++;
  }
  for(let i=0;i<starts.length;i++){
    const start=starts[i][1],end=starts[i+1]?.[0]??bytes.length;
    if(start>=end||(bytes[start]&31)!==6)continue;
    const rbsp=[];let zeros=0;
    for(let j=start+1;j<end;j++){const byte=bytes[j];if(zeros>=2&&byte===3){zeros=0;continue;}rbsp.push(byte);zeros=byte===0?zeros+1:0;}
    let cursor=0;
    while(cursor+2<=rbsp.length){
      let type=0,size=0;
      while(cursor<rbsp.length&&rbsp[cursor]===255){type+=255;cursor++;}
      if(cursor>=rbsp.length)break;type+=rbsp[cursor++];
      while(cursor<rbsp.length&&rbsp[cursor]===255){size+=255;cursor++;}
      if(cursor>=rbsp.length)break;size+=rbsp[cursor++];
      if(size>rbsp.length-cursor)break;
      if(type===5&&size>16&&size<=528&&uuid.every((n,j)=>rbsp[cursor+j]===n)){
        try{const marker=JSON.parse(new TextDecoder().decode(Uint8Array.from(rbsp.slice(cursor+16,cursor+size))));return {...marker,type:'frame',rtpTimestamp};}catch{}
      }
      cursor+=size;
    }
  }
  return null;
}
if(typeof module!=='undefined')module.exports={velaFrameIdentity};
if(typeof self!=='undefined'){
  let enabled=false;
  const pipe=(readable,writable)=>readable.pipeThrough(new TransformStream({transform(frame,controller){
    if(enabled){try{const timestamp=frame.getMetadata?.().rtpTimestamp??frame.timestamp;
      const marker=velaFrameIdentity(frame.data,timestamp);if(marker)self.postMessage(marker);
    }catch{}}
    controller.enqueue(frame);
  }})).pipeTo(writable).catch(()=>self.postMessage({type:'unavailable'}));
  self.onmessage=event=>{
    if(event.data.type==='enabled')enabled=event.data.enabled===true;
    if(event.data.type==='streams')pipe(event.data.readable,event.data.writable);
  };
  self.onrtctransform=event=>pipe(event.transformer.readable,event.transformer.writable);
}
