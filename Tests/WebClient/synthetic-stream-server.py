#!/usr/bin/env python3
"""Serve the optional synthetic Swift/WebRTC browser harness on loopback only."""
import argparse,json,ssl,urllib.request
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--info',required=True,type=Path)
parser.add_argument('--port',type=int,default=18773)
args=parser.parse_args()
info=json.loads(args.info.read_text())
context=ssl.create_default_context(cafile=info['certificate'])
html='''<!doctype html><html><body><video autoplay playsinline muted></video><canvas width="1280" height="720"></canvas><script src="/lossless.js"></script><script>
window.result={frames:0,markers:0,draws:0};let polling;const expectHEVC=HEVC_MODE;const hardwareCapability=expectHEVC?navigator.mediaCapabilities.decodingInfo({type:'webrtc',video:{contentType:'video/H265;profile-id=1;tier-flag=0;level-id=156;tx-mode=SRST',width:1280,height:720,bitrate:24000000,framerate:30}}):Promise.resolve(null);
const video=document.querySelector('video'),canvas=document.querySelector('canvas'),ctx=canvas.getContext('2d');
const api=async(path,body)=>{const response=await fetch(path,body?{method:'POST',body:JSON.stringify(body),headers:{'Content-Type':'application/json'}}:{});if(!response.ok)throw Error(path+':'+response.status);return response.json();};
const receiver=new DesktopLosslessReceiver({decode:png=>createImageBitmap(new Blob([png],{type:'image/png'})),clear:()=>ctx.clearRect(0,0,1280,720),draw:(image,x,y)=>{ctx.drawImage(image,x,y);result.draws++;if(!result.complete){result.complete=true;clearInterval(polling);api('/complete',{});}}});
const pc=new RTCPeerConnection({iceServers:[],encodedInsertableStreams:true}),transceiver=pc.addTransceiver('video',{direction:'recvonly'});
const all=RTCRtpReceiver.getCapabilities('video').codecs;const codecs=all.filter(c=>c.mimeType.toLowerCase()==='video/h264'&&c.sdpFmtpLine?.includes('packetization-mode=1'));const hevc=all.filter(c=>c.mimeType.toLowerCase()==='video/h265'&&/(^|;)profile-id=1(;|$)/.test(c.sdpFmtpLine));transceiver.setCodecPreferences(expectHEVC?[...hevc,...codecs]:codecs);
const worker=new Worker('/frame-identity-worker.js');worker.onmessage=event=>{if(event.data.type==='frame'){result.markers++;receiver.receive(event.data);}else result.worker=event.data;};worker.onerror=event=>result.error=event.message;
if(typeof RTCRtpScriptTransform==='function')transceiver.receiver.transform=new RTCRtpScriptTransform(worker);else{const streams=transceiver.receiver.createEncodedStreams();worker.postMessage({type:'streams',...streams},[streams.readable,streams.writable]);}worker.postMessage({type:'enabled',enabled:true});
const enhancement=pc.createDataChannel('enhancement',{ordered:false});enhancement.onmessage=event=>receiver.receive(JSON.parse(event.data));
pc.ontrack=event=>{video.srcObject=new MediaStream([event.track]);video.play();const next=()=>video.requestVideoFrameCallback((_,metadata)=>{result.frames++;result.lastRTP=metadata.rtpTimestamp;if(expectHEVC&&result.frames>=10&&!result.complete){pc.getStats().then(async report=>{let inbound;report.forEach(s=>{if(s.type==='inbound-rtp'&&s.kind==='video')inbound=s;});const codec=inbound&&report.get(inbound.codecId);result.codec=codec?.mimeType;result.runtimeHardwareReported=inbound?.powerEfficientDecoder??null;const capability=await hardwareCapability;result.hardwareCapability=capability?.supported===true&&capability?.powerEfficient===true;result.width=metadata.width;result.height=metadata.height;if(result.codec==='video/H265'&&result.hardwareCapability&&result.runtimeHardwareReported!==false){result.complete=true;clearInterval(polling);api('/complete',{});}});}receiver.present(metadata.rtpTimestamp,metadata.width,metadata.height);next();});next();};
pc.onicecandidate=event=>{if(event.candidate)api('/candidate',event.candidate.toJSON()).catch(e=>result.error=String(e));};
(async()=>{await pc.setLocalDescription(await pc.createOffer());const answer=await api('/offer',{sdp:pc.localDescription.sdp});await pc.setRemoteDescription({type:'answer',sdp:answer.sdp});let offset=0;polling=setInterval(async()=>{try{const all=await api('/candidates');for(const c of all.slice(offset))await pc.addIceCandidate(c);offset=all.length;if(result.complete)clearInterval(polling);}catch(e){if(!result.complete)result.error=String(e);}},200);})().catch(e=>result.error=String(e));
</script></body></html>'''
html=html.replace('HEVC_MODE','true' if info.get('hevc') else 'false').replace('1280',str(info.get('width',1280))).replace('720',str(info.get('height',720)))
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def handle_request(self):
  if self.path=='/':
   data=html.encode();self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(data);return
  data=self.rfile.read(int(self.headers.get('Content-Length','0'))) if self.command=='POST' else None
  request=urllib.request.Request(f"https://127.0.0.1:{info['port']}{self.path}",data=data,method=self.command,headers={'Content-Type':'application/json'})
  try:
   with urllib.request.urlopen(request,context=context,timeout=5) as response:
    self.send_response(response.status);self.send_header('Content-Type',response.headers.get('Content-Type','application/json'));self.end_headers();self.wfile.write(response.read())
  except Exception:
   self.send_error(502)
 def do_GET(self):self.handle_request()
 def do_POST(self):self.handle_request()
print(f'Synthetic browser harness: http://127.0.0.1:{args.port}',flush=True)
ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
