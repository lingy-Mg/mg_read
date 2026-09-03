import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('Qingting GraphQL, detail and live audio are native and stable', async () => {
  const calls = [];
  const resources = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return 'http://127.0.0.1/resource/opaque';
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = String(input);
        calls.push({ url, init });
        if (url.includes('/api/pc/radio/')) {
          return Response.json({ data: { id: 101, title: '测试电台', imgUrl: '/cover.jpg', description: '详情' } });
        }
        const body = JSON.parse(init.body);
        if (body.query.includes('searchResultsPage')) {
          return Response.json({ data: { searchResultsPage: { searchData: [{ id: 101, title: '测试电台' }], numFound: 1 } } });
        }
        return Response.json({ data: { radioPage: { contents: [{ id: 101, title: '测试电台', imgUrl: '/cover.jpg' }] } } });
      },
    },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.ok(root.document.components[0].children[0].categories.length > 40);
  const list = await plugin.discover({ target: 'category:217', cursor: null, collectionId: null, pageSize: 5 });
  const id = list.document.components[0].children[0].items[0].content.id;
  assert.equal(id, 'radio:MTAx');
  const found = await plugin.search({ query: '测试', cursor: null, pageSize: 5 });
  assert.equal(found.totalCount, 1);
  const detail = await plugin.getDetail({ id });
  assert.equal(detail.description, '详情');
  const chapters = await plugin.getChapters({ id });
  const content = await plugin.getContent({ id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'audio');
  assert.equal(resources.find((resource) => resource.kind === 'audio')?.url, 'https://lhttp-hw.qtfm.cn/live/101/64k.mp3');
  assert.ok(calls.some((call) => call.url === 'https://webbff.qtfm.cn/www' && call.init.method === 'POST'));
});
