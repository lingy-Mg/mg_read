import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('exports standard Plugin API v1 and the Runtime-owned resource handler', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'resource', 'search', 'searchSuggestions']);
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(packageJson.mgread.id, 'org.mgread.shudugu');
  assert.equal(packageJson.main, 'dist/index.mjs');
});
