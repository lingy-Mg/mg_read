import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { build } from 'esbuild';

import * as plugin from '../dist/index.mjs';

test('fixture outputs pass the current Runtime source validators', async () => {
  const validators = await loadRuntimeValidators();
  await plugin.activate({
    log: { info() {}, warn() {} },
    resource: {
      proxy() {
        return 'http://127.0.0.1:9000/v1/source-resource/abcdefghijklmnop';
      },
    },
    http: {
      async fetch(input, init = {}) {
        const path = new URL(input).pathname;
        if (path.endsWith('/getVodList')) {
          const payload = JSON.parse(init.body);
          return Response.json({
            result: true,
            data: {
              items: Array.from({ length: 10 }, (_, index) => ({
                vodId: payload.vodTopicId * 100 + index,
                vodName: `专题 ${payload.vodTopicId} 视频 ${index + 1}`,
                coverImg: `https://img.example/${payload.vodTopicId}-${index}.jpg`,
                remark: index === 0 ? '更新至 12 集' : '已完结',
                flags: '2026 / 视频 / 大陆',
              })),
              totalPages: 1,
            },
          });
        }
        if (path.endsWith('/search/search')) {
          return Response.json({
            result: true,
            data: {
              items: [{
                vodId: 10,
                vodName: '测试视频',
                coverImg: 'https://img.example/c.jpg',
              }],
              totalPages: 1,
            },
          });
        }
        if (path.endsWith('/vodInfo/index')) {
          return Response.json({
            result: true,
            data: {
              vodId: 10,
              vodName: '测试视频',
              playerList: [{
                playerName: '线路',
                epList: [{ epId: 99, epName: '第一集' }],
              }, {
                playerName: '备用线路',
                epList: [{ epId: 100, epName: '第一集' }],
              }],
            },
          });
        }
        if (path.endsWith('/epDetail')) {
          return Response.json({
            result: true,
            data: [{ vodResolution: 3, canPlay: true }],
          });
        }
        if (path.endsWith('/playUrl')) {
          return Response.json({
            result: true,
            data: { playUrl: 'https://media.example/1.m3u8' },
          });
        }
        return Response.json({ result: true, data: { items: [] } });
      },
    },
  });

  const pluginId = 'org.mgread.juzi-tv';
  const sourceName = 'Fixture Juzi TV';
  const home = await plugin.discover({
    target: null,
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });
  assert.deepEqual(
    home.document.components.map((component) => component.id),
    [
      'juzi-home-short-section',
      'juzi-home-navigation',
      'juzi-home-movie-section',
      'juzi-home-series-section',
    ],
  );
  assert.deepEqual(
    home.document.components
      .filter((component) => component.type === 'section')
      .map((section) => section.children[0].items.length),
    [8, 8, 8],
  );
  assert.doesNotThrow(() =>
    validators.validateDiscoverResult(pluginId, sourceName, home));

  const discovery = await plugin.discover({
    target: 'channel:short',
    cursor: null,
    collectionId: null,
    pageSize: 5,
  });
  assert.doesNotThrow(() =>
    validators.validateDiscoverResult(pluginId, sourceName, discovery));

  const search = await plugin.search({ query: '测试', cursor: null, pageSize: 5 });
  assert.doesNotThrow(() =>
    validators.validateSearchResult(pluginId, sourceName, search));

  const detail = await plugin.getDetail({ id: search.items[0].id });
  assert.doesNotThrow(() =>
    validators.validateDetailResult(pluginId, sourceName, detail));

  const chapters = await plugin.getChapters({ id: detail.id });
  assert.doesNotThrow(() =>
    validators.validateChaptersResult(pluginId, sourceName, chapters));

  const content = await plugin.getContent({
    id: detail.id,
    chapterId: chapters.items[0].id,
  });
  assert.doesNotThrow(() =>
    validators.validateContentResult(pluginId, sourceName, content));
});

async function loadRuntimeValidators() {
  const runtimeRoot = fileURLToPath(
    new URL('../../../../packages/mg_read_node_runtime/', import.meta.url),
  );
  const result = await build({
    bundle: true,
    format: 'esm',
    logLevel: 'silent',
    platform: 'node',
    stdin: {
      contents: [
        "export { validateDiscoverResult } from './src/plugin-content-discovery.ts';",
        "export { validateSearchResult, validateDetailResult, validateChaptersResult, validateContentResult } from './src/plugin-content-validation.ts';",
      ].join('\n'),
      loader: 'ts',
      resolveDir: runtimeRoot,
      sourcefile: 'juzi-runtime-contract-entry.mts',
    },
    target: 'node24',
    write: false,
  });
  const source = result.outputFiles[0]?.text;
  assert.ok(source);
  return import(
    `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
  );
}
