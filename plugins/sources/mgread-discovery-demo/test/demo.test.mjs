import assert from 'node:assert/strict';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

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
