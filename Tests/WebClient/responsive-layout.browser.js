// Run only on the isolated mock server, at each viewport under review.
window.runResponsiveLayoutChecks = async () => {
  if (!window.__sessionFixture) throw Error('Responsive checks require the mock session');
  const $ = id => document.getElementById(id), results = [];
  const assert = (value, label) => { if (!value) throw Error(`${innerWidth}px: ${label}`); results.push(label); };
  const frame = element => element.getBoundingClientRect();
  const overlaps = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
  const inside = (a, b) => a.left >= b.left - 1 && a.right <= b.right + 1 && a.top >= b.top - 1 && a.bottom <= b.bottom + 1;
  await VelaI18n.ready;
  if ($('desktop').hidden) {
    $('password').value = 'fixture'; $('login-form').requestSubmit();
    for (let i = 0; i < 50 && ($('desktop').hidden || __peer.connectionState !== 'connected'); i++) {
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  const peer = __peer, offers = __requests.filter(path => path === 'offer').length;
  const tools = document.querySelector('.tools'), actions = document.querySelector('.session-actions');
  for (const language of ['en', 'zh-Hans']) {
    await VelaI18n.setLanguage(language);
    await new Promise(requestAnimationFrame);
    assert(document.documentElement.scrollWidth <= innerWidth, `${language}: no page overflow`);
    assert(!overlaps(frame(tools), frame(actions)), `${language}: toolbar tools and actions do not overlap`);
    assert(inside(frame(actions), frame($('toolbar'))), `${language}: language and session actions fit the toolbar`);
    const languageSwitch = actions.querySelector('.language-switch');
    assert(inside(frame(languageSwitch), frame(actions)), `${language}: language switch fits session actions`);
    for (const button of languageSwitch.querySelectorAll('button')) {
      assert(button.clientWidth >= 36 && button.clientHeight >= 28, `${language}: language button retains a usable target`);
      assert(inside(frame(button), frame(languageSwitch)), `${language}: language button fits the switch`);
    }
    for (const button of tools.querySelectorAll('button')) {
      button.scrollIntoView({block: 'nearest', inline: 'nearest'});
      assert(inside(frame(button), frame(tools)), `${language}: ${button.id || button.dataset.panel} is reachable`);
      const range = document.createRange(); range.selectNodeContents(button.querySelector('span'));
      assert([...range.getClientRects()].every(rect => inside(rect, frame(button))), `${language}: toolbar label fits its button`);
    }
    tools.scrollLeft = 0;
    const state = frame($('control-state')), stats = frame($('stats'));
    assert(!overlaps(state, stats), `${language}: status text and video metrics do not overlap`);
    assert(inside(stats, frame($('statusbar'))), `${language}: video metrics remain visible`);
    for (const id of ['display-panel', 'quality-panel', 'mouse-panel', 'privacy-panel', 'keyboard-panel']) {
      const button = tools.querySelector(`[data-panel="${id}"]`);
      button.click();
      await new Promise(requestAnimationFrame);
      const panel = $(id), rect = frame(panel), workspace = frame($('workspace'));
      assert(!panel.hidden && inside(rect, workspace), `${language}: ${id} fits the workspace`);
      assert(panel.scrollWidth <= panel.clientWidth + 1, `${language}: ${id} has no horizontal content overflow`);
      if (id === 'keyboard-panel' && innerWidth <= 1100) {
        assert(frame($('screen')).bottom <= rect.top + 1, `${language}: keyboard leaves the remote screen accessible`);
      }
      panel.querySelector('[data-close-panel]').click();
    }
    $('collapse-toolbar').click();
    assert(getComputedStyle($('toolbar')).display === 'none' && !$('show-toolbar').hidden, `${language}: collapse keeps an expand control`);
    $('show-toolbar').click();
    assert(getComputedStyle($('toolbar')).display !== 'none', `${language}: toolbar expands again`);
  }
  await VelaI18n.setLanguage('en');
  assert(__peer === peer && __requests.filter(path => path === 'offer').length === offers, 'layout and language checks preserve the session');
  assert(__peer.connectionState === 'connected', 'fixture remains connected');
  return {width: innerWidth, height: innerHeight, passed: results.length};
};
