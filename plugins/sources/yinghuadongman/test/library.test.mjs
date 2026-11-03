import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('library exposes all observed filter groups, preserves combined links and paginates complete upstream pages', async () => {
  const [filters, combined, list] = await Promise.all(['library-filters.html', 'library-filters-combined.html', 'list.html']
    .map(name => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8')));
  const requests = [];
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { return value.url; } },
    http: { async fetch(input) {
      const url = new URL(input);
      requests.push(url.pathname);
      const rows = url.pathname.includes('/class/') ? combined : filters;
      return new Response(rows + list + '<a href="/w/1/page/2.html">下一页</a>');
    } },
  });
  const root = await plugin.discover({ target: 'category:library', cursor: null, collectionId: null, pageSize: 1 });
  const filter = root.document.components[0];
  assert.equal(filter.type, 'filters');
  assert.equal(filter.resetTarget, 'category:library');
  assert.deepEqual(filter.groups.map(group => group.label), ['类型', '剧情', '地区', '年份', '字母', '排序']);
  assert.deepEqual(filter.groups.map(group => group.options.length), [4, 45, 4, 18, 28, 3]);
  const collection = root.document.components[1].children[0];
  assert.equal(collection.items.length, 2, 'a smaller page-size hint must not discard cards within the upstream page');
  assert.equal(collection.continuation.cursor, 'category:library:2');
  await plugin.discover({ target: 'category:library', cursor: collection.continuation.cursor, collectionId: 'video:library', pageSize: 1 });
  assert.equal(requests.at(-1), '/w/1/page/2.html');

  const target = `library:${Buffer.from(JSON.stringify({ type: '10', class: '搞笑' })).toString('base64url')}`;
  const selected = await plugin.discover({ target, cursor: null, collectionId: null, pageSize: 20 });
  const region = selected.document.components[0].groups.find(group => group.label === '地区').options.find(option => option.label === '日本');
  await plugin.discover({ target: region.target, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(requests.at(-1), `/w/10/area/${encodeURIComponent('日本')}/class/${encodeURIComponent('搞笑')}.html`);

  const before = requests.length;
  for (const invalid of ['library:bad', `library:${Buffer.from('{"type":"../bad"}').toString('base64url')}`,
    `library:${Buffer.from('{"type":"1","url":"https://other.invalid"}').toString('base64url')}`]) {
    await assert.rejects(plugin.discover({ target: invalid, cursor: null, collectionId: null, pageSize: 20 }));
  }
  await assert.rejects(plugin.discover({ target: 'category:library', cursor: 'wrong:2', collectionId: 'video:library', pageSize: 20 }));
  assert.equal(requests.length, before);
});
