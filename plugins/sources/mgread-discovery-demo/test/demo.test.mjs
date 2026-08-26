/**
 * 离线发现组件演示书源的内容与发布接口测试。
 *
 * 职责：验证递归发现、ID 边界和不落盘的 single-file 构建函数。
 * 注意：固定数据测试不访问网络，也不承担 Runtime 安装验收。
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';

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

test('builds the default single-file artifact without writing it', async () => {
  const artifact = await buildPluginArtifact();
  assert.equal(artifact.format, 'singleFile');
  assert.equal(artifact.fileName, 'org.mgread.discovery-demo-0.1.2.mgplugin.js');
  assert.equal(artifact.bytes.toString('utf8', 0, 21), '// @mgread-plugin-v1 ');
});
