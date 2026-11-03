'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const web=path.resolve(__dirname,'../../Sources/RemoteServer/Web');
const catalog=JSON.parse(fs.readFileSync(path.join(web,'locales/zh-Hans.json'),'utf8'));
function client(saved){
 const storage=new Map(saved?[['vela.language',saved]]:[]);
 const context={localStorage:{getItem:key=>storage.get(key),setItem:(key,value)=>storage.set(key,value)},module:{exports:{}},Event:class{}};
 vm.runInNewContext(fs.readFileSync(path.join(web,'i18n.js'),'utf8'),context);
 const api=context.module.exports;api.setCatalog(catalog);return {api,storage};
}
test('English is the default and unsupported preferences fall back to English',()=>{
 assert.equal(client().api.language,'en');assert.equal(client('fr').api.language,'en');
 assert.equal(client().api.t('Connect'),'Connect');
});
test('Chinese selection persists and switching back restores English',async()=>{
 const {api,storage}=client();await api.setLanguage('zh-Hans');
 assert.equal(storage.get('vela.language'),'zh-Hans');assert.equal(api.t('Connect'),catalog.Connect);
 assert.equal(api.t('An unknown display name'),'An unknown display name');
 await api.setLanguage('en');assert.equal(api.t(catalog.Connect),'Connect');
 assert.equal(client('zh-Hans').api.language,'zh-Hans');
});
test('formatted messages localize in either direction without interpreting argument braces',async()=>{
 const {api}=client();assert.equal(api.t('Error {0}: {1}','{1}','reason'),'Error {1}: reason');
 await api.setLanguage('zh-Hans');assert.ok(api.t('Display {0}','Connect').endsWith('Connect'));const translated=api.t('Display {0}',42);
 assert.equal(api.t('Display 42'),translated);await api.setLanguage('en');assert.equal(api.t(translated),'Display 42');
});
test('web and native catalogs match, with the same placeholders and English keys',()=>{
 const native=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../Sources/VelaLocalization/Resources/zh-Hans.json'),'utf8'));
 assert.deepEqual(catalog,native);
 for(const [english,chinese] of Object.entries(catalog)){
  assert.doesNotMatch(english,/\p{Script=Han}/u);assert.ok(chinese.length);
  assert.deepEqual((english.match(/\{\d+\}/g)||[]).sort(),(chinese.match(/\{\d+\}/g)||[]).sort(),english);
 }
});
test('the HTML fallback is English and language selection is available before and after login',()=>{
 const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
 assert.match(html,/<html lang="en">/);assert.doesNotMatch(html,/\p{Script=Han}/u);
 assert.equal((html.match(/data-language/g)||[]).length,2);
 assert.ok(html.indexOf('/i18n.js')<html.indexOf('/app.js'));
});
