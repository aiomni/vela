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
