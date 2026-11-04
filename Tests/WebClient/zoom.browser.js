// Run after localization on the isolated mock server; no real desktop input is used.
window.runZoomChecks=async()=>{
 const results=[],assert=(value,label)=>{if(!value)throw Error(label);results.push(label);};
 const wait=()=>new Promise(resolve=>setTimeout(resolve,120));
 const screen=$('screen'),surface=$('surface'),savedZoom=$('zoom').value,savedPreference=$('stream-preference').value,savedLanguage=VelaI18n.language,savedViewOnly=viewOnly;
 const capture=screen.setPointerCapture;
 const choose=async value=>{$('zoom').value=value;$('zoom').dispatchEvent(new Event('change'));await wait();};
 const center=()=>{const rect=surface.getBoundingClientRect(),view=screen.getBoundingClientRect();return {x:(view.left+screen.clientWidth/2-rect.left)/rect.width,y:(view.top+screen.clientHeight/2-rect.top)/rect.height};};
 try{
  assert(connected&&token,'authenticated fixture is connected');
  if(viewOnly)$('view-only').click();
  screen.setPointerCapture=()=>{};closePanels(false);
  $('stream-preference').value='automatic';$('stream-preference').dispatchEvent(new Event('change'));await wait();
  const connection=peer,savedToken=token,offers=__requests.filter(path=>path==='offer').length;
  await choose('fit');assert(Number.isFinite(__streamFeedback.viewportWidth),'fit mode reports the window pixel budget');
  await choose('1');assert(Math.abs(surface.clientWidth*window.devicePixelRatio-$('video').videoWidth)<3,'100 percent shows one received pixel per backing pixel');
  assert(!('viewportWidth' in __streamFeedback)&&!('viewportHeight' in __streamFeedback),'detail mode removes window-only capture downscaling');
  screen.scrollLeft=100;screen.scrollTop=100;const before=center();
  await choose('4');const after=center();
  assert(Math.abs(surface.clientWidth*window.devicePixelRatio-$('video').videoWidth*4)<3,'400 percent enlarges the received image');
  assert(Math.abs(before.x-after.x)<.003&&Math.abs(before.y-after.y)<.003,'zoom preserves the inspected source position');
  $('center-view').click();await wait();
  assert(Math.abs(center().x-.5)<.002&&Math.abs(center().y-.5)<.002,'center action reaches the enlarged image center');
  const origin={x:screen.scrollLeft,y:screen.scrollTop};__inputs.length=0;
  screen.dispatchEvent(new WheelEvent('wheel',{altKey:true,deltaX:120,deltaY:80,bubbles:true,cancelable:true}));await wait();
  assert(screen.scrollLeft>origin.x+50&&screen.scrollTop>origin.y+30,'Alt or Option wheel pans the local image');
  assert(!__inputs.some(input=>['pointer','scroll','key'].includes(input.type)),'local panning does not send remote input');
  const view=screen.getBoundingClientRect(),x=view.left+100,y=view.top+100;
  const expected={x:(screen.scrollLeft+100-surface.offsetLeft)/surface.clientWidth,y:(screen.scrollTop+100-surface.offsetTop)/surface.clientHeight};
  __inputs.length=0;
  for(const type of ['pointerdown','pointerup'])screen.dispatchEvent(new PointerEvent(type,{pointerId:99,pointerType:'mouse',button:0,clientX:x,clientY:y,bubbles:true,cancelable:true}));
  const click=__inputs.find(input=>input.type==='pointer'&&input.action==='down');
  assert(click&&Math.abs(click.x-expected.x)<.001&&Math.abs(click.y-expected.y)<.001,'clicks after zoom and pan hit the correct remote position');
  __inputs.length=0;screen.dispatchEvent(new WheelEvent('wheel',{deltaY:50,clientX:x,clientY:y,bubbles:true,cancelable:true}));
  assert(__inputs.some(input=>input.type==='scroll'&&input.deltaY===50),'ordinary wheel scrolling still controls the remote computer');
  $('view-only').click();__inputs.length=0;const previous=screen.scrollLeft;
  screen.dispatchEvent(new WheelEvent('wheel',{altKey:true,deltaX:100,bubbles:true,cancelable:true}));await wait();
  assert(screen.scrollLeft>previous&&!__inputs.some(input=>['pointer','scroll','key'].includes(input.type)),'view-only permits local inspection without remote input');
  $('view-only').click();await VelaI18n.setLanguage('zh-Hans');
  assert($('zoom').value==='4'&&$('zoom').selectedOptions[0].textContent===t('400% · Zoom in'),'language switching preserves zoom and translates its controls');
  assert(peer===connection&&token===savedToken&&__requests.filter(path=>path==='offer').length===offers,'zoom and panning preserve the authenticated media session');
  await choose('fit');
  assert(screen.scrollLeft===0&&screen.scrollTop===0&&Number.isFinite(__streamFeedback.viewportWidth),'fit restores the window budget and clears panning');
 }finally{
  if(viewOnly!==savedViewOnly)$('view-only').click();
  await VelaI18n.setLanguage(savedLanguage);$('stream-preference').value=savedPreference;$('stream-preference').dispatchEvent(new Event('change'));
  await choose(savedZoom);screen.setPointerCapture=capture;release();
 }
 return {passed:results.length,results};
};
