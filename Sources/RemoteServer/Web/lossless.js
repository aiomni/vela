'use strict';
// Enhancement is displayed only when its content version matches the displayed RTP frame.
(function(root){
  class LosslessReceiver {
    constructor({decode,draw,clear,now=()=>performance.now()}){
      this.decode=decode;this.draw=draw;this.clear=clear;this.now=now;this.reset();
    }
    reset(){
      this.generation=(this.generation||0)+1;
      for(const tile of this.tiles?.values()||[])tile.image.close?.();
      this.markers=new Map();this.parts=new Map();this.tiles=new Map();this.current=null;this.frame=null;this.clear();
    }
    key(value){return `${value.epoch}:${value.version}:${value.width}:${value.height}`;}
    validMarker(value){
      return typeof value.epoch==='string'&&value.epoch.length<=64&&Number.isSafeInteger(value.version)&&value.version>=0&&
        [value.width,value.height].every(n=>Number.isInteger(n)&&n>=2&&n<=3840)&&value.width*value.height<=3840*2160;
    }
    present(rtpTimestamp,width,height){
      this.frame={rtpTimestamp,width,height};this.select();
    }
    select(){
      const marker=this.frame&&this.markers.get(this.frame.rtpTimestamp);
      const next=marker&&marker.width===this.frame.width&&marker.height===this.frame.height?marker:null;
      if(this.current&&(!next||this.key(this.current)!==this.key(next))){
        for(const tile of this.tiles.values())tile.image.close?.();
        this.tiles.clear();this.parts.clear();this.generation++;
      }
      this.current=next;this.clear();
      if(next)for(const tile of this.tiles.values())if(tile.key===this.key(next))this.draw(tile.image,tile.x,tile.y,next.width,next.height);
    }
    async receive(value){
      if(!this.validMarker(value))return;
      if(value.type==='frame'){
        if(!Number.isInteger(value.rtpTimestamp)||value.rtpTimestamp<0||value.rtpTimestamp>0xffffffff)return;
        this.markers.set(value.rtpTimestamp,value);
        while(this.markers.size>128)this.markers.delete(this.markers.keys().next().value);
        if(this.frame?.rtpTimestamp===value.rtpTimestamp)this.select();
        return;
      }
      if(value.type!=='tile'||!this.current||this.key(value)!==this.key(this.current))return;
      const {x,y,tileWidth:w,tileHeight:h,part,count,data}=value;
      if(![x,y,w,h,part,count].every(Number.isInteger)||x<0||y<0||w<1||h<1||w>512||h>512||x+w>value.width||y+h>value.height||count<1||count>16||part<0||part>=count||typeof data!=='string'||data.length>10924)return;
      const now=this.now();for(const [key,entry] of this.parts)if(now-entry.time>3000)this.parts.delete(key);
      const key=`${x}:${y}:${w}:${h}`,scene=this.key(value);
      if(this.tiles.has(key))return;
      if(!this.parts.has(key)){
        if(this.parts.size>=32)return;
        this.parts.set(key,{time:now,count,chunks:new Map(),bytes:0});
      }
      const entry=this.parts.get(key);if(entry.count!==count||entry.chunks.has(part))return;
      let bytes;try{bytes=Uint8Array.from(atob(data),c=>c.charCodeAt(0));}catch{return;}
      if(bytes.length>8192||entry.bytes+bytes.length>131072)return;
      entry.chunks.set(part,bytes);entry.bytes+=bytes.length;
      if(entry.chunks.size!==count)return;
      this.parts.delete(key);
      const png=new Uint8Array(entry.bytes);let offset=0;
      for(let i=0;i<count;i++){const chunk=entry.chunks.get(i);png.set(chunk,offset);offset+=chunk.length;}
      if(png.length<24||[137,80,78,71,13,10,26,10].some((n,i)=>png[i]!==n))return;
      const header=new DataView(png.buffer);if(header.getUint32(16)!==w||header.getUint32(20)!==h)return;
      const generation=this.generation;
      let image;try{image=await this.decode(png);}catch{return;}
      if(generation!==this.generation||!this.current||this.key(this.current)!==scene||image.width!==w||image.height!==h){image.close?.();return;}
      if(this.tiles.size>=64){image.close?.();return;}
      this.tiles.set(key,{image,x,y,key:scene});this.draw(image,x,y,value.width,value.height);
    }
  }
  root.DesktopLosslessReceiver=LosslessReceiver;
  if(typeof module!=='undefined')module.exports={LosslessReceiver};
})(globalThis);
