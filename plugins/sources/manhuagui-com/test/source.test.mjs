import assert from 'node:assert/strict'; import { readFile } from 'node:fs/promises'; import test from 'node:test';
import LZString from 'lz-string'; import * as plugin from '../dist/index.mjs';
const fixture=(name)=>readFile(new URL(`fixtures/${name}`,import.meta.url),'utf8');
test('a short host page drains the upstream listing before following its next link',async()=>{
 const original=await fixture('listing.html');const card=original.match(/<li>[\s\S]*?<\/li>/u)[0];const html='<div class="cont-list"><ul id="detail">'+Array.from({length:7},(_,i)=>card.replaceAll('123',String(200+i))).join('')+'</ul></div>';
 await plugin.activate({log:{info(){},warn(){}},resource:{proxy:r=>r.url},http:{fetch:async()=>new Response(html)}});
 const first=await plugin.discover({target:'category:update',cursor:null,collectionId:null,pageSize:3}),list=first.document.components[0].children[0];
 const next=await plugin.discover({...list.continuation,collectionId:list.id,pageSize:3});const last=await plugin.discover({...next.continuation,collectionId:list.id,pageSize:3});
 assert.equal(last.items.length,1);assert.equal(last.continuation,null);assert.equal(new Set([...list.items,...next.items,...last.items].map(x=>x.content.id)).size,7);
});
test('fixture flow unpacks bounded image data and proxies cover/pages with Referer',async()=>{
  const [listing,detail]=await Promise.all([fixture('listing.html'),fixture('detail.html')]);
  const imageData={files:['001.jpg','002.webp'],host:'i.hamreus.com',path:'/fixture/',sl:{e:'1900000000',m:'fixture-signature'}};
  const code=`SMH.imgData(${JSON.stringify(imageData)}).preInit();`; const dictionary=LZString.compressToBase64('SMH|');
  const chapter=`<html><head><title>第一话_测试漫画</title></head><script>}('${code.replaceAll("'","\\'")}',62,1,'${dictionary}'['split']('|'),0,{})</script></html>`;
  const proxied=[];const logs=[];
  await plugin.activate({dataDir:'data',cacheDir:'cache',http:{async fetch(input){const u=new URL(input);if(u.hostname==='m.manhuagui.com')return new Response(listing);if(u.pathname==='/comic/123/')return new Response(detail);if(u.pathname==='/comic/123/456.html')return new Response(chapter);if(u.hostname==='i.hamreus.com'||u.hostname==='cf.mhgui.com')return new Response(Uint8Array.from([1,2]),{headers:{'content-type':'image/jpeg'}});return new Response('missing',{status:404});}},resource:{proxy(r){proxied.push(r);return`http://127.0.0.1/resource/${proxied.length}`;}},log:{debug(e){logs.push(e)},info(e){logs.push(e)},warn(e){logs.push(e)},error(e){logs.push(e)}},app:{runtimeVersion:'test',nodeVersion:process.versions.node,pluginApi:1},plugin:{id:'org.mgread.manhuagui-com',version:'0.1.0'}});
  const discovery=await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:10});const item=discovery.document.components[0].children[0].items[0].content;assert.equal(item.id,'manga:123');assert.equal(item.contentKind,'manga');
  const category=await plugin.discover({target:'category:update',cursor:null,collectionId:null,pageSize:10});assert.deepEqual(category.document.components[0].children[0].continuation,{target:'category:update',cursor:'category:update:2:0'});
  const search=await plugin.search({query:'测试',cursor:null,pageSize:10});assert.equal(search.items[0].id,'manga:123');
  const info=await plugin.getDetail({id:item.id});assert.equal(info.author,'作者甲');assert.equal(info.status,'ongoing');assert.equal(info.chapterCount,2);
  const chapters=await plugin.getChapters({id:item.id});assert.deepEqual(chapters.items.map(c=>c.id),['chapter:123:456','chapter:123:457']);
  const content=await plugin.getContent({id:item.id,chapterId:chapters.items[0].id});assert.equal(content.text,null);assert.equal(content.pages.length,2);assert.equal(content.pages[0].url,'http://127.0.0.1/resource/5');assert.equal(content.pages[0].resourcePolicy,undefined);
  const request=proxied.find(r=>r.url.includes('/fixture/001.jpg'));assert.equal(request.headers.Referer,'https://www.manhuagui.com/comic/123/456.html');assert.equal(new URL(request.url).hostname,'i.hamreus.com');
  assert.ok(logs.every(e=>/^[a-z_]+$/u.test(e)));
});
