import assert from'node:assert/strict';import test from'node:test';import*as plugin from'../dist/index.mjs';test('Yelive source keeps room IDs and proxies low-latency HLS',async()=>{const proxied=[];await plugin.activate({log:{info(){},warn(){}},resource:{proxy(v){proxied.push(v);return`http://127.0.0.1/r/${proxied.length}`;}},http:{async fetch(){return Response.json({models:[{id:123,username:'tester',status:'public',isOnline:true,previewUrlThumbSmall:'https://img.example/c.jpg',hlsPlaylist:'https://edge-hls.example/hls/123/master/123_240p.m3u8',presets:['720p','480p']} ]});}}});const listing=await plugin.discover({target:'channel:girls',cursor:null,collectionId:null,pageSize:5}),item=listing.document.components[0].children[0].items[0].content;assert.equal(item.id,'live:123');const chapters=await plugin.getChapters({id:item.id});assert.equal(chapters.items[0].id,'live:123:auto');const content=await plugin.getContent({id:item.id,chapterId:chapters.items[0].id});assert.equal(content.media.resourceType,'hls');assert.equal(proxied.at(-1).url,'https://edge-hls.example/hls/123/master/123_240p.m3u8');assert.equal(proxied.at(-1).kind,'hls');});

test('live channel icons use the public discovery vocabulary', async () => {
  await plugin.activate({ log: { info() {} } });
  const result = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 10 });
  assert.equal(result.document.components[0].icon, 'video');
  assert.ok(result.document.components[0].children[0].categories.every((category) => category.icon === 'video'));
});

test('preserves published signed HLS URLs and only selects declared qualities',async()=>{
 const requests=[];await plugin.activate({log:{info(){}},resource:{proxy:r=>{requests.push(r);return r.url;}},http:{fetch:async()=>Response.json({models:[{id:456,username:'public-room',status:'public',hlsPlaylist:'https://edge-hls.example/hls/456/master/456_240p.m3u8?token=fixture',presets:['480p','240p']}]})}});
 await plugin.discover({target:'channel:girls',cursor:null,collectionId:null,pageSize:1});
 await plugin.getContent({id:'live:456',chapterId:'live:456:auto'});assert.equal(requests.at(-1).url,'https://edge-hls.example/hls/456/master/456_240p.m3u8?token=fixture');
 await plugin.getContent({id:'live:456',chapterId:'live:456:480p'});assert.equal(requests.at(-1).url,'https://edge-hls.example/hls/456/master/456_480p.m3u8?token=fixture');
 await assert.rejects(plugin.getContent({id:'live:456',chapterId:'live:456:1080p'}),/unavailable/);
});

test('lightweight search records do not erase published playback metadata',async()=>{
 const resources=[];await plugin.activate({log:{info(){}},resource:{proxy:r=>{resources.push(r);return r.url;}},http:{fetch:async input=>Response.json({models:[String(input).includes('/search/')?{id:789,username:'cached-room',status:'public'}:{id:789,username:'cached-room',status:'public',hlsPlaylist:'https://edge-hls.example/hls/789/master/789_240p.m3u8',presets:['480p','240p']}]})}});
 await plugin.discover({target:'channel:girls',cursor:null,collectionId:null,pageSize:1});await plugin.search({query:'cached-room',cursor:null,pageSize:1});
 const catalog=await plugin.getChapters({id:'live:789'});assert.equal(catalog.items.length,3);
 await plugin.getContent({id:'live:789',chapterId:'live:789:auto'});assert.equal(resources.at(-1).url,'https://edge-hls.example/hls/789/master/789_240p.m3u8');
});
