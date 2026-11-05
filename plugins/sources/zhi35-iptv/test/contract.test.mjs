/** 公开导出、Runtime 校验与可独立加载的确定性 artifact；不修改宿主或 Runtime。 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import { build, stop } from 'esbuild';
import { assertStandardSourceContract, collectDiscoveryContent, collectDiscoveryTargets } from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';
import { buildPluginArtifact, buildPluginArtifactForProject } from '../tools/mgread.mjs';
import { playlist, hlsManifest, contextFixture, discoveryRequest } from './fixtures.mjs';

const pluginId = 'org.mgread.zhi35-iptv';

test('standard exports and deterministic artifact with verifiable code/icon hashes', async (t) => {
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assertStandardSourceContract({ plugin, packageJson, pluginId, optionalExports: ['searchSuggestions'], icon: 'assets/icon.png' });
  const first = await buildPluginArtifact(), second = await buildPluginArtifact();
  assert.deepEqual(first.bytes, second.bytes);
  assert.equal(first.format, 'singleFile');
  assert.equal(first.fileName, `${pluginId}-${packageJson.version}.mgplugin.js`);
  const newline = first.bytes.indexOf(10);
  const header = first.bytes.subarray(0, newline).toString('utf8');
  assert.ok(header.startsWith('// @mgread-plugin-v1 '));
  const envelope = JSON.parse(Buffer.from(header.slice('// @mgread-plugin-v1 '.length), 'base64url').toString('utf8'));
  const code = first.bytes.subarray(newline + 1);
  const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
  assert.equal(envelope.codeBytes, code.length);
  assert.equal(envelope.codeSha256, sha(code));
  assert.ok(code.toString('utf8').includes('Copyright (c) 2024 Amazing Watermelon'));
  assert.equal(envelope.icon.sha256, sha(Buffer.from(envelope.icon.data, 'base64')));
  assert.equal(envelope.descriptor.mgread.sourceUrl, 'https://github.com/zhi35/iptv');
  assert.equal(envelope.descriptor.dependencies, undefined);
  assert.equal(envelope.descriptor.devDependencies, undefined);
  const overridden = await buildPluginArtifactForProject(fileURLToPath(new URL('../', import.meta.url)), { versionOverride: '9.9.9' });
  assert.equal(overridden.fileName, `${pluginId}-9.9.9.mgplugin.js`);
  assert.deepEqual((await buildPluginArtifact()).bytes, first.bytes);
  const bundled = await loadIsolatedModule(first.bytes, t);
  await bundled.activate(contextFixture(async () => new Response(playlist)).context);
  assert.equal(collectDiscoveryContent(await bundled.discover(discoveryRequest)).length, 2);
});

test('root, categories, append, search, details, catalogs and media pass current Runtime validators', async (t) => {
  const validators = await loadValidators(t);
  await plugin.activate(contextFixture(async (url) => new Response(new URL(url).pathname.endsWith('.m3u8') ? hlsManifest : playlist)).context);
  const check = (method, value) => validators[method](pluginId, 'zhi35 IPTV fixture', value);
  const root = await plugin.discover(discoveryRequest);
  check('validateDiscoverResult', root);
  for (const target of collectDiscoveryTargets(root)) {
    const page = await plugin.discover({ ...discoveryRequest, target });
    check('validateDiscoverResult', page);
    const listing = page.document.components[0].children[0];
    if (listing.continuation) check('validateDiscoverResult', await plugin.discover({
      ...discoveryRequest, ...listing.continuation, collectionId: listing.id,
    }));
    for (const item of collectDiscoveryContent(page)) {
      check('validateDetailResult', await plugin.getDetail({ id: item.id }));
      const catalog = await plugin.getChapters({ id: item.id });
      check('validateChaptersResult', catalog);
      for (const episode of catalog.items) check('validateContentResult', await plugin.getContent({ id: item.id, chapterId: episode.id }));
    }
  }
  check('validateSearchResult', await plugin.search({ query: 'CCTV', cursor: null, pageSize: 50 }));
});

async function loadValidators(t) {
  try {
    const result = await build({
      bundle: true, format: 'esm', logLevel: 'silent', platform: 'node', target: 'node24', write: false,
      stdin: {
        contents: "export { validateDiscoverResult } from './src/plugin-content-discovery.ts';\nexport { validateSearchResult, validateDetailResult, validateChaptersResult, validateContentResult } from './src/plugin-content-validation.ts';",
        loader: 'ts', resolveDir: fileURLToPath(new URL('../../../../packages/mg_read_node_runtime/', import.meta.url)),
      },
    });
    return loadIsolatedModule(result.outputFiles[0].text, t);
  } finally { await stop(); }
}

async function loadIsolatedModule(bytes, t) {
  const root = await mkdtemp(join(tmpdir(), 'mgread-iptv-contract-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const entry = join(root, 'entry.mjs');
  await writeFile(entry, bytes);
  return import(pathToFileURL(entry).href);
}
