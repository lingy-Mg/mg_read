import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('packages native Sebo source deterministically', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(pkg.mgread.id, 'org.mgread.sebo-live');
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.deepEqual(first.bytes, second.bytes);
});
