import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const encode = (prefix, path) => `${prefix}:${Buffer.from(path, 'utf8').toString('base64url')}`;

test('public home keeps varied discovery sections and a target chapter yields proxy-only pages', { timeout: 30_000 }, async () => {
  let proxied; const homeImages = [];
  await plugin.activate({ dataDir: '.', cacheDir: '.', app: {}, plugin: {}, log: { debug(){}, info(){}, warn(){}, error(){} }, resource: { proxy(request) { proxied = request; homeImages.push(request.url); return `http://127.0.0.1/resource/${homeImages.length}`; } }, http: { fetch: globalThis.fetch } });
  const discovery = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(discovery.kind, 'document');
  assert.deepEqual(discovery.document.components.map((component) => component.type === 'group' ? `${component.type}:${component.layout}` : component.children[0].layout), ['carousel', 'coverGrid', 'group:vertical', 'shelf', 'group:grid']);
  const sections = discovery.document.components.flatMap((component) => component.type === 'group' ? component.children : [component]);
  assert.deepEqual(sections.map((section) => section.title), ['精选推荐', '最近更新', '上升最快', '人气排行榜', '完结大作', '收藏榜', '打赏榜', '月票榜']);
  assert.ok(sections.every((section) => section.children[0].items.length > 0));
  assert.ok(new Set(homeImages).size >= 20);
  const detailItems = [...new Map(sections.map((section) => section.children[0].items[0].content).map((content) => [content.id, content])).values()];
  for (const item of detailItems) { const detail = await plugin.getDetail({ id: item.id }); assert.equal(detail.id, item.id); assert.ok(detail.title.length > 0); }
  const content = await plugin.getContent({ id: encode('comic', '/index.php/comic/meinuzishangshideyejianzhenliaoshi'), chapterId: encode('chapter', '/index.php/chapter/101382') });
  assert.equal(content.text, null); assert.ok(content.pages.length > 0); assert.ok(content.pages.every((page) => /^http:\/\/127\.0\.0\.1\/resource\/\d+$/u.test(page.url)));
  const image = await plugin.resource(proxied); assert.equal(image.status, 200); assert.ok(image.body.byteLength > 0);
});
