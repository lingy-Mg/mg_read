/** Deterministic encrypted fixtures cover dynamic guards, auth, discovery, fallback search and playback. */
import assert from 'node:assert/strict';
import { createCipheriv, createHash } from 'node:crypto';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

const salt = '8124fb976064d07a5c6af58c771f1c87';
const dynamicGuard = 'X-App-Guard-fixture';
const video = {
  vod_id: 6861,
  vod_name: 'Fixture Anime',
  vod_pic: 'https://img.example/cover.jpg',
  vod_actor: 'Fixture Actor',
  vod_class: 'TV番剧',
  vod_blurb: 'Fixture intro',
  vod_remarks: '更新至 2 集',
};
const detail = {
  ...video,
  play_sources: [{
    from: 'mui2', display_name: '高清线路',
    episodes: [
      { episode_index: 1, episode_id: 'ep-1', name: '第1集' },
      { episode_index: 2, episode_id: 'ep-2', name: '第2集' },
    ],
  }],
};

test('native source negotiates current guards and projects one encrypted video chain', async () => {
  const calls = [];
  const resources = [];
  await plugin.activate({
    dataDir: 'fixture-data', cacheDir: 'fixture-cache',
    app: { runtimeVersion: 'test', nodeVersion: process.versions.node, pluginApi: 1 },
    plugin: { id: 'org.mgread.fanshu-anime', version: '1.0.0' },
    log: { debug() {}, info() {}, warn() {}, error() {} },
    resource: { proxy(request) { resources.push(request); return `http://127.0.0.1/resource/${resources.length}`; } },
    http: { async fetch(input, init = {}) {
      const url = new URL(input);
      const headers = new Headers(init.headers);
      const action = url.searchParams.get('action');
      calls.push({ action, init, headers });
      if (action === 'app_config') {
        assert.equal(headers.has(dynamicGuard), false);
        return encrypted({
          request_validation: { headers: [{ name: dynamicGuard, value: 'fixture-value' }] },
          system_verify: { app_signature_sha256: '1F83BDCA0957AADDCD3CE53088D60FD228ADC463EBA105495E4EBAE6962B54D6' },
        });
      }
      assert.equal(headers.get(dynamicGuard), 'fixture-value');
      if (action === 'device_secret') {
        assert.equal(init.method, 'POST');
        return encrypted({ device_secret: 'fixture-secret', ttl: 86400 });
      }
      if (action === 'category_videos') {
        return encrypted(url.searchParams.get('type_id') === '1' ? { list: [video] } : { list: [] });
      }
      if (action === 'video_detail') return encrypted(detail);
      if (action === 'video_play') return encrypted({
        play_url: 'https://media.example/fixture.m3u8',
        headers: { referer: 'https://yoapp.bytegooty.com/', user_agent: 'Fixture Player' },
      });
      throw new Error(`Unexpected action: ${action}`);
    } },
  });

  const root = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  const seed = root.document.components[0].children[0].items[0].content;
  assert.equal(seed.title, 'Fixture Anime');
  assert.equal(root.document.components.at(-1).children[0].categories.length, 9);
  const search = await plugin.search({ query: 'Fixture', cursor: null, pageSize: 5 });
  assert.equal(search.items[0].id, 'video:6861');
  const info = await plugin.getDetail({ id: seed.id });
  assert.equal(info.author, 'Fixture Actor');
  const chapters = await plugin.getChapters({ id: info.id });
  assert.equal(chapters.groups[0].title, '高清线路');
  assert.deepEqual(chapters.items.map((item) => item.title), ['第1集', '第2集']);
  const content = await plugin.getContent({ id: info.id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(content.media.url, 'http://127.0.0.1/resource/4');
  assert.equal(resources.at(-1).headers.Referer, 'https://yoapp.bytegooty.com/');
  assert.equal(calls.filter(({ action }) => action === 'app_config').length, 1);
  assert.equal(calls.filter(({ action }) => action === 'device_secret').length, 1);
});

test('invalid ids are rejected before API work', async () => {
  await assert.rejects(plugin.getDetail({ id: 'video:invalid' }), /Content ID is invalid/u);
  await assert.rejects(plugin.getContent({ id: 'video:6861', chapterId: 'video:6861:broken' }), /Chapter ID is invalid/u);
});

function encrypted(value) {
  const seed = 'fixture response seed';
  const keyCipher = createCipheriv('aes-128-ecb', sha(salt).subarray(0, 16), null);
  const ek = Buffer.concat([keyCipher.update(seed, 'utf8'), keyCipher.final()]).toString('base64');
  const dataCipher = createCipheriv('aes-256-cbc', sha(`${seed}${salt}`), sha(`${salt}${seed}`).subarray(0, 16));
  const data = Buffer.concat([dataCipher.update(JSON.stringify(value), 'utf8'), dataCipher.final()]).toString('base64');
  return new Response(JSON.stringify({ success: true, data, ek }), { headers: { 'content-type': 'application/json' } });
}

function sha(value) { return createHash('sha256').update(value).digest(); }
