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
  probeResourceGroups,
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
  const fetchHeaders = [];
  const harness = await createSourceTestHarness({
    plugin: fakePlugin({ async activate(context) { activatedContext = context; } }),
    pluginId: 'org.mgread.fixture',
    version: '1.0.0',
    async fetch(_input, init) {
      fetchHeaders.push(new Headers(init?.headers));
      return new Response('ok');
    },
  });
  t.after(harness.cleanup);
  await access(harness.root);
  const projected = activatedContext.resource.proxy({
    kind: 'image',
    url: 'https://fixture.invalid/cover.webp',
    headers: { Accept: 'image/*' },
  });
  activatedContext.log.info('source_fixture_stage');
  await activatedContext.http.fetch('https://fixture.invalid/default');
  await activatedContext.http.fetch('https://fixture.invalid/custom', {
    headers: { 'User-Agent': 'source-specific' },
  });
  assert.match(projected, /^http:\/\/127\.0\.0\.1:1234\//u);
  assert.match(fetchHeaders[0].get('user-agent'), /^Mozilla\/5\.0/u);
  assert.equal(fetchHeaders[1].get('user-agent'), 'source-specific');
  assert.deepEqual(harness.summary(), { resources: 1, logs: 1 });
  const webview = await activatedContext.webview.open();
  await assert.rejects(
    webview.show(),
    (error) => error instanceof SourceTestFailure && error.code === 'source_webview_interaction_required',
  );
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
    async fetch(url, init) {
      calls.push({ url, userAgent: new Headers(init?.headers).get('user-agent') });
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
  assert.ok(calls.every((call) => call.userAgent?.startsWith('Mozilla/5.0')));
});

test('resource failures expose statuses and request URLs', async () => {
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
      && error.message.includes('private-fixture.invalid'),
  );
});

test('probes cover and comic image groups independently', async () => {
  const groups = await probeResourceGroups({
    requests: [
      { kind: 'image', url: 'https://fixture.invalid/cover.jpg', projectedUrl: 'proxy:cover' },
      { kind: 'image', url: 'https://fixture.invalid/page-1.jpg', projectedUrl: 'proxy:page-1' },
    ],
    detail: { contentKind: 'manga', coverUrl: 'proxy:cover' },
    contents: [{
      contentKind: 'manga',
      pages: [{ url: 'proxy:page-1' }],
    }],
    contentKind: 'manga',
    fetch: async (url) => new Response(new Uint8Array([1, 2, 3]), {
      status: 200,
      headers: { 'content-type': url.endsWith('cover.jpg') ? 'image/jpeg' : 'image/png' },
    }),
  });
  assert.equal(groups.cover.status, 'passed');
  assert.equal(groups.comicImages.status, 'passed');
  assert.equal(groups.audio.status, 'notTested');
  assert.equal(groups.video.status, 'notTested');
  assert.equal(groups.cover.candidates, 1);
  assert.equal(groups.comicImages.candidates, 1);
});

test('marks an applicable media group failed without masking the cover result', async () => {
  const groups = await probeResourceGroups({
    requests: [
      { kind: 'image', url: 'https://fixture.invalid/cover.jpg', projectedUrl: 'proxy:cover' },
      { kind: 'audio', url: 'https://fixture.invalid/audio.mp3', projectedUrl: 'proxy:audio' },
    ],
    detail: { contentKind: 'audio', coverUrl: 'proxy:cover' },
    contents: [{ contentKind: 'audio', media: { url: 'proxy:audio' } }],
    contentKind: 'audio',
    fetch: async (url) => url.endsWith('cover.jpg')
      ? new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/jpeg' } })
      : new Response('denied', { status: 403, headers: { 'content-type': 'text/plain' } }),
  });
  assert.equal(groups.cover.status, 'passed');
  assert.equal(groups.audio.status, 'failed');
  assert.equal(groups.video.status, 'notTested');
});

test('runs the standard reading chain and reports complete results', async () => {
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
  assert.equal(result.detail.title, 'fixture');
  assert.equal(result.content.text, 'fixture');
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

test('counts a Runtime-style media body even when its pages collection is empty', async () => {
  const result = await runReadingSourceFlow({
    plugin: fakePlugin({
      async getDetail({ id }) {
        return { id, title: 'fixture', contentKind: 'video' };
      },
      async getContent({ chapterId }) {
        return {
          chapterId,
          contentKind: 'video',
          text: null,
          pages: [],
          media: { type: 'video', url: 'http://127.0.0.1:1234/v1/source-resource/fixture' },
        };
      },
    }),
    contentId: 'video:1',
  });

  assert.equal(result.summary.contentKind, 'video');
  assert.equal(result.summary.contentUnits, 1);
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
