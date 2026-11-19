// Request/response fixture only: never creates a real display or injects input.
window.runVirtualPresetChecks = async () => {
  if (!window.__sessionFixture) throw Error('Virtual preset checks require the mock server');
  const $ = id => document.getElementById(id), results = [];
  const assert = (value, label) => { if (!value) throw Error(label); results.push(label); };
  const wait = () => new Promise(resolve => setTimeout(resolve, 10));
  await VelaI18n.ready;
  if ($('desktop').hidden) {
    $('password').value = 'fixture'; $('login-form').requestSubmit();
  }
  for (let i = 0; i < 100 && ($('desktop').hidden || $('create-virtual').disabled); i++) await wait();
  const peer = __peer, offers = __requests.filter(path => path === 'offer').length;
  const preset = $('virtual-preset'), hiDPI = $('virtual-hidpi');
  const options = [...preset.options].filter(option => /^\d+,\d+$/.test(option.value));
  assert(options.length === 18, '18 presets are available');
  assert(options.filter(option => { const [w,h] = option.value.split(',').map(Number); return h>w; }).length === 13, '13 presets are portrait');
  const select = value => { preset.value = value; preset.dispatchEvent(new Event('change')); };
  async function create(expected) {
    const before = __virtualRequests.length;
    $('create-virtual').click();
    for (let i = 0; i < 100 && ($('create-virtual').disabled || __virtualRequests.length === before); i++) await wait();
    assert(__virtualRequests.length === before + 1, 'preset creates exactly one virtual display request');
    assert(JSON.stringify(__virtualRequests.at(-1)) === JSON.stringify(expected), 'request preserves pixel dimensions and HiDPI');
  }
  for (const language of ['en','zh-Hans']) {
    await VelaI18n.setLanguage(language);
    const groups = [...preset.querySelectorAll('optgroup')];
    assert(groups[0].label === VelaI18n.t('Phone · Portrait'), `${language}: phone group is localized`);
    assert(groups[1].label === VelaI18n.t('Tablet · Portrait'), `${language}: tablet group is localized`);
    for (const scaled of [true,false]) {
      hiDPI.checked = scaled; hiDPI.dispatchEvent(new Event('change'));
      const before = __virtualRequests.length; select('1080,2400');
      assert(__virtualRequests.length === before, 'selection does not create a display automatically');
      assert($('virtual-summary').textContent === VelaI18n.t('Desktop {0} × {1}, output {2} × {3} pixels.',1080/(scaled?2:1),2400/(scaled?2:1),1080,2400), `${language}: portrait summary shows logical and physical dimensions`);
      await create({width:1080,height:2400,hiDPI:scaled});
    }
  }
  await VelaI18n.setLanguage('en');
  for (const option of options) {
    const [width,height] = option.value.split(',').map(Number);
    for (const scaled of [true,false]) {
      hiDPI.checked = scaled; select(option.value);
      assert(Number($('virtual-width').value) === width && Number($('virtual-height').value) === height, 'selection updates dimension fields');
      await create({width,height,hiDPI:scaled});
    }
  }
  const before = __virtualRequests.length;
  hiDPI.checked = true; $('virtual-width').value = '958'; $('virtual-height').value = '1280';
  $('virtual-width').dispatchEvent(new Event('input')); $('create-virtual').click(); await wait();
  assert(preset.value === 'custom' && __virtualRequests.length === before, 'undersized custom HiDPI is rejected before the API call');
  assert(!$('message').hidden && $('message').textContent.includes('960×1280'), 'validation explains the portrait HiDPI minimum');
  select('1080,2400');
  assert(__peer === peer && __requests.filter(path => path === 'offer').length === offers, 'presets and language changes preserve the existing peer');
  return {passed:results.length,presets:options.length,requests:__virtualRequests.length};
};

window.runDisplayOverviewChecks = async () => {
  const $ = id => document.getElementById(id), results = [];
  const assert = (value, label) => { if (!value) throw Error(label); results.push(label); };
  const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
  const until = async (condition, label) => {
    for (let i = 0; i < 125 && !condition(); i++) await wait(25);
    assert(condition(), label);
  };
  const card = id => document.querySelector(`#display-grid [data-display-id="${id}"]`);
  const toggle = document.querySelector('[data-panel="display-panel"]');
  const savedSession = __sessionFixture;
  const canvas = document.createElement('canvas');
  const fixture = { physical: [
    {id:1,name:'Main Display',width:2560,height:1600},
    {id:2,name:'External Display',width:1920,height:1080}
  ], virtual:false, selected:1, previews:[], jpeg:canvas.toDataURL('image/jpeg').split(',')[1] };
  __displayOverviewFixture = fixture;
  try {
    if ($('desktop').hidden) { $('password').value = 'fixture'; $('login-form').requestSubmit(); }
    await until(() => !$('desktop').hidden && $('display').options.length === 2, 'poll lists both physical displays');
    assert(fixture.previews.length === 0, 'closed overview requests no thumbnails');
    const offers = __requests.filter(path => path === 'offer').length;
    toggle.click();
    await until(() => card(1)?.querySelector('img').getAttribute('src') && card(2)?.querySelector('img').getAttribute('src'),
      'both displays receive previews in the overview');
    assert(fixture.previews.every(request => request.displayID === 2 && request.mediaID === 'fixture-media'),
      'only the other display requests an authenticated preview');
    assert(card(1).getAttribute('aria-pressed') === 'true' && !canInput(), 'active display is marked and remote input pauses');
    for (const language of ['zh-Hans','en']) {
      await VelaI18n.setLanguage(language);
      assert(card(2).textContent.includes(VelaI18n.t('Physical display · {0}','1920 × 1080')) &&
        $('display-panel').scrollWidth <= $('display-panel').clientWidth + 1, `${language}: the populated grid fits and localizes`);
    }
    card(2).click();
    await until(() => $('display-panel').hidden && $('display').value === '2' && canInput(), 'selecting a card switches and returns to remote control');
    toggle.click();
    $('virtual-options-toggle').click();
    assert(!$('virtual-controls').hidden, 'add action opens the resolution editor');
    $('create-virtual').click();
    await until(() => card(3)?.getAttribute('aria-pressed') === 'true' && !$('remove-virtual').disabled, 'new virtual display is added and selected');
    $('remove-virtual').click();
    await until(() => !card(3) && $('display').value === '1', 'remove closes the virtual display and returns to a physical display');
    await until(() => card(2)?.querySelector('img').getAttribute('src'), 'preview resumes after topology changes');
    __sessionFixture = {...savedSession,state:'locked',lockScreenControl:true,canManageVirtualDisplay:false};
    await until(() => [...$('display-grid').querySelectorAll('img')].every(image => !image.hasAttribute('src')),
      'locking clears thumbnails from the overview');
    const lockedCount = fixture.previews.length;
    await wait(1100);
    assert(fixture.previews.length === lockedCount && $('virtual-options-toggle').disabled, 'locked overview neither captures nor mutates displays');
    __sessionFixture = savedSession;
    await until(() => fixture.previews.length > lockedCount, 'unlock resumes thumbnails while the overview is open');
    toggle.click();
    const closedCount = fixture.previews.length;
    await wait(1100);
    assert(fixture.previews.length === closedCount && !$('display-grid').querySelector('img[src]'),
      'closing stops requests and discards thumbnail images');
    fixture.deferNextPreview = true;
    toggle.click();
    await until(() => fixture.finishPreview, 'test holds an in-flight thumbnail request');
    toggle.click();
    fixture.finishPreview();
    await wait(100);
    assert(!$('display-grid').querySelector('img[src]'), 'a late thumbnail cannot reappear after closing');
    assert(__requests.filter(path => path === 'offer').length === offers, 'overview and virtual display operations preserve the media peer');
  } finally {
    fixture.finishPreview?.();
    __sessionFixture = savedSession;
    __displayOverviewFixture = null;
    if (!$('display-panel').hidden) toggle.click();
  }
  return {passed:results.length,results};
};
