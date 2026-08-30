import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
test('exports manga Plugin API v1 with single-file metadata', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate','discover','getChapters','getContent','getDetail','search','searchSuggestions']);
  const pkg=JSON.parse(await readFile(new URL('../package.json',import.meta.url),'utf8'));
  assert.equal(pkg.mgread.id,'org.mgread.manhuagui-com'); assert.equal(pkg.mgread.packageMode,'single-file');
  assert.deepEqual(pkg.mgread.contentKinds,['manga']); assert.equal(pkg.main,'dist/index.mjs');
});

