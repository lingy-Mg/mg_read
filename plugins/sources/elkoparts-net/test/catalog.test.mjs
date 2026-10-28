/** Catalog regression: lazy native pages retain the full catalog and do not silently truncate legacy results. */
import assert from 'node:assert/strict';
import test from 'node:test';
import {ElkopartsCatalog} from '../dist/catalog.js';
const chapter=id=>({id,title:id,url:null,volumeTitle:null,wordCount:null,updatedAt:null,isLocked:false,attributes:[]});

test('large catalogs expose bounded lazy groups and preserve their final chapter',async()=>{
 const calls=[];const pages=Array.from({length:130},(_,n)=>new URL(`http://www.elkoparts.net/kanshu/1/2/${n+1}.html`));
 const catalog=new ElkopartsCatalog(async url=>{calls.push(url.href);return url.pathname;},()=>pages,(html,url)=>Array.from({length:50},(_,n)=>chapter(`${url.pathname}:${n}`)));
 const initial=await catalog.load({id:'novel:1:2',supportsDeferredGroups:true},pages[0]);
 assert.equal(calls.length,2);assert.equal(initial.groups.length,65);assert.equal(initial.items.length,100);assert.ok(initial.groups.slice(1).every(group=>group.deferred));
 const last=await catalog.load({id:'novel:1:2',groupId:initial.groups.at(-1).id},pages[0]);
 assert.equal(last.items.at(-1).id,'/kanshu/1/2/130.html:49');assert.equal(last.groups.length,65);assert.equal(last.groups.at(-1).deferred,undefined);assert.equal(last.groups.at(-1).order,64);assert.equal(last.groups.at(-1).id,initial.groups.at(-1).id);assert.equal(calls.length,4);
 await assert.rejects(catalog.load({id:'novel:1:2',groupId:'unknown'},pages[0]),/unavailable/);
 await assert.rejects(catalog.load({id:'novel:1:2'},pages[0]),/requires deferred/);
});
