/** Build metadata, deterministic artifact and production Runtime schema checks. */
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact } from '../tools/mgread.mjs';
import {
  validateDiscoverResult, validateSearchResult, validateDetailResult,
  validateChaptersResult, validateContentResult,
} from '../../../../packages/mg_read_node_runtime/dist/plugin-content.js';

test('packages an independent video source deterministically', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const descriptor = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(descriptor.mgread.id, 'org.mgread.bilibili-video');
  assert.equal(descriptor.version, '1.0.0');
  assert.equal(descriptor.mgread.displayName, '哔哩哔哩视频');
  assert.deepEqual(descriptor.mgread.contentKinds, ['video']);
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.deepEqual(first.bytes, second.bytes);
});

test('video discovery, URL search, details, multipart catalog and playback pass production validators', async () => {
  const pluginId = 'org.mgread.bilibili-video', sourceName = '哔哩哔哩视频';
  const bvid = 'BV1tGe36YEap', id = `bvid:${bvid}`;
  await plugin.activate({
    log: { info() {} },
    resource: { proxy() { return `http://127.0.0.1/v1/source-resource/${'x'.repeat(24)}`; } },
    http: { async fetch(input) {
      return Response.json({ code: 0, data: String(input).includes('/playurl?')
        ? { format: 'mp4720', durl: [{ url: 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video.mp4' }] }
        : { bvid, title: '视频契约', duration: 120, pic: '', owner: { name: '作者' },
          pages: [{ cid: 123, page: 1, part: '第一集', duration: 120 }] } });
    } },
  });
  validateDiscoverResult(pluginId, sourceName, await plugin.discover({ target: null, cursor: null, collectionId: null }));
  validateSearchResult(pluginId, sourceName, await plugin.search({ query: bvid, cursor: null, pageSize: 20 }));
  validateDetailResult(pluginId, sourceName, await plugin.getDetail({ id }));
  const catalog = validateChaptersResult(pluginId, sourceName, await plugin.getChapters({ id }));
  const content = validateContentResult(pluginId, sourceName, await plugin.getContent({ id, chapterId: catalog.items[0].id }));
  assert.equal(content.contentKind, 'video');
  assert.equal(content.media.resourceType, 'video');
});
