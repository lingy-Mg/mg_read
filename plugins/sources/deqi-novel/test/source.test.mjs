import assert from'node:assert/strict';import test from'node:test';import*as plugin from'../dist/index.mjs';const list=`<div class="bookbox"><h4 class="bookname"><a href="/books/3305/">测试小说</a></h4><div class="author">作者：作者</div><div class="cat"><a>最新章</a></div></div>`,detail=`<meta property="og:title" content="测试小说"><meta property="og:novel:author" content="作者"><meta property="og:image" content="https://img.example/c.jpg">`,toc=`<a href="/books/3305/2905167.html">第一章</a>`,page=`<h1 class="pt10">第一章</h1>`,script=`var chapterToken = 't'; var timestamp = 1; var nonce = 'n';`;test('Deqi source exchanges chapter token and returns text',async()=>{const proxied=[];await plugin.activate({log:{info(){},warn(){}},resource:{proxy(v){proxied.push(v);return`http://127.0.0.1/r/${proxied.length}`;}},http:{async fetch(input){const url=String(input);if(url.includes('/sort/'))return new Response(list);if(url.includes('articleinfo'))return new Response(detail);if(url.endsWith('/books/3305/'))return new Response(toc);if(url.includes('chapter.js.php'))return new Response(script);if(url.includes('ajax2.php'))return Response.json({status:1,data:{content:'<p>正文内容</p>'}});return new Response(page);}}});const listing=await plugin.discover({target:'channel:1',cursor:null,collectionId:null,pageSize:5}),item=listing.document.components[0].children[0].items[0].content;assert.equal(item.id,'book:3305');const chapters=await plugin.getChapters({id:item.id});assert.equal(chapters.items[0].id,'book:3305:2905167');const content=await plugin.getContent({id:item.id,chapterId:chapters.items[0].id});assert.equal(content.text,'正文内容');assert.equal(proxied[0].kind,'image');});

test('discovery exposes official ranking charts and paginates chart results', async () => {
  const requests = [];
  const ranking = list + '<div class="bookbox"><h4 class="bookname"><a href="/books/3306/">第二部小说</a></h4><div class="author">作者：另一作者</div><div class="cat"><a>另一最新章</a></div></div>';
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { return 'http://127.0.0.1/chart/' + value.kind; } },
    http: { async fetch(input) { const path = new URL(input).pathname; requests.push(path); return new Response(path.endsWith('/2.html') ? '' : ranking); } },
  });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  const rankingCategories = home.document.components[1].children[0].categories;
  assert.equal(rankingCategories.length, 35);
  assert.deepEqual(rankingCategories.slice(0, 4).map((value) => value.target), [
    'chart:allvisit', 'chart:monthvisit', 'chart:weekvisit', 'chart:dayvisit',
  ]);

  const first = await plugin.discover({ target: 'chart:dayvisit', cursor: null, collectionId: null, pageSize: 1 });
  assert.equal(first.document.components[0].title, '日点击榜');
  assert.equal(first.document.components[0].children[0].layout, 'compact');
  assert.equal(first.document.components[0].children[0].items[0].content.id, 'book:3305');
  assert.deepEqual(first.document.components[0].children[0].continuation, {
    target: 'chart:dayvisit',
    cursor: 'chart:dayvisit:1:1',
  });

  const next = await plugin.discover({
    target: 'chart:dayvisit',
    cursor: 'chart:dayvisit:1:1',
    collectionId: 'deqi:chart:dayvisit',
    pageSize: 1,
  });
  assert.equal(next.kind, 'append');
  assert.equal(next.collectionId, 'deqi:chart:dayvisit');
  assert.equal(next.items[0].content.id, 'book:3306');
  assert.deepEqual(next.continuation, { target: 'chart:dayvisit', cursor: 'chart:dayvisit:2:0' });
  const last = await plugin.discover({
    target: 'chart:dayvisit',
    cursor: 'chart:dayvisit:2:0',
    collectionId: 'deqi:chart:dayvisit',
    pageSize: 1,
  });
  assert.equal(last.items.length, 0);
  assert.equal(last.continuation, null);
  assert.deepEqual(requests, ['/top/dayvisit/1.html', '/top/dayvisit/2.html']);
  await assert.rejects(
    plugin.discover({ target: 'chart:unknown', cursor: null, collectionId: null, pageSize: 5 }),
    /Discovery target is invalid/u,
  );
});
