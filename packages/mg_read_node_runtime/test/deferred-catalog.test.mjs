import assert from 'node:assert/strict';
import test from 'node:test';
import { AsyncLocalStorage } from 'node:async_hooks';
import { parseChaptersParams, validateChaptersResult } from '../dist/plugin-content.js';
import { invokeLoadedPluginContent } from '../dist/plugin-content-invocation.js';
import { normalizePluginModule } from '../dist/plugin-manager-files.js';

const episode = (id, order = 0) => ({ id, title: id, order, url: null, volumeTitle: null,
  wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
const loaded = { id: 'a', title: 'A', order: 0, episodes: [episode('a1')] };
const deferred = { id: 'b', title: 'B', order: 1, deferred: true, episodes: [] };
const result = { groups: [loaded, deferred], items: loaded.episodes };
test('deferred state is explicit; legacy empty groups and contradictory flags remain invalid', () => {
  assert.equal(validateChaptersResult('org.test.source', 'Source', result).groups[1].deferred, true);
  for (const patch of [{ deferred: false }, { deferred: null }, { episodes: [episode('b1')] }]) {
    assert.throws(() => validateChaptersResult('org.test.source', 'Source', { ...result, groups: [loaded, { ...deferred, ...patch }] }));
  }
  assert.deepEqual(parseChaptersParams({ pluginId: 'org.test.source', id: '1' }).request, { id: '1' });
  assert.throws(() => parseChaptersParams({ pluginId: 'org.test.source', id: '1', groupId: '' }));
});
test('5000 episodes in one line remain ordered and validated without quadratic matching', () => {
  const items = Array.from({ length: 5000 }, (_, i) => episode(`ep${i}`, i));
  assert.equal(validateChaptersResult('org.test.source', 'Source', { items, groups: [{ ...loaded, episodes: items }, deferred] }).items.length, 5000);
});
async function invoke(module, request = { id: '1' }) {
  return invokeLoadedPluginContent({ debugLogEnabled: () => false, deadlineUnixMs: String(Date.now() + 30000),
    events() {}, invocationScope: new AsyncLocalStorage(), operation: 'getChapters',
    plugin: { descriptor: { displayName: 'Source' }, module }, pluginId: 'org.test.source', request,
    signal: new AbortController().signal, snapshot: { enabled: true }, validate: validateChaptersResult });
}
test('negotiation leaves legacy plugin requests unchanged and checks group correlation', async () => {
  let received;
  const legacy = { getChapters: request => { received = request; return { items: loaded.episodes, groups: [loaded] }; } };
  await invoke(legacy);
  assert.deepEqual(received, { id: '1' });
  const modern = { deferredGroups: true, getChapters: request => { received = request; return result; } };
  await invoke(modern);
  assert.equal(received.supportsDeferredGroups, true);
  await assert.rejects(invoke(modern, { id: '1', groupId: 'b' }));
  await assert.rejects(invoke({ getChapters: () => result }));
  const methods = Object.fromEntries(['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions'].map(key => [key, () => {}]));
  assert.equal(normalizePluginModule({ ...methods, deferredGroups: true }).deferredGroups, true);
});
