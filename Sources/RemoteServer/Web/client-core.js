'use strict';
// Shared pure calculations: keep input coordinates and quality diagnostics testable.
(function(root){
  const modifierName={MetaLeft:'meta',MetaRight:'meta',AltLeft:'alt',AltRight:'alt',ControlLeft:'control',ControlRight:'control',ShiftLeft:'shift',ShiftRight:'shift'};
  function surfaceSize(width,height,availableWidth,availableHeight,zoom='fit',dpr=1){
    if(!width||!height||!availableWidth||!availableHeight)return {width:availableWidth||0,height:availableHeight||0};
    const scale=zoom==='fit'?Math.min(availableWidth/width,availableHeight/height):Number(zoom)/Math.max(1,dpr);
    return {width:width*scale,height:height*scale};
  }
  function point(rect,clientX,clientY,clamp=false){
    if(rect.width<=0||rect.height<=0)return null;
    const x=(clientX-rect.left)/rect.width,y=(clientY-rect.top)/rect.height;
    if(!clamp&&(x<0||y<0||x>1||y>1))return null;
    return {x:Math.min(1,Math.max(0,x)),y:Math.min(1,Math.max(0,y))};
  }
  function viewportFeedback(width,height,dpr,zoom){
    // Detail views retain the selected source quality instead of a window-sized budget.
    if(zoom!=='fit')return {};
    const scale=Math.max(1,Math.min(3,dpr||1));
    return {viewportWidth:Math.max(1,Math.min(16384,Math.round(width*scale))),viewportHeight:Math.max(1,Math.min(16384,Math.round(height*scale)))};
  }
  function bitrate(previous,current){
    const dt=current.timestamp-(previous?.timestamp??current.timestamp),db=current.bytesReceived-(previous?.bytesReceived??current.bytesReceived);
    return dt>0&&db>=0?db*8/dt/1000:null;
  }
  function verifiedHEVCCodecs(codecs,verification){
    if(!verification?.supported||!verification?.powerEfficient)return [];
    return codecs.filter(codec=>{
      if(codec.mimeType.toLowerCase()!=='video/h265')return false;
      const parameters=Object.fromEntries((codec.sdpFmtpLine||'').split(';').map(field=>field.trim().split('=')));
      return (parameters['profile-id']||'1')==='1'&&(parameters['tier-flag']||'0')==='0'&&(parameters['tx-mode']||'SRST')==='SRST';
    });
  }
  function receiverFeedback(previous,current){
    if(!previous||current.id!==previous.id||current.timestamp<=previous.timestamp)return {};
    const frames=current.framesDecoded-previous.framesDecoded,dropped=current.framesDropped-previous.framesDropped;
    const seconds=current.totalDecodeTime-previous.totalDecodeTime,result={};
    if(Number.isFinite(frames)&&frames>0&&Number.isFinite(seconds)&&seconds>=0)result.decodeMilliseconds=seconds*1000/frames;
    if(Number.isFinite(frames)&&frames>=0&&Number.isFinite(dropped)&&dropped>=0&&frames+dropped>0)result.droppedFrameRatio=dropped/(frames+dropped);
    return result;
  }
  function validVirtualDisplay({width,height,hiDPI}){
    if(!Number.isInteger(width)||!Number.isInteger(height)||width<640||height<480||width>3840||height>3840||width%2||height%2||width*height>3840*2160)return false;
    const portrait=height>width;
    return !hiDPI||(width>=(portrait?960:1280)&&height>=(portrait?1280:960));
  }
  function upgradeH264SDP(sdp,profiles){
    return sdp.split(/(?=m=)/).map(section=>{
      if(!section.startsWith('m=video'))return section;
      const payloads=new Set([...section.matchAll(/^a=rtpmap:(\d+) H264\/90000/gmi)].map(match=>match[1]));
      return section.replace(/^a=fmtp:(\d+) (.*)$/gmi,(line,payload,parameters)=>{
        if(!payloads.has(payload)||!parameters.includes('packetization-mode=1'))return line;
        return line.replace(/profile-level-id=([0-9a-f]{4})([0-9a-f]{2})/gi,(value,profile,level)=>
          profiles.includes(profile.toLowerCase())&&parseInt(level,16)<52?`profile-level-id=${profile}34`:value);
      });
    }).join('');
  }
  function fourFingerAction(origin,current){
    if(origin.size!==4||current.size!==4)return null;
    const deltas=[...origin].map(([id,p])=>{const q=current.get(id);return q?{x:q.x-p.x,y:q.y-p.y}:null;});
    if(deltas.some(p=>!p))return null;
    const dx=deltas.reduce((sum,p)=>sum+p.x,0)/4,dy=deltas.reduce((sum,p)=>sum+p.y,0)/4;
    if(Math.abs(dx)>=60&&Math.abs(dx)>Math.abs(dy)*1.4&&deltas.every(p=>p.x*Math.sign(dx)>=40&&Math.abs(p.x)>Math.abs(p.y)*1.2))return dx<0?'next':'previous';
    if(dy<=-60&&-dy>Math.abs(dx)*1.4&&deltas.every(p=>p.y<=-40&&-p.y>Math.abs(p.x)*1.2))return 'overview';
    return null;
  }
  const api={modifierName,surfaceSize,point,viewportFeedback,bitrate,upgradeH264SDP,fourFingerAction,validVirtualDisplay,receiverFeedback,verifiedHEVCCodecs};
  if(typeof module!=='undefined')module.exports=api;
  root.RemoteClientCore=api;
})(globalThis);
