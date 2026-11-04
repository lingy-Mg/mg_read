/** Category isolation, complete single pages and the seven-day public schedule. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const list = await readFile(new URL('./fixtures/list.html', import.meta.url), 'utf8');
const week = await readFile(new URL('./fixtures/week.html', import.meta.url), 'utf8');
const card = id => `<a href="/v/${id}.html" title="Fixture ${id}"><img src="/cover.jpg"></a>`;
const panel = body => `<div class="module-main tab-list"><div class="module-items module-poster-items">${body}</div></div>`;
const collections = result => result.document.components.flatMap(section => section.children);

async function activate(html) {
  const requests = [];
  await plugin.activate({
    log: { info() {}, warn() {} }, resource: { proxy(value) { return value.url; } },
    http: { async fetch(input) { requests.push(new URL(input).pathname); return new Response(html); } },
  });
  return requests;
}

for (const [id, route] of [['today', '/label/new.html'], ['hot', '/label/hot.html'], ['new', '/s/1.html']]) {
  test(`${id} keeps its whole panel, excludes other modules and never invents a next page`, async () => {
    const requests = await activate(list + '<h2>排行榜</h2>' + panel(card(999)));
    for (const pageSize of [1, 2, 100]) {
      const result = await plugin.discover({ target: `category:${id}`, cursor: null, collectionId: null, pageSize });
      assert.deepEqual(collections(result).flatMap(collection => collection.items.map(item => item.content.id)), ['video:101', 'video:102']);
      assert.ok(collections(result).every(collection => collection.continuation === null));
    }
    await assert.rejects(plugin.discover({ target: `category:${id}`, cursor: `category:${id}:2`, collectionId: `video:${id}`, pageSize: 1 }), /Discovery cursor is invalid/u);
    assert.deepEqual(requests, Array(3).fill(route));
  });
}

test('weekly schedule retains all seven days and over fifty items without mixing days', async () => {
  let html = week;
  for (let day = 1; day <= 7; day += 1) {
    const cards = day === 2 ? '' : Array.from({ length: 12 }, (_, index) => card(day * 100 + index)).join('');
    html = html.replace(`__DAY_${day}__`, cards);
  }
  await activate(html);
  const result = await plugin.discover({ target: 'category:week', cursor: null, collectionId: null, pageSize: 1 });
  assert.deepEqual(result.document.components.map(section => section.title), ['周一', '周二', '周三', '周四', '周五', '周六', '周日']);
  assert.equal(collections(result).flatMap(collection => collection.items).length, 72);
  for (const [index, collection] of collections(result).entries()) {
    assert.equal(collection.id, `video:week:${index + 1}`);
    assert.equal(collection.continuation, null);
    assert.ok(collection.items.every(item => Number(item.content.id.slice(6)) >= (index + 1) * 100 && Number(item.content.id.slice(6)) < (index + 2) * 100));
  }
  await assert.rejects(plugin.discover({ target: 'category:week', cursor: 'category:week:2', collectionId: 'video:week', pageSize: 1 }), /Discovery cursor is invalid/u);
});

test('large single-page panels preserve cards within the public collection limit', async () => {
  await activate(panel(Array.from({ length: 65 }, (_, index) => card(index + 1)).join('')));
  const result = await plugin.discover({ target: 'category:today', cursor: null, collectionId: null, pageSize: 1 });
  assert.deepEqual(collections(result).map(collection => collection.items.length), [50, 15]);
  assert.equal(new Set(collections(result).flatMap(collection => collection.items.map(item => item.content.id))).size, 65);
  assert.ok(collections(result).every(collection => collection.continuation === null));
});

test('missing category markup and incomplete weekday panels fail instead of becoming empty success', async () => {
  await activate('<html>Upstream maintenance</html>');
  await assert.rejects(plugin.discover({ target: 'category:today', cursor: null, collectionId: null, pageSize: 20 }), /Category listing is unavailable/u);
  await activate(list);
  await assert.rejects(plugin.discover({ target: 'category:week', cursor: null, collectionId: null, pageSize: 20 }), /Weekly schedule is unavailable/u);
});
