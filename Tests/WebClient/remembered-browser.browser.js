// Isolated fixture only. Persistent fixture flags contain no credentials.
window.runRememberedBrowserChecks=async()=>{
 const $=id=>document.getElementById(id),results=[],wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
 const assert=(value,label)=>{if(!value)throw Error(label);results.push(label);};
 if(!window.__sessionFixture)throw Error('Remembered-browser checks require the mock session');
 const connect=async()=>{$('login-form').requestSubmit();await wait(250);};
 if(!$('desktop').hidden){$('disconnect').click();await wait(50);}
 assert(!$('remember-device').checked,'remembering a browser is opt-in');
 $('remember-device').checked=true;$('password').value='fixture';await connect();
 assert(!$('desktop').hidden&&localStorage.getItem('vela.fixtureRemembered')==='1','password login can remember the browser');
 $('disconnect').click();await wait(50);
 assert($('desktop').hidden&&$('password').hidden&&!$('password').required,'disconnect ends the session while preserving browser trust');
 const logins=__requests.filter(path=>path==='login').length;
 await connect();
 assert(!$('desktop').hidden&&__requests.filter(path=>path==='login').length===logins,'reconnection uses the device credential instead of a password');
 $('disconnect').click();await wait(50);
 localStorage.removeItem('vela.fixtureRemembered');await connect();
 assert($('desktop').hidden&&!$('password').hidden&&$('password').required,'revoked or expired browser trust returns to password entry');
 $('remember-device').checked=true;$('password').value='fixture';await connect();
 $('disconnect').click();await wait(50);
 const details=document.querySelector('.login-note');details.open=true;
 await VelaI18n.setLanguage('zh-Hans');
 assert(!$('forget-device').hidden&&$('forget-device').textContent===VelaI18n.t('Forget this device'),'forget action is available and localized');
 $('forget-device').click();await wait(100);
 assert(localStorage.getItem('vela.fixtureRemembered')===null&&!$('password').hidden&&!$('remember-device').checked,'forgetting removes trust and restores password entry');
 details.open=false;await VelaI18n.setLanguage('en');
 return {passed:results.length,results};
};
