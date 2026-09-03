import assert from 'node:assert/strict';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('45hk native flow handles verification and proxies audio', async () => {
  const resources = [];
  const calls = [];
  const list = '<div class="play_list"><ul><li><a href="/mp3/songabc.html" title="周深《测试歌曲》">歌曲</a></li></ul></div>';
  const detail = '<div class="list_r"><h1>周深《测试歌曲》</h1></div><div class="pic"><img src="/cover.jpg"></div><div class="content">测试专辑</div>';
  let verified = false;
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        resources.push(value);
        return `http://127.0.0.1/resource/${resources.length}`;
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = String(input);
        calls.push({ url, init });
        if (url.endsWith('/js/play.php')) {
          return Response.json({ url: 'https://media.example/song.mp3' });
        }
        if (init.method === 'POST') {
          verified = true;
          return new Response(detail, { headers: { 'set-cookie': 'verified=1; Path=/' } });
        }
        if (url.includes('/mp3/') && !verified) {
          return new Response('<form>安全人机验证<input name="csrf_token" value="token-a"><input name="human_check"></form>');
        }
        return new Response(url.includes('/mp3/') ? detail : list);
      },
    },
  });

  const root = await plugin.discover({ target: 'category:top', cursor: null, collectionId: null, pageSize: 5 });
  const id = root.document.components[0].children[0].items[0].content.id;
  const info = await plugin.getDetail({ id });
  assert.equal(info.author, '周深');
  const chapters = await plugin.getChapters({ id });
  const content = await plugin.getContent({ id, chapterId: chapters.items[0].id });
  assert.equal(content.media.resourceType, 'audio');
  assert.equal(resources.find((value) => value.kind === 'audio').url, 'https://media.example/song.mp3');
  assert.ok(calls.some((call) => call.init.method === 'POST' && String(call.init.body).includes('csrf_token')));
});
