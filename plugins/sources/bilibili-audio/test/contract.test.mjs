import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('packages Bilibili source deterministically with required search and playback exports', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const descriptor = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(descriptor.mgread.id, 'org.mgread.bilibili-audio');
  assert.equal(descriptor.version, '1.0.4');
  assert.deepEqual(descriptor.mgread.contentKinds, ['audio']);
  assert.match(descriptor.mgread.description, /有声书/);
  assert.match(descriptor.mgread.description, /输入作品链接/);
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.deepEqual(first.bytes, second.bytes);
});
