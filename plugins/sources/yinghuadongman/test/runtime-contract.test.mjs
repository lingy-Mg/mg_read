import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { build } from 'esbuild';
import * as plugin from '../dist/index.mjs';

test('fixture outputs pass the current Runtime source validators', async () => {
  const validators = await loadRuntimeValidators();
  const [list, detail, player] = await Promise.all([
    'list.html', 'detail.html', 'player-direct.html',
  ].map((name) => readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8')));
  await plugin.activate({
    log: { info() {}, warn() {} },
    errors: { raise(code) { throw Object.assign(new Error(code), { code, name: 'PluginManagerError' }); } },
    resource: {
      proxy() { return 'http://127.0.0.1:9000/v1/source-resource/abcdefghijklmnop'; },
    },
    http: {
      async fetch(input) {
        const path = new URL(input).pathname;
        if (path === '/v/101.html') return new Response(detail);
        if (path === '/p/101-5-1.html') return new Response(player);
        return new Response(list);
      },
    },
  });
  const pluginId = 'org.mgread.yinghuadongman';
  const sourceName = 'Fixture Yinghua';
  const discovery = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 5 });
  assert.doesNotThrow(() => validators.validateDiscoverResult(pluginId, sourceName, discovery));
  const search = await plugin.search({ query: 'fixture', cursor: null, pageSize: 5 });
  assert.doesNotThrow(() => validators.validateSearchResult(pluginId, sourceName, search));
  const info = await plugin.getDetail({ id: search.items[0].id });
  assert.doesNotThrow(() => validators.validateDetailResult(pluginId, sourceName, info));
  const catalog = await plugin.getChapters({ id: info.id });
  assert.doesNotThrow(() => validators.validateChaptersResult(pluginId, sourceName, catalog));
  const content = await plugin.getContent({ id: info.id, chapterId: 'video:101:5:1' });
  assert.doesNotThrow(() => validators.validateContentResult(pluginId, sourceName, content));
});

async function loadRuntimeValidators() {
  const runtimeRoot = fileURLToPath(new URL('../../../../packages/mg_read_node_runtime/', import.meta.url));
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
      sourcefile: 'yinghua-runtime-contract-entry.mts',
    },
    target: 'node24',
    write: false,
  });
  const source = result.outputFiles[0]?.text;
  assert.ok(source);
  return import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
}
