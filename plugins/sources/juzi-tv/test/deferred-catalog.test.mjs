// Large real-shaped catalogs exercise line loading without live network I/O.
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

function fixture(lines = 15, count = 3000) {
  return { vodId: 10, vodName: '大型目录', playerList: Array.from({ length: lines }, (_, line) => ({
    playerId: line + 1, playerName: `线路 ${line + 1}`,
    epList: Array.from({ length: count }, (_, index) => ({ epId: line * count + index + 1, epName: `第 ${index + 1} 集` })),
  })) };
}
async function activate(data) {
  let calls = 0;
  await plugin.activate({ log: { info() {}, warn() {} }, resource: { proxy: () => 'https://example.test/cover' },
    http: { async fetch() { calls++; return Response.json({ result: true, data }); } } });
  return () => calls;
}
test('15 x 3000 returns default line, loads a complete other line, and reuses upstream response', async () => {
  const calls = await activate(fixture());
  await plugin.getDetail({ id: 'vod:10' });
  const first = await plugin.getChapters({ id: 'vod:10', supportsDeferredGroups: true });
  assert.equal(first.items.length, 3000);
  assert.equal(first.groups.filter(group => group.deferred).length, 14);
  const groupId = first.groups[12].id;
  const [second, repeat] = await Promise.all([1, 2].map(() => plugin.getChapters({ id: 'vod:10', groupId, supportsDeferredGroups: true })));
  assert.equal(second.items.length, 3000);
  assert.equal(second.groups[12].episodes.at(-1).order, 2999);
  assert.equal(repeat.groups[12].id, groupId);
  assert.equal(calls(), 1);
  assert.equal(first.groups[12].episodes.length, 0);
  await plugin.getChapters({ id: 'vod:10', supportsDeferredGroups: true, refresh: true });
  assert.equal(calls(), 2);
});
test('small catalogs stay complete; each group order restarts at zero', async () => {
  await activate(fixture(3, 50));
  const result = await plugin.getChapters({ id: 'vod:10', supportsDeferredGroups: true });
  assert.equal(result.items.length, 150);
  assert.ok(result.groups.every(group => !group.deferred && group.episodes[0].order === 0));
  assert.equal(result.groups[1].id, 'group:10:1');
});
test('older hosts receive complete catalogs and large line IDs survive upstream reordering', async () => {
  const data = fixture(2, 600);
  await activate(data);
  const full = await plugin.getChapters({ id: 'vod:10' });
  assert.equal(full.items.length, 1200);
  const id = full.groups[1].id;
  data.playerList.reverse();
  const refreshed = await plugin.getChapters({ id: 'vod:10', groupId: id, supportsDeferredGroups: true, refresh: true });
  assert.equal(refreshed.groups[0].id, id);
  assert.equal(refreshed.groups[0].episodes.length, 600);
  await assert.rejects(plugin.getChapters({ id: 'vod:10', groupId: 'missing', supportsDeferredGroups: true }));
});
