/** Live category audit: every root entry, public filter option and library page boundary. */
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { libraryRoute, libraryState } from '../dist/library.mjs';

test('live categories preserve their panels, weekdays and real library pagination', { timeout: 180_000 }, async t => {
  const origin = 'https://www.yinhuadm.xyz';
  const cache = new Map();
  const report = { checkedAt: new Date().toISOString(), status: 'running', categories: [], libraryPages: [], filters: [] };
  const reportDirectory = new URL('../../../../artifacts/source-tests/', import.meta.url);
  const page = path => {
    const url = new URL(path, origin).href;
    if (!cache.has(url)) cache.set(url, (async () => {
      const response = await fetch(url, { signal: AbortSignal.timeout(20_000) });
      assert.equal(response.status, 200, `upstream ${new URL(url).pathname}`);
      assert.equal(new URL(response.url).origin, origin);
      return response.text();
    })());
    return cache.get(url);
  };
  const rawIds = html => [...new Set([...html.matchAll(/href=["']\/v\/(\d+)\.html["']/gu)].map(match => `video:${match[1]}`))];
  const collection = result => result.document.components.at(-1).children[0];
  const filterGroups = result => result.document.components.find(component => component.type === 'filters').groups;
  const ids = items => items.map(item => item.content.id);
  const request = target => ({ target, cursor: null, collectionId: null, pageSize: 1 });
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: { proxy(value) { return value.url; } },
    http: { async fetch(input) { return new Response(await page(input)); } },
  });
  try {
    const root = await plugin.discover(request(null));
    const entries = root.document.components.find(component => component.id === 'video-categories').children[0].categories;
    assert.deepEqual(entries.map(entry => entry.id), ['library', 'today', 'hot', 'week', 'new']);
    const routes = new Map([['today', '/label/new.html'], ['hot', '/label/hot.html'], ['week', '/label/week.html'], ['new', '/s/1.html']]);
    for (const entry of entries.filter(entry => entry.id !== 'library')) {
      const html = await page(routes.get(entry.id));
      // Independent live oracle: split at the rendered page's sibling panel starts.
      // Later panel headings contain no content cards before that panel starts.
      const rawPanels = html.split(/<div\b[^>]*class=["'][^"']*\bmodule-main\b[^"']*\btab-list\b[^"']*["'][^>]*>/iu).slice(1);
      const expected = entry.id === 'week' ? rawPanels : rawPanels.slice(0, 1);
      const result = await plugin.discover(request(entry.target));
      assert.equal(result.document.components.length, expected.length);
      const surfaces = result.document.components.map((section, index) => {
        const items = section.children.flatMap(child => child.items);
        assert.deepEqual(ids(items), rawIds(expected[index]), `${entry.id} ${section.title} must keep every card in its own panel`);
        assert.ok(section.children.every(child => child.continuation === null && child.items.length <= 50));
        assert.ok(items.every(item => item.content.coverUrl !== null));
        return { title: section.title, items: items.length, continuation: null };
      });
      if (entry.id === 'week') assert.deepEqual(surfaces.map(surface => surface.title), ['周一', '周二', '周三', '周四', '周五', '周六', '周日']);
      report.categories.push({ id: entry.id, status: 'passed', surfaces });
      t.diagnostic(`${entry.id} ${surfaces.map(surface => `${surface.title}:${surface.items}`).join(' ')} noContinuation`);
    }

    const library = await plugin.discover(request('category:library'));
    const groups = filterGroups(library);
    assert.deepEqual(groups.map(group => group.label), ['类型', '剧情', '地区', '年份', '字母', '排序']);
    for (const option of groups[0].options) {
      const state = JSON.parse(Buffer.from(option.target.slice(8), 'base64url').toString('utf8'));
      const route = `/w/${state.type}.html`;
      const html = await page(route);
      const first = await plugin.discover(request(option.target));
      assert.deepEqual(ids(collection(first).items), rawIds(html));
      assert.ok(collection(first).continuation, `${option.label} first page should expose its real next page`);
      const second = await plugin.discover({ ...request(option.target), ...collection(first).continuation, collectionId: 'video:library' });
      assert.deepEqual(ids(second.items), rawIds(await page(`/w/${state.type}/page/2.html`)));
      assert.ok(second.items.some(item => !ids(collection(first).items).includes(item.content.id)));
      const lastPage = Number(/href=["'][^"']*\/page\/(\d+)\.html["'][^>]*>\s*尾页/u.exec(html)?.[1]);
      assert.ok(Number.isSafeInteger(lastPage) && lastPage > 2);
      const last = await plugin.discover({ ...request(option.target), cursor: `${option.target}:${lastPage}`, collectionId: 'video:library' });
      assert.deepEqual(ids(last.items), rawIds(await page(`/w/${state.type}/page/${lastPage}.html`)));
      assert.equal(last.continuation, null, `${option.label} terminal next link points at the current page`);
      report.libraryPages.push({ label: option.label, first: collection(first).items.length, second: second.items.length, lastPage, last: last.items.length, terminalContinuation: null });
    }

    const options = groups.flatMap(group => group.options.map(option => ({ ...option, groupId: group.id, groupLabel: group.label })));
    let nextOption = 0;
    await Promise.all(Array.from({ length: 3 }, async () => {
      while (nextOption < options.length) {
        const option = options[nextOption++];
        const result = await plugin.discover(request(option.target));
        const group = filterGroups(result).find(candidate => candidate.id === option.groupId);
        const selected = group.options.find(candidate => candidate.id === group.selectedOptionId);
        assert.equal(selected?.label, option.label, `${option.groupLabel}/${option.label} must remain selected`);
        const html = await page(libraryRoute(libraryState(option.target)));
        assert.deepEqual(ids(collection(result).items), rawIds(html), `${option.groupLabel}/${option.label} must keep the whole page`);
        const nextLink = /<a\b[^>]*href=["']([^"']+)["'][^>]*>\s*下一页/u.exec(html)?.[1];
        assert.equal(collection(result).continuation !== null, /\/page\/2\.html$/u.test(nextLink ?? ''), `${option.groupLabel}/${option.label} must follow a real next link`);
        report.filters.push({ group: option.groupLabel, label: option.label, items: collection(result).items.length, hasContinuation: collection(result).continuation !== null, status: 'passed' });
      }
    }));
    t.diagnostic(`library_types=${report.libraryPages.length} public_filter_options=${report.filters.length} requests=${cache.size}`);
    report.status = 'passed';
  } catch (error) {
    report.status = 'failed';
    report.failure = { message: error.message };
    throw error;
  } finally {
    await mkdir(reportDirectory, { recursive: true });
    await writeFile(new URL('yinghuadongman-categories-live.json', reportDirectory), JSON.stringify(report, null, 2));
  }
});
