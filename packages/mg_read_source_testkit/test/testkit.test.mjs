/** 数据源测试库自身的离线行为测试；不访问任何真实来源。 */
import assert from 'node:assert/strict';
import { access } from 'node:fs/promises';
import test from 'node:test';

import {
  SourceTestFailure,
  assertInlineJsonSize,
  assertStandardSourceContract,
  collectDiscoveryTargets,
  createSourceTestHarness,
  parseSourceTestArguments,
  probeReachableResource,
  runReadingSourceFlow,
} from '../index.js';

function fakePlugin(overrides = {}) {
  return {
    async activate() {},
    async discover() {
      return {
        kind: 'document',
        document: {
          components: [{
            type: 'section',
            children: [{
              type: 'contentCollection',
              items: [{ content: { id: 'novel:1' } }],
            }],
          }],
        },
      };
    },
    async search() { return { items: [{ id: 'novel:1' }] }; },
    async searchSuggestions() { return { items: [{ query: 'fixture' }] }; },
    async getDetail({ id }) { return { id, title: 'fixture', contentKind: 'novel' }; },
    async getChapters() { return { items: [{ id: 'chapter:1' }] }; },
    async getContent({ chapterId }) {
      return { chapterId, contentKind: 'novel', text: 'fixture', pages: [] };
    },
    ...overrides,
  };
}

test('asserts standard exports and package metadata with stable failures', () => {
  const plugin = fakePlugin();
  const result = assertStandardSourceContract({
    plugin,
    packageJson: {
      main: 'dist/index.mjs',
      mgread: {
        id: 'org.mgread.fixture',
        pluginApi: 1,
        packageMode: 'single-file',
        icon: 'assets/icon.png',
      },
    },
    pluginId: 'org.mgread.fixture',
    optionalExports: ['searchSuggestions'],
  });
  assert.equal(result.metadata.id, 'org.mgread.fixture');
  assert.throws(
    () => assertStandardSourceContract({
      plugin: { ...plugin, unexpected() {} },
      packageJson: {},
      pluginId: 'org.mgread.fixture',
      optionalExports: ['searchSuggestions'],
    }),
    (error) => error instanceof SourceTestFailure && error.code === 'source_contract_exports',
  );
});

test('creates an isolated host and records bounded resource metadata', async (t) => {
  let activatedContext;
  const harness = await createSourceTestHarness({
    plugin: fakePlugin({ async activate(context) { activatedContext = context; } }),
    pluginId: 'org.mgread.fixture',
    version: '1.0.0',
  });
  t.after(harness.cleanup);
  await access(harness.root);
  const projected = activatedContext.resource.proxy({
    kind: 'image',
    url: 'https://fixture.invalid/cover.webp',
    headers: { Accept: 'image/*' },
  });
  activatedContext.log.info('source_fixture_stage');
  assert.match(projected, /^http:\/\/127\.0\.0\.1:1234\//u);
  assert.deepEqual(harness.summary(), { resources: 1, logs: 1 });
  await harness.cleanup();
  await assert.rejects(access(harness.root));
});

test('resource probe skips a stale descriptor and reads only the first healthy chunk', async () => {
  const calls = [];
  const result = await probeReachableResource({
    requests: [
      { kind: 'image', url: 'https://fixture.invalid/stale.webp', headers: {} },
      { kind: 'image', url: 'https://fixture.invalid/healthy.webp', headers: {} },
    ],
    async fetch(url) {
      calls.push(url);
      return url.endsWith('stale.webp')
        ? new Response('missing', {
            status: 404,
            headers: { 'content-type': 'text/plain' },
          })
        : new Response(new Uint8Array([1, 2, 3]), {
            status: 200,
            headers: { 'content-type': 'image/webp' },
          });
    },
  });
  assert.equal(result.bytesRead, 3);
  assert.deepEqual(result.attempts.map((attempt) => attempt.status), [404, 200]);
  assert.equal(calls.length, 2);
});

test('resource failures expose statuses without echoing request URLs', async () => {
  await assert.rejects(
    probeReachableResource({
      requests: [{
        kind: 'image',
        url: 'https://private-fixture.invalid/cover.webp',
        headers: {},
      }],
      fetch: async () => new Response('missing', {
        status: 404,
        headers: { 'content-type': 'text/plain' },
      }),
    }),
    (error) => error instanceof SourceTestFailure
      && error.code === 'source_resource_unreachable'
      && error.summary.attempts[0].status === 404
      && !error.message.includes('private-fixture.invalid'),
  );
});

test('runs the standard reading chain and reports only bounded counts', async () => {
  const result = await runReadingSourceFlow({
    plugin: fakePlugin(),
    discoverRequest: {
      target: 'category:fixture',
      cursor: null,
      collectionId: null,
      pageSize: 5,
    },
    searchRequest: { query: 'fixture', cursor: null, pageSize: 5 },
    suggestionsRequest: { cursor: null, pageSize: 5 },
  });
  assert.deepEqual(result.summary, {
    discoveryItems: 1,
    searchItems: 1,
    suggestionItems: 1,
    chapterItems: 1,
    contentKind: 'novel',
    contentSamples: 1,
    contentUnits: 7,
  });

  await assert.rejects(
    runReadingSourceFlow({
      plugin: fakePlugin({ async getChapters() { return { items: [] }; } }),
      contentId: 'novel:1',
    }),
    (error) => error instanceof SourceTestFailure
      && error.code === 'source_chapters_empty'
      && error.stage === 'chapters',
  );
});

test('collects bounded discovery targets and parses one pure Node selection', () => {
  const targets = collectDiscoveryTargets({
    kind: 'document',
    document: {
      components: [{
        type: 'section',
        children: [
          { type: 'tabs', tabs: [{ target: 'tab:one' }, { target: 'tab:one' }] },
          { type: 'categoryCollection', categories: [{ target: 'category:one' }] },
        ],
      }],
    },
  });
  assert.deepEqual(targets, ['tab:one', 'category:one']);
  const options = parseSourceTestArguments(['--source', 'aisishuwu', '--skip-build'], {
    cwd: 'C:\\workspace',
  });
  assert.equal(options.source, 'aisishuwu');
  assert.equal(options.all, false);
  assert.equal(options.skipBuild, true);
});

test('checks inline JSON bytes without serializing a full diagnostic', () => {
  assert.equal(assertInlineJsonSize({ ok: true }, { maximumBytes: 32 }), 11);
  assert.throws(
    () => assertInlineJsonSize({ value: 'oversized' }, { maximumBytes: 4 }),
    (error) => error instanceof SourceTestFailure
      && error.code === 'source_inline_result_oversized',
  );
});
