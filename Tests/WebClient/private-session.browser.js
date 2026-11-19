// Current behavior: physical-display blackout, no user-session switching.
// Run with the mock-session fixture; no real display or input is changed.
window.runPrivateSessionChecks=async()=>{
 const $=id=>document.getElementById(id),results=[],wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
 const assert=(condition,label)=>{if(!condition)throw Error(label);results.push(label);};
 if($('desktop').hidden){$('password').value='fixture';$('login-form').requestSubmit();await wait(400);}
 const offers=__requests.filter(path=>path==='offer').length;
 assert(!document.getElementById('session-password'),'blackout does not ask for Mac password or switch accounts');
 assert(document.querySelector('[data-panel="privacy-panel"] span').textContent==='Physical displays','toolbar clearly names physical displays');
 __sessionFixture={state:'local',recovering:false,requiresAccountVerification:false,canEnterPrivacy:false,canManageVirtualDisplay:true,localWakePermission:true};await wait(1700);
 assert($('begin-privacy').disabled,'requires selected virtual display before blackout');
 __sessionFixture.canEnterPrivacy=true;__sessionFixture.localWakePermission=false;await wait(1700);
 assert($('begin-privacy').disabled&&$('privacy-status').textContent.includes('Input Monitoring'),'requires local wake listener permission');
 __sessionFixture.localWakePermission=true;await wait(1700);
 assert(!$('begin-privacy').disabled,'ready virtual display enables blackout');
 $('privacy-form').requestSubmit();await wait(1700);
 assert(__blackoutAttempts===1,'blackout uses the new display endpoint');
 assert($('control-state').textContent.includes('Virtual display only'),'blackout indicates virtual-only control');
 assert(!$('left-click').disabled,'remote input remains enabled during blackout');
 assert($('create-virtual').disabled&&$('remove-virtual').disabled&&$('display').disabled,'display mutations disabled until physical displays restored');
 assert(!$('restore-physical').hidden,'physical restore action stays available');
 $('restore-physical').click();await wait(1700);
 assert(__restoreRequests===1&&$('restore-physical').hidden,'remote restore exits blackout');
 assert(!$('create-virtual').disabled&&!$('display').disabled,'restore unlocks display controls');
 __sessionFixture={state:'blackout',companionBlackout:true,displaySleepRequested:true,recovering:true,
  requiresAccountVerification:false,canEnterPrivacy:false,canManageVirtualDisplay:false,localWakePermission:true};await wait(1700);
 assert($('display').disabled&&$('screen-overlay').hidden===false,'companion blackout masks video during display replacement');
 __sessionFixture.recovering=false;await wait(1700);
 assert(!$('display').disabled&&!$('quality').disabled&&$('create-virtual').disabled,'companion blackout allows display selection without editing the virtual layout');
 assert($('restore-physical').hidden&&$('privacy-status').textContent.includes('host Mac'),'companion blackout uses local input for restoration');
 __sessionFixture={state:'locked',recovering:true,requiresAccountVerification:false,lockScreenControl:false,canEnterPrivacy:false,canManageVirtualDisplay:false,localWakePermission:true};await wait(1700);
 assert($('connection').textContent==='Connected','ordinary lock preserves connection');
 assert(__requests.filter(path=>path==='offer').length===offers,'ordinary lock does not loop reconnect');
 assert(!$('screen-overlay').hidden&&$('overlay-title').textContent==='Connecting to the system lock screen','transition masks old video until new lock-screen frame');
 assert($('left-click').disabled&&$('begin-privacy').disabled,'transition blocks input and blackout entry');
 __sessionFixture.recovering=false;__sessionFixture.lockScreenControl=true;await wait(1700);
 assert($('screen-overlay').hidden&&!$('left-click').disabled,'ready system lock screen permits authenticated remote input');
 assert($('control-state').textContent.includes('Password entry available'),'state clearly offers system password entry');
 assert($('create-virtual').disabled&&$('begin-privacy').disabled,'locked console cannot mutate virtual screens or enter blackout');
 assert($('text').hidden&&!$('lock-text').hidden&&$('lock-text').type==='password','lock text entry is masked instead of plaintext');
 $('lock-text').value='fixture-only';$('text-form').requestSubmit();
 assert(__inputs.some(e=>e.type==='text'&&e.text==='fixture-only')&&$('lock-text').value==='','masked text uses input channel and clears immediately');
 $('lock-text').value='fixture-clear';document.querySelector('#keyboard-panel [data-close-panel]').click();
 assert($('lock-text').value==='','closing keyboard clears unsent lock text');
 $('lock-text').value='fixture-clear';window.dispatchEvent(new Event('blur'));
 assert($('lock-text').value==='','leaving browser clears unsent lock text');
 __sessionFixture={state:'detached',recovering:false,requiresAccountVerification:true,lockScreenControl:false,canEnterPrivacy:false,canManageVirtualDisplay:false};await wait(1700);
 assert(!$('screen-overlay').hidden&&$('left-click').disabled,'a different console user remains protected');
 __sessionFixture={state:'local',recovering:false,requiresAccountVerification:false,canEnterPrivacy:true,canManageVirtualDisplay:true,localWakePermission:true};await wait(1700);
 assert($('screen-overlay').hidden&&!$('left-click').disabled&&$('lock-text').hidden,'unlock restores normal desktop controls');
 const privateSession={state:'locked',automaticPrivacy:true,displaySleepRequested:true,lockScreenControl:true,
  recovering:false,requiresAccountVerification:false,canEnterPrivacy:false,canManageVirtualDisplay:false,localWakePermission:true};
 __sessionFixture={...privateSession};await wait(1700);
 assert($('control-state').textContent.includes('Private lock screen'),'automatic privacy identifies the real virtual lock screen');
 assert(!$('restore-physical').hidden&&$('show-physical').hidden&&$('display').disabled,'locked privacy offers safe restore and blocks display changes');
 assert(!$('left-click').disabled&&!$('lock-text').hidden,'locked privacy accepts remote input and keeps password helper masked');
 __sessionFixture={...privateSession,state:'blackout',lockScreenControl:false};await wait(1700);
 assert(!$('restore-physical').hidden&&!$('show-physical').hidden,'unlocked privacy offers both restore actions');
 const previousConfirm=window.confirm;
 try{
  window.confirm=()=>false;$('show-physical').click();await wait(50);
  assert(__restoreRequests===1,'declining visibility confirmation leaves privacy active');
  $('restore-physical').click();await wait(1700);
  assert(__restorePayloads.at(-1).showDesktop===false&&$('restore-physical').hidden&&!$('lock-text').hidden,'default restore leaves the Mac locked');
  __sessionFixture={...privateSession,state:'blackout',lockScreenControl:false};await wait(1700);
  window.confirm=()=>true;$('show-physical').click();await wait(1700);
  assert(__restorePayloads.at(-1).showDesktop===true&&$('restore-physical').hidden,'explicit confirmed restore can show the desktop');
 }finally{window.confirm=previousConfirm;}
 assert(__requests.filter(path=>path==='offer').length===offers,'private lock and restore stay on the same media connection');
 return {passed:results.length,results};
};
