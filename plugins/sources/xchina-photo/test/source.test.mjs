/** Current SSR fixtures use neutral sample text; tests preserve legacy IDs and real chapter semantics. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
const photo = '/photo/abcdef123', novel = '/fiction/123abcdef', short = '/fiction/456abcdef', video = '/video/789abcdef';
const id = (kind, path) => `${kind}:${Buffer.from(path).toString('base64url')}`;
const photoId = id('manga','/photo/id-abcdef123.html');
const card = (path, title) => `<a class="group block" href="${path}"><img src="https://img.xchina.io/photos/abcdef123/00009_600x0.webp"><span class="mt-2 text-sm">${title}</span></a>`;
const body = '<article class="reader"><header><h1>正文标题</h1></header><div class="mb-6">页面元数据</div><div class="space-y-5 font-serif"><p>第一段。</p><p>第二段。<br>换行。</p></div></article>';
const catalog = `<main><h1>长篇样本</h1><a class="btn-primary" href="${novel}/1">开始阅读</a><a class="flex py-3" href="${novel}/1">第一章</a><a class="flex py-3" href="${novel}/2">第二章</a><a href="/fiction-tag/sample">标签</a></main>`;
const album = `<main><h1>套图样本</h1><img src="https://img.xchina.io/photos/abcdef123/00003_600x0.webp"><img src="https://upload.xchina.io/media/ad.webp"><img src="https://img.xchina.io/photos/abcdef123/00009_600x0.webp"></main>`;
function activate(pages) {
  const requests=[], resources=[];
  plugin.activate({log:{info(){}},http:{async fetch(input){const u=new URL(input),path=u.pathname+u.search;requests.push(path);assert.ok(pages[path]!==undefined,`Unexpected ${path}`);return new Response(pages[path]);}},resource:{proxy(d){resources.push(d);return `http://127.0.0.1/r/${resources.length}`;}}});
  return {requests,resources};
}
test('current photo routes preserve old album/chapter IDs and published images without filename guessing',async()=>{
  const {resources,requests}=activate({'/photos':`<main>${card(photo,'套图样本')}${card('/photo/987abc','另一个样本')}<a href="/photos/2">2</a></main>`,[photo]:album});
  const r=await plugin.discover({target:'channel:latest',cursor:null,collectionId:null,pageSize:1});
  const c=r.document.components[0].children[0]; assert.equal(c.items[0].content.id,photoId);
  assert.ok(c.continuation);const more=await plugin.discover({...c.continuation,collectionId:c.id,pageSize:1});assert.equal(more.items.length,1);
  const chapters=await plugin.getChapters({id:photoId}); assert.equal(chapters.items[0].id,photoId+':main');
  const content=await plugin.getContent({id:photoId,chapterId:chapters.items[0].id});assert.equal(content.pages.length,2);
  assert.deepEqual(resources.slice(-2).map(x=>x.url),['https://img.xchina.io/photos/abcdef123/00003_600x0.webp','https://img.xchina.io/photos/abcdef123/00009_600x0.webp']);
  assert.ok(requests.includes(photo));assert.ok(!requests.some(x=>x.includes('id-')));
});
test('short fiction without a catalog has one stable full-text chapter excluding page metadata',async()=>{
  activate({[short]:`<main><h1>短篇样本</h1>${body}</main>`});const contentId=id('novel',short);
  const a=await plugin.getChapters({id:contentId}),b=await plugin.getChapters({id:contentId});assert.equal(a.items.length,1);assert.equal(a.items[0].title,'全文');assert.equal(a.items[0].id,b.items[0].id);
  const detail=await plugin.getDetail({id:contentId});assert.equal(detail.chapterCount,1);
  const c=await plugin.getContent({id:contentId,chapterId:a.items[0].id});assert.equal(c.contentKind,'novel');assert.equal(c.text,'第一段。\n\n第二段。\n\n换行。');assert.ok(!c.text.includes('元数据'));
});
test('long fiction uses real ordered chapter paths, excludes start/tag links and validates membership',async()=>{
  activate({[novel]:catalog,[novel+'/1']:`<main>${body}</main>`});const contentId=id('novel',novel);
  const c=await plugin.getChapters({id:contentId});assert.deepEqual(c.items.map(x=>[x.title,x.order,x.url.split('/').at(-1)]),[['第一章',0,'1'],['第二章',1,'2']]);
  assert.equal((await plugin.getContent({id:contentId,chapterId:c.items[0].id})).contentKind,'novel');
  await assert.rejects(plugin.getContent({id:contentId,chapterId:id('novel',short)+':main'}),/invalid/);
});
test('missing fiction catalog and body is an explicit failure, not a fabricated short story',async()=>{
  activate({[short]:'<main><h1>无正文</h1></main>'});await assert.rejects(plugin.getChapters({id:id('novel',short)}),/unavailable/);
});
test('mixed search traverses published type links and real next-page links',async()=>{
  const paths={'/search?q=sample':`<main><a href="/search?q=sample&type=photo">photo</a><a href="/search?q=sample&type=video">video</a><a href="/search?q=sample&type=fiction">fiction</a></main>`,'/search?q=sample&type=photo':`<main>${card(photo,'套图')}</main>`,'/search?q=sample&type=video':`<main>${card(video,'视频')}</main>`,'/search?q=sample&type=fiction':`<main>${card(novel,'小说')}<a href="/search?q=sample&type=fiction&page=2">2</a></main>`,'/search?q=sample&type=fiction&page=2':`<main>${card(short,'短篇')}</main>`};activate(paths);
  let cursor=null;const kinds=[];do{const r=await plugin.search({query:'sample',cursor,pageSize:3});kinds.push(...r.items.map(x=>x.contentKind));cursor=r.nextCursor;}while(cursor);assert.deepEqual(kinds,['manga','video','novel','novel']);
});
test('video uses the published HLS source and correct proxy resource kind',async()=>{
  const {resources}=activate({[video]:`<main><h1>视频样本</h1><div id="video-player" data-src="/hls/789abcdef/master.m3u8"></div></main>`});const contentId=id('video',video);
  const c=await plugin.getContent({id:contentId,chapterId:contentId+':main'});assert.equal(c.media.resourceType,'hls');assert.equal(resources[0].kind,'hls');assert.equal(resources[0].url,'https://xchina001.ink/hls/789abcdef/master.m3u8');
});

 test('published long-chapter gate uses the host WebView without treating the catalog as chapter text',async()=>{
  let url;const contentId=id('novel',novel);const pages={[novel]:catalog,[novel+'/1']:`<main><a class="btn-primary" href="${novel}/1">点这里继续看你要的页面</a></main>`};
  await plugin.activate({log:{info(){}},http:{async fetch(input){const u=new URL(input);return new Response(pages[u.pathname]);}},webview:{async open(){return {async navigate(value){url=value;},async executeJavaScript(){return true;},async getHtml(){return `<main>${body}</main>`;}};}}});
  const c=await plugin.getChapters({id:contentId});const result=await plugin.getContent({id:contentId,chapterId:c.items[0].id});assert.equal(url,'https://xchina001.ink'+novel+'/1');assert.ok(result.text.includes('第一段'));
 });
