import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('audio fixture covers search, catalog, locked items and proxy playback metadata', async () => {
  const fixture = JSON.parse(await readFile(new URL('./fixtures/catalog.json', import.meta.url), 'utf8'));
  const resources = []; const calls = []; const logs = [];
  await plugin.activate({ log: { info(event) { logs.push(`info:${event}`); }, warn(event) { logs.push(`warn:${event}`); } }, resource: { proxy(value) { resources.push(value); return 'http://127.0.0.1:9000/v1/source-resource/token123456789012'; } }, http: { async fetch(input, init) {
    const url = String(input); calls.push({ url, init });
    if (url.includes('AppGetChapterUrl2023')) return Response.json(fixture.play);
    if (url.includes('chapter?')) return Response.json(fixture.chapters);
    if (url.includes('book?')) return Response.json(fixture.book);
    if (url.includes('appHome')) return Response.json(fixture.home);
    return Response.json(fixture.search);
  } } });
  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(root.document.components[0].children[0].categories.length, 8);
  const discovery = await plugin.discover({ target: 'category:popular', cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.document.components[0].children[0].items.length, 1);
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 });
  const detail = await plugin.getDetail({ id: search.items[0].id });
  const chapters = await plugin.getChapters({ id: detail.id });
  assert.equal(chapters.items.length, 2); assert.equal(chapters.items[1].isLocked, true);
  const content = await plugin.getContent({ id: detail.id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'audio'); assert.equal(content.media.resourcePolicy, 'sessionOnly');
  assert.equal(content.media.url.startsWith('http://127.0.0.1:'), true);
  assert.equal(resources[0].kind, 'audio'); assert.equal(resources[0].headers.Range, undefined);
  await assert.rejects(plugin.getContent({ id: detail.id, chapterId: chapters.items[1].id }), /paid audio chapter/u);
  assert.deepEqual(logs.slice(-3), ['info:audio_playback_resource_resolved', 'info:audio_playback_resource_requested', 'warn:audio_playback_resource_failed']);
  assert.ok(calls.every(({ init }) => init.headers.cookie === undefined));
});
