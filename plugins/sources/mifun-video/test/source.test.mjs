import assert from'node:assert/strict';import test from'node:test';import*as plugin from'../dist/index.mjs';const list=`<html>MiFun<ul><li class="hl-list-item"><a href="/voddetail/12/" title="测试动漫"><img data-original="https://img.example/c.jpg"></a><p class="hl-item-sub hl-text-muted hl-hidden-xs">导演&nbsp;/&nbsp;主演&nbsp;/&nbsp;</p><p class="hl-item-sub hl-text-muted hl-lc-2">简介</p><span class="remarks">更新</span></li></ul><a href="/vodtype/1-2/">下一頁</a></html>`,detail=`<html>MiFun<h1>测试动漫</h1><ul class="hl-plays-list"><a href="/vodplay/12-1-1/">第一集</a></ul></html>`,play=`<html>MiFun<script>var player_aaaa = {"url":"https://media.example/1.m3u8"};</script></html>`;test('MiFun source maps stable paths and proxies HLS',async()=>{const proxied=[],requested=[];await plugin.activate({log:{info(){},warn(){}},resource:{proxy(v){proxied.push(v);return`http://127.0.0.1/r/${proxied.length}`;}},http:{async fetch(input){const url=String(input);requested.push(url);if(url.includes('/voddetail/'))return new Response(detail);if(url.includes('/vodplay/'))return new Response(play);return new Response(list);}}});const listing=await plugin.discover({target:'channel:0',cursor:null,collectionId:null,pageSize:1}),collection=listing.document.components[0].children[0],item=collection.items[0].content;assert.equal(collection.continuation,null);const category=await plugin.discover({target:'channel:1',cursor:null,collectionId:null,pageSize:1});assert.deepEqual(category.document.components[0].children[0].continuation,{target:'channel:1',cursor:'channel:1:2'});await plugin.discover({target:'channel:1',cursor:'channel:1:2',collectionId:'mifun:1',pageSize:1});assert.ok(requested.some(url=>url.endsWith('/vodtype/1-2/')));assert.equal(item.id,'video:12');assert.equal(item.author,'导演 / 主演 /');const chapters=await plugin.getChapters({id:item.id});assert.equal(chapters.items[0].id,'video:12:1:1');const content=await plugin.getContent({id:item.id,chapterId:chapters.items[0].id});assert.equal(content.media.resourceType,'hls');assert.equal(proxied.at(-1).url,'https://media.example/1.m3u8');});
test('detail titles respect the public label limit',async()=>{
 const longTitle='动漫'.repeat(200),longRemark='更新'.repeat(200);
 await plugin.activate({log:{info(){},warn(){}},resource:{proxy:value=>value.url},http:{async fetch(input){const url=String(input);return new Response(url.endsWith('/voddetail/99/')?`<html>MiFun<h1>${longTitle}</h1><span class="hl-content-text">${longRemark}</span></html>`:list);}}});
 const result=await plugin.getDetail({id:'video:99'});
 assert.equal(result.title.length,256);
 assert.equal(result.title,'动漫'.repeat(128));
 assert.equal(result.latestChapter.title.length,256);
 assert.equal(result.description,longRemark);
});

test('chapter order is local and contiguous inside each playback line',async()=>{
 const detail=`<html>MiFun<ul><li data-href="/vodplay/99-1-1/"><span>线路一</span></li><li data-href="/vodplay/99-2-1/"><span>线路二</span></li><a href="/vodplay/99-1-1/">一-1</a><a href="/vodplay/99-1-2/">一-2</a><a href="/vodplay/99-2-1/">二-1</a><a href="/vodplay/99-2-2/">二-2</a></ul></html>`;
 await plugin.activate({log:{info(){},warn(){}},resource:{proxy:value=>value.url},http:{async fetch(input){return new Response(String(input).endsWith('/voddetail/99/')?detail:list);}}});
 const result=await plugin.getChapters({id:'video:99'});
 assert.deepEqual(result.items.map(item=>item.order),[0,1,2,3]);
 assert.deepEqual(result.groups.map(group=>group.episodes.map(item=>item.order)),[[0,1],[0,1]]);
});

test('preserves escaped Unicode inside double-escaped player JSON',async()=>{
 const escapedPlay=String.raw`<html>MiFun<script>var player_aaaa={\"url\":\"https://media.example/escaped.m3u8\",\"vod_data\":{\"vod_name\":\"\\u65e0\\u4e0a\\u795e\\u5e1d\"}};<\/script></html>`;
 await plugin.activate({log:{info(){},warn(){}},resource:{proxy:value=>value.url},http:{async fetch(input){return new Response(String(input).includes('/vodplay/')?escapedPlay:detail);}}});
 const result=await plugin.getContent({id:'video:99',chapterId:'video:99:1:1'});
 assert.equal(result.media.resourceType,'hls');
 assert.equal(result.media.url,'https://media.example/escaped.m3u8');
});
