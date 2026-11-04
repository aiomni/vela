// Run on the isolated fixture after localization checks, before manually opening panels.
window.runMouseSidebarChecks = async ({expectAutoDock=true}={}) => {
  if (!window.__sessionFixture) throw Error('Mouse sidebar checks require the mock session');
  const $ = id => document.getElementById(id), results = [];
  const assert = (value, label) => { if (!value) throw Error(label); results.push(label); };
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const center = element => { const rect = element.getBoundingClientRect(); return rect.left + rect.width / 2; };
  await VelaI18n.ready;
  if ($('desktop').hidden) {
    $('password').value='fixture'; $('login-form').requestSubmit();
  }
  for (let i=0; i<50 && (!window.__peer || __peer.connectionState!=='connected' || !$('video').videoWidth); i++) await wait(20);
  await wait(350);
  const peer=__peer, offers=__requests.filter(path=>path==='offer').length;
  const panel=$('mouse-panel'), button=document.querySelector('[data-panel="mouse-panel"]');
  assert($('desktop').classList.contains('mouse-docked')===expectAutoDock, 'automatic docking follows available landscape space');
  if (!expectAutoDock) {
    assert(panel.hidden, 'small or portrait view does not automatically cover the video');
    button.click(); await wait(350);
  }
  const screen=$('screen').getBoundingClientRect(), side=panel.getBoundingClientRect();
  if (expectAutoDock) assert(screen.right<=side.left && screen.height===side.height, 'sidebar and screen sit beside each other without overlap');
  assert(!panel.hidden && button.getAttribute('aria-expanded')==='true', 'toolbar reflects the visible mouse panel');
  assert(!panel.querySelector('details').open, 'gesture explanations start collapsed');
  for (const language of ['en','zh-Hans']) {
    await VelaI18n.setLanguage(language);
    for (const mode of ['direct','trackpad']) {
      panel.querySelector(`[data-touch-mode="${mode}"]`).click();
      assert($('touch-mode').value===mode && panel.querySelector(`[data-touch-mode="${mode}"]`).getAttribute('aria-pressed')==='true', `${language}: mode buttons update the existing input mode`);
    }
    assert(panel.scrollWidth<=panel.clientWidth+1, `${language}: sidebar content fits its width`);
    panel.querySelector('details').open=true;
    assert(panel.scrollWidth<=panel.clientWidth+1, `${language}: expanded gesture guide also fits`);
    panel.querySelector('details').open=false;
  }
  if (expectAutoDock) {
    const surface=$('surface').getBoundingClientRect();
    $('screen').setPointerCapture=()=>{};
    for (const type of ['pointerdown','pointerup']) $('screen').dispatchEvent(new PointerEvent(type,{pointerId:81,pointerType:'touch',clientX:surface.left+surface.width/2,clientY:surface.top+surface.height/2,bubbles:true,cancelable:true}));
    assert(!panel.hidden && $('desktop').classList.contains('mouse-docked'), 'touching the remote desktop keeps docked controls visible');
  }
  const start=center($('surface')), width=$('surface').getBoundingClientRect().width;
  $('drag-toggle').click(); __inputs.length=0;
  panel.querySelector('[data-close-panel]').click();
  assert(panel.hidden && button.getAttribute('aria-expanded')==='false', 'close button hides the sidebar and updates its toolbar button');
  assert(__inputs.some(input=>input.type==='release') && $('drag-toggle').getAttribute('aria-pressed')==='false', 'closing releases held input and dragging');
  await wait(70); const middle=center($('surface'));
  await wait(300); const end=center($('surface'));
  assert(Math.abs(end-center($('workspace')))<1, 'closing centers the remote screen');
  if (expectAutoDock) {
    assert(Math.abs($('surface').getBoundingClientRect().width-width)<1, 'docking uses spare space without shrinking the fitted video');
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) assert(middle>start+1 && middle<end-1, 'screen moves through an intermediate position during the close animation');
  }
  window.dispatchEvent(new Event('resize')); await VelaI18n.setLanguage('en'); await wait(350);
  assert(panel.hidden, 'resize and language changes respect an explicit close');
  button.click(); await wait(350);
  assert(!panel.hidden, 'toolbar can reopen the mouse panel');
  panel.querySelector('[data-close-panel]').click(); await wait(350);
  assert(__peer===peer && __requests.filter(path=>path==='offer').length===offers, 'sidebar interactions preserve the peer and authentication');
  return {width:innerWidth,height:innerHeight,passed:results.length};
};
