// Browser integration checks for the synthetic session fixture (no real desktop input).
// Load after client-core.js/app.js with __inputs populated by the mock control channel,
// then await runTouchChecks(). Synthetic pointer capture is stubbed explicitly below.
window.runTouchChecks=async()=>{
 const screen=document.getElementById('screen'),$=id=>document.getElementById(id),results=[];
 const assert=(ok,label)=>{if(!ok)throw Error(label);results.push(label);};
 const wait=ms=>new Promise(r=>setTimeout(r,ms));
 // Synthetic PointerEvents do not register active browser pointer IDs.
 screen.setPointerCapture=()=>{};
 $('password').value='fixture';$('login-form').requestSubmit();await wait(200);
 assert(!$('desktop').hidden,'fixture connected');
 const reset=()=>{$('release').click();window.__inputs.length=0;};
 const event=(type,id,x,y)=>screen.dispatchEvent(new PointerEvent(type,{pointerId:id,pointerType:'touch',clientX:x,clientY:y,bubbles:true,cancelable:true}));
 const points=()=>{const r=$('surface').getBoundingClientRect();return [0,1,2,3].map(i=>({x:r.left+Math.min(r.width*.3,100)+i*30,y:r.top+Math.min(r.height*.55,240)}));};
 const down=(ps,n=4)=>ps.slice(0,n).forEach((p,i)=>event('pointerdown',i+1,p.x,p.y));
 const move=(ps,dx,dy,n=4)=>ps.slice(0,n).forEach((p,i)=>event('pointermove',i+1,p.x+dx,p.y+dy));
 const up=ps=>ps.forEach((p,i)=>event('pointerup',i+1,p.x,p.y));
 const arrows=()=>__inputs.filter(e=>e.type==='key'&&e.action==='down'&&e.code.startsWith('Arrow'));
 for(const mode of ['trackpad','direct']){
  $('touch-mode').value=mode;$('touch-mode').dispatchEvent(new Event('change'));
  for(const [dx,dy,code] of [[-80,0,'ArrowRight'],[80,0,'ArrowLeft'],[0,-80,'ArrowUp']]){
   reset();const ps=points();down(ps);move(ps,dx,dy);move(ps,dx*2,dy*2);up(ps);await wait(20);
   assert(arrows().length===1&&arrows()[0].code===code&&arrows()[0].modifiers.join()==='control',`${mode} ${code} exactly once with control`);
   assert(!__inputs.some(e=>e.type==='scroll'||e.type==='pointer'),`${mode} ${code} no scroll, click or drag`);
   assert(__inputs.filter(e=>e.type==='key').map(e=>`${e.action}:${e.code}`).join()==='down:ControlLeft,down:'+code+',up:'+code+',up:ControlLeft',`${mode} ${code} releases keys`);
  }
 }
 for(const [dx,dy,label] of [[0,80,'down'],[30,0,'short'],[80,80,'diagonal']]){
  reset();const ps=points();down(ps);move(ps,dx,dy);up(ps);assert(!arrows().length&&!__inputs.some(e=>e.type==='pointer'||e.type==='scroll'),`${label} motion ignored`);
 }
 reset();let ps=points();down(ps);move(ps,-120,0,1);up(ps);assert(!arrows().length,'one moving finger cannot trigger four-finger action');
 reset();ps=points();down(ps,3);move(ps,-100,0,3);up(ps);assert(!arrows().length&&!__inputs.some(e=>e.type==='scroll'),'three fingers ignored');
 reset();ps=points();down(ps);event('pointerdown',5,ps[0].x+130,ps[0].y);event('pointerup',5,ps[0].x+130,ps[0].y);move(ps,-100,0);up(ps);assert(!arrows().length,'five-finger chord cannot become four-finger action');
 reset();ps=points();down(ps);event('pointerup',4,ps[3].x,ps[3].y);event('pointerdown',4,ps[3].x,ps[3].y);move(ps,-100,0);up(ps);assert(!arrows().length,'lifting and replacing a finger cannot retrigger');
 reset();ps=points();down(ps);event('pointercancel',1,ps[0].x,ps[0].y);move(ps,-100,0);up(ps);assert(!arrows().length,'cancel stops gesture');
 reset();ps=points();down(ps);window.dispatchEvent(new Event('blur'));move(ps,-100,0);up(ps);assert(!arrows().length,'blur stops gesture');
 for(const [action,code] of [['previous','ArrowLeft'],['next','ArrowRight'],['overview','ArrowUp']]){
  reset();document.querySelector(`[data-desktop-action="${action}"]`).click();assert(arrows().length===1&&arrows()[0].code===code,`${action} button sends shortcut`);
 }
 reset();$('view-only').click();__inputs.length=0;ps=points();down(ps);move(ps,-100,0);up(ps);document.querySelector('[data-desktop-action="next"]').click();assert(!__inputs.length&&[...document.querySelectorAll('[data-desktop-action]')].every(b=>b.disabled),'view-only disables gestures and buttons');$('view-only').click();
 for(const mode of ['trackpad','direct']){
  $('touch-mode').value=mode;$('touch-mode').dispatchEvent(new Event('change'));reset();ps=points();down(ps,2);await wait(140);move(ps,0,-40,2);up(ps);
  assert(__inputs.some(e=>e.type==='scroll'&&e.deltaY>0)&&!__inputs.some(e=>e.type==='pointer'||e.type==='key'),`${mode} two-finger scroll preserved`);
  reset();ps=points();down(ps,1);up(ps);assert(__inputs.filter(e=>e.type==='pointer').map(e=>e.action).join()==='down,up',`${mode} tap preserved`);
 }
 reset();ps=points();down(ps,1);move(ps,20,10,1);await wait(30);up(ps);assert(__inputs.filter(e=>e.type==='pointer'&&e.action!=='move').map(e=>e.action).join()==='down,up','direct drag preserved');
 reset();ps=points();down(ps,1);await wait(650);up(ps);assert(__inputs.filter(e=>e.type==='pointer').map(e=>`${e.action}:${e.button}`).join()==='down:2,up:2','long press right click preserved');
 reset();$('drag-toggle').click();__inputs.length=0;ps=points();down(ps);move(ps,-80,0);up(ps);assert(__inputs.some(e=>e.type==='pointer'&&e.action==='up')&&!__inputs.some(e=>e.type==='pointer'&&e.action==='down')&&arrows().length===1&&$('drag-toggle').getAttribute('aria-pressed')==='false','four fingers release active drag');
 reset();return {passed:results.length,results};
};
