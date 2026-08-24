import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';
import { packPlugin } from '../tools/pack.mjs';

test('offline demo exposes a recursive document and a targeted append', async () => {
  await plugin.activate({ log: { info() {} } });
  const home = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(home.kind, 'document');
  assert.equal(home.document.components[0].type, 'tabs');
  assert.equal(home.document.components[2].children[1].layout, 'horizontal');
  const category = await plugin.discover({ target: 'category:fantasy', cursor: null, collectionId: null, pageSize: 20 });
  const collection = category.document.components[0].children[0];
  const append = await plugin.discover({ target: 'category:fantasy', cursor: collection.continuation.cursor, collectionId: collection.id, pageSize: 20 });
  assert.equal(append.kind, 'append');
  assert.equal(append.collectionId, collection.id);
});

test('detail preserves generated opaque ids and rejects foreign ids', async () => {
  for (const id of ['demo:fantasy-1', 'demo:search:星海']) {
    const detail = await plugin.getDetail({ id });
    assert.equal(detail.id, id);
  }
  await assert.rejects(
    () => plugin.getDetail({ id: 'fantasy-1' }),
    /Invalid demonstration content id/,
  );
});

test('packed archive marks local and central entry names as UTF-8', async () => {
  await packPlugin();
  const archive = await readFile(
    new URL('../artifacts/org.mgread.discovery-demo-0.1.1.mgplugin', import.meta.url),
  );
  const endOfCentralDirectory = archive.length - 22;
  const centralOffset = archive.readUInt32LE(endOfCentralDirectory + 16);

  assert.equal(archive.readUInt16LE(6), 0x0800);
  assert.equal(archive.readUInt16LE(centralOffset + 8), 0x0800);
});
