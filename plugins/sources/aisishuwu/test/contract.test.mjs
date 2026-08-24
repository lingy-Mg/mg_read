import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('exports the standard Plugin API v1 entry points and hot-search extension', async () => {
  assert.deepEqual(
    Object.keys(plugin).sort(),
    ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'resource', 'search', 'searchSuggestions'],
  );
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(packageJson.mgread.id, 'org.mgread.aisishuwu');
  assert.equal(packageJson.mgread.pluginApi, 1);
  assert.equal(packageJson.main, 'dist/index.mjs');
});
