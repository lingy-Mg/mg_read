/** 数据源测试库自身的离线行为测试；不访问任何真实来源。 */
import assert from 'node:assert/strict';
import { createCipheriv } from 'node:crypto';
import { access, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  SourceTestFailure,
  assertInlineJsonSize,
  assertStandardSourceContract,
  collectDiscoveryContinuations,
  collectDiscoveryTargets,
  createSourceTestHarness,
  parseSourceTestArguments,
  probeReachableResource,
  probeResourceGroups,
  runReadingSourceFlow,
  runSourceProjects,
} from '../index.js';
import { createRuntimeLikeFetch } from '../src/http.js';

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
  const boundaries = [
    [() => webview.executeJavaScript('return document.title;'), 'source_webview_script_unsupported', 'webview.evaluate'],
    [() => webview.cdp('Page.enable'), 'source_webview_cdp_unsupported', 'webview.cdp'],
    [() => webview.click({ x: 1, y: 1 }), 'source_webview_interaction_required', 'webview.click'],
    [() => webview.inputText('fixture'), 'source_webview_interaction_required', 'webview.inputText'],
    [() => webview.key({ key: 'Enter' }), 'source_webview_interaction_required', 'webview.key'],
    [() => webview.waitForText({ text: 'ready', timeoutMs: 1_000 }), 'source_webview_wait_unsupported', 'webview.waitText'],
    [() => webview.show(), 'source_webview_interaction_required', 'webview.show'],
  ];
  for (const [operation, code, stage] of boundaries) {
    await assert.rejects(
      operation,
      (error) => error instanceof SourceTestFailure && error.code === code && error.stage === stage,
    );
  }
  await harness.cleanup();
  await assert.rejects(access(harness.root));
});

test('reports a temporary WebView capability boundary as partial', async (t) => {
  const repositoryRoot = await mkdtemp(join(tmpdir(), 'mgread-source-report-'));
  t.after(() => rm(repositoryRoot, { force: true, recursive: true }));
  const projectRoot = join(repositoryRoot, 'plugins', 'sources', 'fixture-webview');
  await mkdir(join(projectRoot, 'dist'), { recursive: true });
  await writeFile(join(projectRoot, 'package.json'), JSON.stringify({
    name: '@fixture/webview',
    version: '1.0.0',
    type: 'module',
    main: 'dist/index.mjs',
    mgread: {
      id: 'org.mgread.fixture-webview',
      displayName: 'Fixture WebView',
      pluginApi: 1,
      packageMode: 'single-file',
      icon: 'assets/icon.png',
      contentKinds: ['video'],
    },
  }), 'utf8');
  await writeFile(join(projectRoot, 'dist', 'index.mjs'), `
    let context;
    export async function activate(value) { context = value; }
    export async function discover() {
      const page = await context.webview.open();
      await page.executeJavaScript('return document.title;');
    }
    export async function search() { return { items: [] }; }
    export async function getDetail() { return {}; }
    export async function getChapters() { return { items: [] }; }
    export async function getContent() { return {}; }
  `, 'utf8');

  const report = await runSourceProjects({
    all: false,
    source: 'fixture-webview',
    repositoryRoot,
    reportPath: null,
    skipBuild: true,
  });
  assert.equal(report.status, 'failed');
  assert.deepEqual(report.totals, { sources: 1, passed: 0, partial: 1, failed: 0 });
  assert.equal(report.sources[0].status, 'partial');
  assert.deepEqual(report.sources[0].limitation, {
    kind: 'testkitWebViewCapability',
    capability: 'javascriptEvaluation',
    code: 'source_webview_script_unsupported',
    stage: 'webview.evaluate',
    summary: {},
  });
  assert.equal('failure' in report.sources[0], false);
});

test('runtime-like fetch routes direct requests outside the configured fetch', async () => {
  const calls = [];
  const runtimeFetch = createRuntimeLikeFetch(
    async (_input, init) => { calls.push({ route: 'configured', init }); return new Response('configured'); },
    { directFetch: async (_input, init) => { calls.push({ route: 'direct', init }); return new Response('direct'); } },
  );
  assert.equal(await (await runtimeFetch('https://fixture.invalid/configured')).text(), 'configured');
  assert.equal(await (await runtimeFetch('https://fixture.invalid/direct', { proxyMode: 'direct' })).text(), 'direct');
  assert.deepEqual(calls.map(({ route }) => route), ['configured', 'direct']);
  assert.ok(calls.every(({ init }) => init.proxyMode === undefined));
  assert.ok(calls.every(({ init }) => new Headers(init.headers).get('user-agent')?.startsWith('Mozilla/5.0')));
});

test('browser session retains host cookies between source requests', async (t) => {
  const requestHeaders = [];
  const harness = await createSourceTestHarness({
    plugin: fakePlugin(),
    pluginId: 'org.mgread.fixture',
    version: '1.0.0',
    async fetch(input, init) {
      requestHeaders.push(new Headers(init?.headers));
      return String(input).endsWith('/set-cookie')
        ? new Response('session-started', { headers: { 'set-cookie': 'sid=fixture; Path=/' } })
        : new Response('session-continued');
    },
  });
  t.after(harness.cleanup);
  const request = harness.context.browser.sessionV1.request;
  const base = {
    version: 1,
    sessionKey: 'fixture-session',
    method: 'GET',
    headers: {},
    body: null,
    interaction: 'silent',
    presentation: 'hidden',
    transport: 'http',
    timeoutMs: 5_000,
    maxResponseBytes: 1_024,
  };
  await request({ ...base, url: 'https://fixture.invalid/set-cookie' });
  await request({ ...base, url: 'https://fixture.invalid/session' });
  assert.equal(requestHeaders[1].get('cookie'), 'sid=fixture');
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

test('resource probe verifies Node-side transformed image descriptors', async () => {
  const encrypt = (body) => {
    const cipher = createCipheriv('aes-128-cbc', Buffer.from('aaaaaaaaaaaaaaaa'), Buffer.from('0123456789aaaaaa'));
    return Buffer.concat([cipher.update(body), cipher.final()]);
  };
  const parts = new Map([
    ['https://fixture.invalid/image.b_0', new Response(encrypt(new Uint8Array([0, 0, 0, 1, 0, 0, 0, 1, 74, 70, 73, 70, 0, 1, 2])))],
    ['https://fixture.invalid/image.b_1', new Response(encrypt(new Uint8Array([3, 4, 5])))],
  ]);
  const result = await probeReachableResource({
    requests: [{
      kind: 'image', url: 'https://fixture.invalid/image.b_0', urls: [...parts.keys()],
      resourceTransform: 'aes-cbc-split-image-v1', headers: {},
    }],
    fetch: async (url) => parts.get(String(url)),
  });
  assert.equal(result.contentType, 'image/jpeg');
  assert.ok(result.bytesRead > 0);
});

test('resource probe decodes AES-256-CBC images with a prefixed IV', async () => {
  const key = Buffer.from('0123456789abcdef0123456789abcdef');
  const iv = Buffer.from('abcdefghijklmnop');
  const plain = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
  const cipher = createCipheriv('aes-256-cbc', key, iv);
  const encrypted = Buffer.concat([iv, cipher.update(plain), cipher.final()]);
  const result = await probeReachableResource({
    requests: [{
      kind: 'image',
      url: 'https://fixture.invalid/encrypted.jpg',
      resourceTransform: 'aes-cbc-prefixed-iv-image-v1',
      resourceTransformKey: key.toString('ascii'),
      headers: {},
    }],
    fetch: async () => new Response(encrypted, { headers: { 'content-type': 'image/jpeg' } }),
  });
  assert.equal(result.contentType, 'image/jpeg');
  assert.ok(result.bytesRead > 0);
});

test('resource probe joins encrypt-then-split AES-CBC images before decrypting', async () => {
  const key = Buffer.from('aaaaaaaaaaaaaaaa');
  const iv = Buffer.from('0123456789aaaaaa');
  const plain = Buffer.from([0, 0, 0, 1, 0, 0, 0, 1, 74, 70, 73, 70, 1, 2, 3]);
  const cipher = createCipheriv('aes-128-cbc', key, iv);
  const encrypted = Buffer.concat([cipher.update(plain), cipher.final()]);
  const urls = ['https://fixture.invalid/manifest-0', 'https://fixture.invalid/manifest-1'];
  const parts = new Map([[urls[0], encrypted.subarray(0, 13)], [urls[1], encrypted.subarray(13)]]);
  const result = await probeReachableResource({
    requests: [{
      kind: 'image', url: urls[0], urls,
      resourceTransform: 'aes-cbc-encrypt-then-split-image-v1', headers: {},
    }],
    fetch: async (url) => new Response(parts.get(String(url))),
  });
  assert.equal(result.contentType, 'image/jpeg');
  assert.ok(result.bytesRead > 0);
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
    fetch: async (url) => new Response(new Uint8Array(url.endsWith('cover.jpg')
      ? [0xff, 0xd8, 0xff]
      : [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), {
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

test('requires every sampled manga chapter and page position to pass', async () => {
  const groups = await probeResourceGroups({
    requests: [
      { kind: 'image', url: 'https://fixture.invalid/chapter-1-page-1.jpg', projectedUrl: 'proxy:c1p1' },
      { kind: 'image', url: 'https://fixture.invalid/chapter-2-page-1.jpg', projectedUrl: 'proxy:c2p1' },
    ],
    detail: { contentKind: 'manga' },
    contents: [
      { contentKind: 'manga', pages: [{ url: 'proxy:c1p1' }] },
      { contentKind: 'manga', pages: [{ url: 'proxy:c2p1' }] },
    ],
    contentKind: 'manga',
    fetch: async (url) => url.includes('chapter-1')
      ? new Response(new Uint8Array([0xff, 0xd8, 0xff]), { headers: { 'content-type': 'image/jpeg' } })
      : new Response('missing', { status: 404, headers: { 'content-type': 'text/plain' } }),
  });
  assert.equal(groups.comicImages.status, 'failed');
  assert.deepEqual(
    groups.comicImages.surfaces.map((surface) => surface.status),
    ['passed', 'failed'],
  );
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
      ? new Response(new Uint8Array([0xff, 0xd8, 0xff]), { headers: { 'content-type': 'image/jpeg' } })
      : new Response('denied', { status: 403, headers: { 'content-type': 'text/plain' } }),
  });
  assert.equal(groups.cover.status, 'passed');
  assert.equal(groups.audio.status, 'failed');
  assert.equal(groups.video.status, 'notTested');
});

test('keeps discovery cover surfaces independent from a healthy detail cover', async () => {
  const groups = await probeResourceGroups({
    requests: [
      { kind: 'image', url: 'https://fixture.invalid/broken.jpg', projectedUrl: 'proxy:broken' },
      { kind: 'image', url: 'https://fixture.invalid/detail.jpg', projectedUrl: 'proxy:detail' },
    ],
    detail: { contentKind: 'novel', coverUrl: 'proxy:detail' },
    discoverySurfaces: [
      { name: 'discover.root', items: [{ id: 'novel:1', coverUrl: 'proxy:broken' }] },
      { name: 'discover.target.1', items: [{ id: 'novel:2', coverUrl: null }] },
    ],
    fetch: async (url) => url.endsWith('detail.jpg')
      ? new Response(new Uint8Array([0xff, 0xd8, 0xff]), { headers: { 'content-type': 'image/jpeg' } })
      : new Response('missing', { status: 404, headers: { 'content-type': 'text/plain' } }),
  });
  assert.equal(groups.cover.status, 'failed');
  assert.deepEqual(
    groups.cover.surfaces.map((surface) => [surface.name, surface.status]),
    [
      ['discover.root', 'failed'],
      ['discover.target.1', 'notRegistered'],
      ['detail', 'passed'],
    ],
  );
});

test('rejects mismatched image signatures and accepts an HLS playlist prefix', async () => {
  const imageGroups = await probeResourceGroups({
    requests: [{ kind: 'image', url: 'https://fixture.invalid/cover.png', projectedUrl: 'proxy:cover' }],
    detail: { contentKind: 'novel', coverUrl: 'proxy:cover' },
    fetch: async () => new Response(new Uint8Array([0xff, 0xd8, 0xff]), {
      headers: { 'content-type': 'image/png' },
    }),
  });
  assert.equal(imageGroups.cover.status, 'failed');

  const videoGroups = await probeResourceGroups({
    requests: [{ kind: 'hls', url: 'https://fixture.invalid/master.m3u8', projectedUrl: 'proxy:hls' }],
    detail: { contentKind: 'video' },
    contents: [{ contentKind: 'video', media: { url: 'proxy:hls' } }],
    contentKind: 'video',
    fetch: async () => new Response('#EXTM3U\n#EXT-X-VERSION:3\n', {
      headers: { 'content-type': 'application/vnd.apple.mpegurl' },
    }),
  });
  assert.equal(videoGroups.video.status, 'passed');
});

test('accepts a live MP3 chunk that starts inside a frame', async () => {
  const body = new Uint8Array(7 + 192 * 2);
  body.set([0xff, 0xfb, 0x54, 0x00], 7);
  body.set([0xff, 0xfb, 0x54, 0x00], 7 + 192);
  const groups = await probeResourceGroups({
    requests: [{ kind: 'audio', url: 'https://fixture.invalid/live.mp3', projectedUrl: 'proxy:audio' }],
    detail: { contentKind: 'audio' },
    contents: [{ contentKind: 'audio', media: { url: 'proxy:audio' } }],
    contentKind: 'audio',
    fetch: async () => new Response(body, { headers: { 'content-type': 'audio/mpeg' } }),
  });
  assert.equal(groups.audio.status, 'passed');
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
      async getChapters() {
        const chapter = { id: 'chapter:1', order: 0, isLocked: false };
        return { items: [chapter], groups: [{ id: 'group:1', order: 0, episodes: [chapter] }] };
      },
      async getContent({ chapterId }) {
        return {
          chapterId,
          contentKind: 'video',
          text: null,
          pages: [],
          media: { resourceType: 'video', url: 'http://127.0.0.1:1234/v1/source-resource/fixture' },
        };
      },
    }),
    contentId: 'video:1',
  });

  assert.equal(result.summary.contentKind, 'video');
  assert.equal(result.summary.contentUnits, 1);
});

test('requires audio and video groups to match the flat catalog', async () => {
  await assert.rejects(
    runReadingSourceFlow({
      plugin: fakePlugin({
        async getDetail({ id }) { return { id, title: 'fixture', contentKind: 'audio' }; },
        async getChapters() {
          return {
            items: [{ id: 'track:1', order: 0, isLocked: false }],
            groups: [{ id: 'group:1', order: 0, episodes: [] }],
          };
        },
      }),
      contentId: 'audio:1',
    }),
    (error) => error instanceof SourceTestFailure
      && error.code === 'source_media_groups_invalid'
      && error.stage === 'chapters',
  );
});

test('requires search to recover the discovered stable ID', async () => {
  await assert.rejects(
    runReadingSourceFlow({
      plugin: fakePlugin({ async search() { return { items: [{ id: 'novel:other' }] }; } }),
      contentId: 'novel:1',
      searchRequest: { query: 'fixture', cursor: null, pageSize: 5 },
    }),
    (error) => error instanceof SourceTestFailure
      && error.code === 'source_search_identity_missing'
      && error.stage === 'search',
  );
});

test('tries bounded search query candidates until the stable ID is recovered', async () => {
  const queries = [];
  const result = await runReadingSourceFlow({
    plugin: fakePlugin({
      async search({ query }) {
        queries.push(query);
        return { items: [{ id: query === 'fixture' ? 'novel:1' : 'novel:other' }] };
      },
    }),
    contentId: 'novel:1',
    searchRequest: [
      { query: '《Fixture：副标题》', cursor: null, pageSize: 5 },
      { query: 'fixture', cursor: null, pageSize: 5 },
    ],
  });
  assert.equal(result.selectedId, 'novel:1');
  assert.deepEqual(queries, ['《Fixture：副标题》', 'fixture']);
});

test('samples only unlocked chapters', async () => {
  const requested = [];
  const result = await runReadingSourceFlow({
    plugin: fakePlugin({
      async getChapters() {
        return {
          items: [
            { id: 'chapter:locked', order: 0, isLocked: true },
            { id: 'chapter:open', order: 1, isLocked: false },
          ],
        };
      },
      async getContent({ chapterId }) {
        requested.push(chapterId);
        return { chapterId, contentKind: 'novel', text: 'fixture', pages: [] };
      },
    }),
    contentId: 'novel:1',
  });
  assert.equal(result.summary.contentSamples, 1);
  assert.deepEqual(requested, ['chapter:open']);
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
  const continuations = collectDiscoveryContinuations({
    kind: 'document',
    document: {
      components: [{
        type: 'contentCollection',
        id: 'collection:one',
        items: [],
        continuation: { target: 'category:one', cursor: 'page:2' },
      }],
    },
  });
  assert.deepEqual(continuations, [{ collectionId: 'collection:one', target: 'category:one', cursor: 'page:2' }]);
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

test('verification negotiates and traverses deferred lines without treating grouped order as flat', async () => {
  const requests = [];
  const a = { id: 'a1', order: 0 };
  const b = { id: 'b1', order: 0 };
  const plugin = fakePlugin({ deferredGroups: true,
    async getDetail({ id }) { return { id, title: 'fixture', contentKind: 'video' }; },
    async getChapters(request) {
      requests.push(request);
      return { items: request.groupId ? [b] : [a], groups: [
        { id: 'a', order: 0, episodes: request.groupId ? [] : [a], deferred: !!request.groupId },
        { id: 'b', order: 1, episodes: request.groupId ? [b] : [], deferred: !request.groupId },
      ] };
    },
    async getContent({ chapterId }) { return { chapterId, contentKind: 'video', text: null, pages: [], media: { resourceType: 'hls' } }; },
  });
  const result = await runReadingSourceFlow({ plugin, contentId: 'novel:1' });
  assert.equal(result.summary.chapterItems, 2);
  assert.deepEqual(requests, [{ id: 'novel:1', supportsDeferredGroups: true }, { id: 'novel:1', groupId: 'b', supportsDeferredGroups: true }]);
});
