import assert from'node:assert/strict';import test from'node:test';import*as plugin from'../dist/index.mjs';test('Manwa native API and HTML produce decrypting manga resource descriptors',async()=>{const resources=[],detail='<h1 class="comic-title" data-original-title="测试漫画"></h1><img class="comic-cover" src="/cover.jpg"><div id="author-container">作者：作者</div><div class="comic-desc">简介</div><div id="chapter-grid-container"><a class="chapter-item" href="/comic/123/456_2" data-title="第一话"></a></div>';await plugin.activate({log:{info(){},warn(){}},resource:{proxy(v){resources.push(v);return`http://127.0.0.1/resource/${resources.length}`;}},http:{async fetch(input){const url=String(input);if(url.includes('/api/search'))return Response.json({data:{list:[{id:123,title:'测试漫画',author:'作者',cover:'/cover.jpg'}],total:1}});if(url.includes('/api/comic/image/'))return Response.json({data:{images:[{url:'https://img.example/1.jpg'}]}});if(url.includes('/comic/123'))return new Response(detail);return Response.json({data:{comicList:[]}});}}});const result=await plugin.search({query:'测试',cursor:null,pageSize:5});assert.equal(result.items[0].id,'manga:123');const chapters=await plugin.getChapters({id:result.items[0].id});assert.ok(!chapters.items[0].id.includes('/comic/'));const content=await plugin.getContent({id:result.items[0].id,chapterId:chapters.items[0].id});assert.equal(content.pages.length,1);const cover=resources.find(v=>v.url==='https://manwamu.cc/cover.jpg'),page=resources.find(v=>v.url==='https://img.example/1.jpg');for(const resource of[cover,page]){assert.equal(resource.kind,'image');assert.equal(resource.resourceTransform,'aes-cbc-prefixed-iv-image-v1');assert.equal(resource.resourceTransformKey,'0B6666A0-BB59-1381-B746-a0E4C9AC');assert.equal(resource.headers.Accept,'image/*');}assert.equal(page.headers.Referer,'https://manwamu.cc/comic/123');});
test('site navigation retains Korean categories and drains every rendered card',async()=>{
 const html='<a href="/cate/manhwa">韩漫</a><a href="/rank/">排行</a>'+Array.from({length:8},(_,i)=>`<a href="/comic/${100+i}"><div class="thumbnail"><div class="thumb_img" data-src="https://img.example/${i}.jpg"></div></div><div class="title">Comic ${i}</div><div class="badge"><span>韩漫</span></div></a>`).join('');
 await plugin.activate({log:{info(){}},resource:{proxy:r=>r.url},http:{fetch:async input=>String(input).includes('/api/home')?Response.json({data:{comicList:[]}}):new Response(html)}});
 const root=await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:3});
 const nav=root.document.components.find(x=>x.id==='manwa-site-navigation');assert.equal(nav.children[0].categories[0].target,'browse:/cate/manhwa');
 const child=await plugin.discover({target:'browse:/cate/manhwa',cursor:null,collectionId:null,pageSize:3}),list=child.document.components[0].children[0];
 const append=await plugin.discover({...list.continuation,collectionId:list.id,pageSize:20});assert.equal(append.items.length,5);assert.equal(append.continuation,null);
 assert.equal(new Set([...list.items,...append.items].map(x=>x.content.id)).size,8);
 await assert.rejects(plugin.discover({target:'browse:https://bad.example',cursor:null,collectionId:null,pageSize:2}));
});

test('fixed six-item upstream pages use returned pageSize and total',async()=>{
 const calls=[];await plugin.activate({log:{info(){}},resource:{proxy:r=>r.url},http:{fetch:async input=>{const page=Number(new URL(input).searchParams.get('page'));calls.push(page);return Response.json({data:{comicList:Array.from({length:6},(_,i)=>({id:page*10+i,title:'Comic '+i})),page,pageSize:6,total:12}});}}});
 const first=await plugin.discover({target:'category:latest',cursor:null,collectionId:null,pageSize:4});const list=first.document.components[0].children[0];
 const tail=await plugin.discover({...list.continuation,collectionId:list.id,pageSize:4});assert.equal(tail.items.length,2);
 const second=await plugin.discover({...tail.continuation,collectionId:list.id,pageSize:20});assert.equal(second.items.length,6);assert.equal(second.continuation,null);assert.deepEqual(calls,[1,1,2]);
});
test('client-rendered rankings use a bounded WebView and release it',async()=>{
 let closed=0;const selected=[];await plugin.activate({log:{info(){}},resource:{proxy:r=>r.url},webview:{open:async()=>({navigate:async()=>{},waitForText:async()=>{},executeJavaScript:async code=>{selected.push(code);return true;},getHtml:async()=>'<a class="main" href="/comic/900"><div class="title">Ranked</div><div class="thumb_img" data-src="https://img.example/900.jpg"></div></a>',close:async()=>{closed++;}})}});
 const result=await plugin.discover({target:'rank:1',cursor:null,collectionId:null,pageSize:10});assert.equal(result.document.components[0].title,'完结榜');assert.equal(result.document.components[0].children[0].items[0].rank,1);assert.equal(closed,1);assert.ok(selected[0].includes('data-sort="1"'));
});
test('adjacent API page overlap and duplicate tags do not duplicate discovery entries',async()=>{
 await plugin.activate({log:{info(){}},resource:{proxy:r=>r.url},http:{fetch:async input=>{const page=Number(new URL(input).searchParams.get('page'));return Response.json({data:{comicList:Array.from({length:6},(_,i)=>({id:(page===1?10:15)+i,title:'Comic '+i,tags:['题材','题材']})),page,pageSize:6,total:12}});}}});
 const root=await plugin.discover({target:'category:latest',cursor:null,collectionId:null,pageSize:20}),list=root.document.components[0].children[0];
 const tail=await plugin.discover({...list.continuation,collectionId:list.id,pageSize:20});
 assert.equal(tail.items.length,5);assert.equal(tail.continuation,null);assert.deepEqual(list.items[0].content.tags,['题材']);
 assert.equal(new Set([...list.items,...tail.items].map(x=>x.content.id)).size,11);
});
