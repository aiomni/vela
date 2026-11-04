// Isolated fixture: run after localization checks, with no real desktop input.
window.runKeyboardLayoutChecks = async ({expectSideAvailable=true}={}) => {
  if (!window.__sessionFixture) throw Error('Keyboard layout checks require the mock session');
  const $=id=>document.getElementById(id), results=[];
  const assert=(value,label)=>{if(!value)throw Error(label);results.push(label);};
  const wait=()=>new Promise(resolve=>setTimeout(resolve,350));
  const choose=layout=>document.querySelector(`[data-keyboard-layout="${layout}"]`).click();
  const docked=()=>$('desktop').classList.contains('keyboard-docked');
  const frame=element=>element.getBoundingClientRect();
  const peer=__peer, offers=__requests.filter(path=>path==='offer').length, savedText=$('text').value;
  if (!$('mouse-panel').hidden) $('mouse-panel').querySelector('[data-close-panel]').click();
  if ($('keyboard-panel').hidden) document.querySelector('[data-panel="keyboard-panel"]').click();
  await wait();
  assert($('keyboard-layout-switch').hidden===!expectSideAvailable,'layout choice is offered only when both columns fit');
  if (expectSideAvailable) {
    for (const language of ['en','zh-Hans']) {
      await VelaI18n.setLanguage(language);
      $('text').value='fixture unsent text';$('lock-text').value='fixture unsent masked text';
      choose('bottom');await wait();
      assert(!docked(),`${language}: bottom choice restores the original layout`);
      assert(frame($('screen')).bottom<=frame($('keyboard-panel')).top+1,`${language}: bottom keyboard keeps screen space above it`);
      assert(localStorage.getItem('vela.keyboardLayout')==='bottom',`${language}: bottom preference is saved`);
      assert($('text').value==='fixture unsent text'&&$('lock-text').value==='fixture unsent masked text',`${language}: layout switch preserves unfinished text`);
      document.querySelector('[data-key="MetaLeft"]').click();__inputs.length=0;
      choose('side');await wait();
      assert(docked(),`${language}: side choice docks the keyboard`);
      assert(frame($('screen')).right<=frame($('keyboard-panel')).left+1,`${language}: video and keyboard do not overlap`);
      assert(Math.abs(frame($('screen')).height-frame($('workspace')).height)<1,`${language}: side keyboard retains full video viewport height`);
      assert($('keyboard-panel').scrollWidth<=$('keyboard-panel').clientWidth+1,`${language}: side keyboard has no horizontal content overflow`);
      assert($('text').value==='fixture unsent text'&&$('lock-text').value==='fixture unsent masked text',`${language}: side switch also preserves unfinished text`);
      assert(__inputs.some(input=>input.type==='release')&&document.querySelector('[data-key="MetaLeft"]').getAttribute('aria-pressed')==='false',`${language}: layout change releases held modifiers`);
      assert(localStorage.getItem('vela.keyboardLayout')==='side',`${language}: side preference is saved`);
      $('keyboard-panel').scrollTop=$('keyboard-panel').scrollHeight;
      const heading=frame($('keyboard-panel').querySelector('.panel-heading')),panel=frame($('keyboard-panel'));
      assert(heading.top>=panel.top-1&&heading.bottom<=panel.bottom+1,`${language}: layout and close controls remain reachable while scrolling`);
      $('keyboard-panel').scrollTop=0;
    }
    const rect=frame($('surface'));$('screen').setPointerCapture=()=>{};
    for(const type of ['pointerdown','pointerup']) $('screen').dispatchEvent(new PointerEvent(type,{pointerId:91,pointerType:'touch',clientX:rect.left+rect.width/2,clientY:rect.top+rect.height/2,bubbles:true,cancelable:true}));
    assert(!$('keyboard-panel').hidden&&docked(),'touching the remote desktop keeps its side keyboard open');
    choose('bottom');await wait();
    $('keyboard-panel').querySelector('[data-close-panel]').click();
    assert($('lock-text').value==='','closing still clears unfinished masked input');
    document.querySelector('[data-panel="keyboard-panel"]').click();await wait();
    assert(!docked(),'reopening respects the bottom preference');
    choose('side');await wait();
  } else {
    assert(!docked(),'small or portrait viewport uses the bottom keyboard');
    assert(frame($('screen')).bottom<=frame($('keyboard-panel')).top+1,'fallback keyboard reserves space above itself');
  }
  __inputs.length=0;document.querySelector('[data-key="KeyA"]').click();
  assert(__inputs.filter(input=>input.type==='key'&&input.code==='KeyA').map(input=>input.action).join()==='down,up','keyboard keys still use the authenticated control channel');
  $('keyboard-panel').querySelector('[data-close-panel]').click();await wait();
  $('text').value=savedText;await VelaI18n.setLanguage('en');
  assert(__peer===peer&&__requests.filter(path=>path==='offer').length===offers,'layout switching preserves the peer and authentication');
  return {width:innerWidth,height:innerHeight,passed:results.length};
};
