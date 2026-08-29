/** Static Plugin API and descriptor contract; no network access. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('exports Plugin API v1 and declares a novel single-file descriptor', async () => {
  assert.deepEqual(
    Object.keys(plugin).sort(),
    ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'resource', 'search', 'searchSuggestions'],
  );
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(packageJson.mgread.id, 'org.mgread.elkoparts-net');
  assert.equal(packageJson.mgread.pluginApi, 1);
  assert.equal(packageJson.mgread.packageMode, 'single-file');
  assert.deepEqual(packageJson.mgread.contentKinds, ['novel']);
  assert.equal(packageJson.main, 'dist/index.mjs');
});

