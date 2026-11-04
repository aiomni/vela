/* English source strings are localization keys. Chinese lives only in the catalog. */
(function(root){
  'use strict';
  const storageKey='vela.language', supported=['en','zh-Hans'];
  let language='en', catalog={}, reverse=new Map(), patterns=[];
  try{const saved=root.localStorage?.getItem(storageKey);if(supported.includes(saved))language=saved;}catch{}
  const escape=value=>value.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const format=(template,args)=>template.replace(/\{(\d+)\}/g,(marker,index)=>index<args.length?String(args[index]):marker);
  function setCatalog(value){
    catalog=value;reverse=new Map(Object.entries(catalog).map(([key,text])=>[text,key]));patterns=[];
    for(const [english,chinese] of Object.entries(catalog)){
      for(const source of [english,chinese]){
        const slots=[];let pattern='',cursor=0;
        for(const match of source.matchAll(/\{(\d+)\}/g)){
          pattern+=escape(source.slice(cursor,match.index))+'([\\s\\S]*?)';slots.push(Number(match[1]));cursor=match.index+match[0].length;
        }
        if(slots.length)patterns.push({english,chinese,slots,expression:new RegExp('^'+pattern+escape(source.slice(cursor))+'$')});
      }
    }
    patterns.sort((a,b)=>b.english.length-a.english.length);
  }
  function t(key,...args){
    if(typeof key!=='string')return key;
    if(args.length)return format(language==='zh-Hans'?(catalog[key]??key):key,args);
    if(Object.hasOwn(catalog,key))return language==='zh-Hans'?catalog[key]:key;
    if(reverse.has(key))return language==='en'?reverse.get(key):key;
    for(const pattern of patterns){
      const match=pattern.expression.exec(key);if(!match)continue;
      const values=[];pattern.slots.forEach((slot,index)=>values[slot]=match[index+1]);
      return format(language==='en'?pattern.english:pattern.chinese,values);
    }
    return key;
  }
  function apply(scope=root.document){
    if(!scope)return;
    const walker=scope.createTreeWalker?scope.createTreeWalker(scope.documentElement,4):root.document.createTreeWalker(scope,4);
    let node;
    while((node=walker.nextNode())){
      if(node.parentElement?.closest('script,style,textarea,[data-no-i18n]'))continue;
      const value=node.nodeValue,trimmed=value.trim();
      if(trimmed)node.nodeValue=value.replace(trimmed,t(trimmed));
    }
    for(const element of scope.querySelectorAll('[title],[aria-label],[placeholder],optgroup[label]')){
      for(const attribute of ['title','aria-label','placeholder','label']){
        if(element.hasAttribute(attribute))element.setAttribute(attribute,t(element.getAttribute(attribute)));
      }
    }
    root.document.documentElement.lang=language;
    for(const button of scope.querySelectorAll('button[data-language]'))button.setAttribute('aria-pressed',String(button.dataset.language===language));
    for(const name of scope.querySelectorAll('[data-language-name]'))name.textContent=catalog.Chinese??'Chinese';
  }
  const ready=root.document?fetch('/locales/zh-Hans.json',{cache:'no-cache',credentials:'omit'})
    .then(response=>{if(!response.ok)throw new Error('Unable to load translations');return response.json();})
    .then(value=>{setCatalog(value);apply();})
    .catch(()=>{language='en';apply();}):Promise.resolve();
  async function setLanguage(value){
    await ready;language=supported.includes(value)?value:'en';
    // Do not switch sessions, reload the page, or touch password/input values.
    try{root.localStorage?.setItem(storageKey,language);}catch{}
    apply();root.dispatchEvent?.(new Event('vela-language-change'));
  }
  const api={t,apply,setLanguage,ready,get language(){return language;},setCatalog};
  root.VelaI18n=api;
  if(typeof module!=='undefined')module.exports=api;
  root.document?.addEventListener('click',event=>{
    const button=event.target.closest('button[data-language]');
    if(button)void setLanguage(button.dataset.language);
  });
})(typeof window==='undefined'?globalThis:window);
