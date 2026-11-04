// Run on the isolated mock server after the language/session fixtures.
window.runCodecFallbackChecks=async()=>{
 const results=[],assert=(value,label)=>{if(!value)throw Error(label);results.push(label);};
 if(!window.__sessionFixture||!token)throw Error('An authenticated mock connection is required');
 const capabilities=RTCRtpReceiver.getCapabilities.bind(RTCRtpReceiver);
 const decoding=navigator.mediaCapabilities.decodingInfo.bind(navigator.mediaCapabilities);
 const savedPreference=$('stream-preference').value,savedLossless=$('lossless-text').checked,savedForce=forceH264;
 try{
  __codecFixture={supported:true,decodedFrames:0};forceH264=false;$('lossless-text').checked=false;
  RTCRtpReceiver.getCapabilities=kind=>({codecs:[{mimeType:'video/H265',clockRate:90000,sdpFmtpLine:'profile-id=1;tier-flag=0;level-id=156;tx-mode=SRST'},...capabilities(kind).codecs.filter(c=>c.mimeType.toLowerCase()!=='video/h265')]});
  navigator.mediaCapabilities.decodingInfo=async config=>config.video?.contentType.includes('H265')?{supported:true,powerEfficient:true,smooth:true}:decoding(config);
  const savedToken=token;
  await startPeer();assert(hevcAttempted,'verified HEVC is offered');assert(videoCodec==='H265','negotiated HEVC is presented');
  const original=peer;lastVideoProgress=performance.now()-7000;lastDecodedFrames=0;
  await updateStats(peer,connectionEpoch);assert(forceH264&&retryTimer!==null,'stalled HEVC schedules H264 fallback');
  for(let i=0;i<60&&(peer===original||!connected);i++)await new Promise(resolve=>setTimeout(resolve,50));
  assert(peer!==original&&connected,'fallback establishes a replacement media connection');
  assert(!hevcAttempted&&!/H265\/90000/.test(peer.localDescription.sdp),'replacement offers H264 without HEVC');
  assert(token===savedToken&&canInput(),'fallback preserves authentication and restores input');
  const offers=__requests.filter(path=>path==='offer').length;
  await new Promise(resolve=>setTimeout(resolve,1700));
  assert(__requests.filter(path=>path==='offer').length===offers,'H264 replacement does not loop reconnect');
 }finally{
  __codecFixture=null;RTCRtpReceiver.getCapabilities=capabilities;navigator.mediaCapabilities.decodingInfo=decoding;
  forceH264=savedForce;$('stream-preference').value=savedPreference;$('lossless-text').checked=savedLossless;
  await startPeer();
 }
 return {passed:results.length,results};
};
