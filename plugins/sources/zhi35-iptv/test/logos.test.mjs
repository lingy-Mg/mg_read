/** 台标修复回归：同源原图、精确目录回退、确认缺失、传输故障、限流缓存和各内容表面的一致性。 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { canonicalLogoUrl, createLogoResolver, parseLogoCatalog } from '../dist/logos.mjs';
import { parsePlaylist } from '../dist/playlist.mjs';
import * as plugin from '../dist/index.mjs';
import { collectDiscoveryContent } from '@mgread/source-testkit';
import { contextFixture, discoveryRequest } from './fixtures.mjs';

const original = 'https://tb.zbds.top/logo/%E5%8F%A5%E5%AE%B9%E7%94%9F%E6%B4%BB.png';
const fallback = 'https://upload.112114.xyz/logo/%E5%8F%A5%E5%AE%B9%E7%94%9F%E6%B4%BB.png';
const directory = '<html><a href="%E5%8F%A5%E5%AE%B9%E7%94%9F%E6%B4%BB.png">句容生活.png</a></html>';
const channel = (cover = original) => ({ id: 'channel:unchanged', title: '句容生活', name: '句容生活', cover, categories: ['地方频道'], streams: [] });
const imageHead = () => new Response(null, { headers: { 'content-type': 'image/png' } });

test('retired logo mirrors resolve to the same original repositories and preserve exact filenames', () => {
  assert.equal(canonicalLogoUrl('https://live.fanmingming.cn/tv/CCTV1.png'), 'https://raw.githubusercontent.com/fanmingming/live/main/tv/CCTV1.png');
  assert.equal(canonicalLogoUrl('https://live.fanmingming.com/tv/北京卫视.png'), 'https://raw.githubusercontent.com/fanmingming/live/main/tv/%E5%8C%97%E4%BA%AC%E5%8D%AB%E8%A7%86.png');
  assert.equal(canonicalLogoUrl('https://ghproxy.zhi35.com/https://raw.githubusercontent.com/wanglindl/TVlogo/main/img/TVB2.png'), 'https://raw.githubusercontent.com/wanglindl/TVlogo/main/img/TVB2.png');
  assert.equal(canonicalLogoUrl('https://ghproxy.zhi35.com/https://raw.githubusercontent.com/wanglindl/TVlogo/main/img/CTI3.pngg'), 'https://raw.githubusercontent.com/wanglindl/TVlogo/main/img/CTI3.png');
  assert.equal(canonicalLogoUrl('https://ghp.ci/raw.githubusercontent.com/suxuang/myIPTV/main/tvlog/直播中国.png'), 'https://raw.githubusercontent.com/suxuang/myIPTV/main/tvlog/%E7%9B%B4%E6%92%AD%E4%B8%AD%E5%9B%BD.png');
  assert.equal(canonicalLogoUrl('https://upload.112114.xyz/logo/TVBFEICUITAI.png'), 'https://upload.112114.xyz/logo/TVBFEICUITAI.png');
  assert.equal(canonicalLogoUrl('https://ghp.ci/https://evil.example/logo.png'), null);
  assert.equal(canonicalLogoUrl('https://ghproxy.zhi35.com/https://raw.githubusercontent.com/other/repo/main/a.png'), null);
  assert.equal(canonicalLogoUrl('https://ghproxy.zhi35.com/https://raw.githubusercontent.com/wanglindl/TVlogo/main/img/../secret.png'), null);
});

test('catalog accepts only declared same-origin PNG entries and never guesses similar channel names', () => {
  const parsed = parseLogoCatalog(`${directory}
<a href="句容生活2.png">other</a><a href="https://evil.example/logo/句容生活.png">bad</a>
<a href="../private.png">bad</a><a href="%2E%2E%2Fsecret.png">bad</a>
<a href="%0Aevil.png">bad</a><a href="cn/句容生活.png">nested</a><a href="javascript:evil.png">bad</a>`);
  assert.equal(parsed.size, 2);
  assert.equal(parsed.get('句容生活.png'), fallback);
  assert.equal(parsed.has('句容综合.png'), false);
  assert.throws(() => parseLogoCatalog('<html>challenge</html>'), /logo_catalog_empty/u);
});

test('working original logos are retained and HEAD/cached metadata do not read image bytes', async () => {
  let calls = 0;
  const resolver = createLogoResolver(contextFixture(async (url, init) => {
    calls += 1;
    assert.equal(url, original);
    assert.equal(init.method, 'HEAD');
    return imageHead();
  }).context);
  assert.equal((await resolver.prepare([channel()]))[0].cover, original);
  assert.equal((await resolver.prepare([channel()]))[0].cover, original);
  assert.equal(calls, 1);
});

test('404 logos recover only through a validated exact catalog URL and share in-flight/cache state', async () => {
  const requested = [];
  const resolver = createLogoResolver(contextFixture(async (url, init) => {
    requested.push({ url, method: init.method ?? 'GET' });
    if (url === original) return new Response(null, { status: 404 });
    if (url === fallback) return imageHead();
    assert.equal(url, 'https://upload.112114.xyz/logo/');
    return new Response(directory);
  }).context);
  const [first, second] = await Promise.all([resolver.prepare([channel()]), resolver.prepare([channel()])]);
  assert.equal(first[0].cover, fallback);
  assert.equal(second[0].id, channel().id);
  assert.equal(second[0].title, channel().title);
  assert.deepEqual(requested, [{ url: original, method: 'HEAD' }, { url: 'https://upload.112114.xyz/logo/', method: 'GET' }, { url: fallback, method: 'HEAD' }]);
  await resolver.prepare([channel()]);
  assert.equal(requested.length, 3);
});

test('confirmed missing logos return null without deleting channels or guessing station logos', async () => {
  const resolver = createLogoResolver(contextFixture(async (url) => url === 'https://upload.112114.xyz/logo/'
    ? new Response('<a href="句容生活2.png">similar</a>') : new Response(null, { status: 404 })).context);
  const result = await resolver.prepare([channel()]);
  assert.equal(result.length, 1);
  assert.equal(result[0].cover, null);
  assert.equal(result[0].id, 'channel:unchanged');
  assert.equal(result[0].title, '句容生活');
});

test('temporary transport failures preserve original URLs and expire the short cache', async () => {
  let time = 0, calls = 0;
  const resolver = createLogoResolver(contextFixture(async () => { calls += 1; throw new Error('TLS unavailable'); }).context, () => time);
  assert.equal((await resolver.prepare([channel()]))[0].cover, original);
  await resolver.prepare([channel()]);
  assert.equal(calls, 1);
  time = 60_001;
  assert.equal((await resolver.prepare([channel()]))[0].cover, original);
  assert.equal(calls, 2);
});

test('fallback HTML and oversized catalog responses are rejected and cancelled', async () => {
  let cancelled = false;
  const resolver = createLogoResolver(contextFixture(async (url) => {
    if (url === original) return new Response(null, { status: 404 });
    return new Response(new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array(3 * 1024 * 1024 + 1)); },
      cancel() { cancelled = true; },
    }));
  }).context);
  assert.equal((await resolver.prepare([channel()]))[0].cover, null);
  assert.equal(cancelled, true);
  const htmlResolver = createLogoResolver(contextFixture(async (url) => url === original
    ? new Response(null, { status: 404 }) : url === fallback
      ? new Response(null, { headers: { 'content-type': 'text/html' } }) : new Response(directory)).context);
  assert.equal((await htmlResolver.prepare([channel()]))[0].cover, null);
});

test('HEAD concurrency remains bounded across multiple simultaneously requested pages', async () => {
  let active = 0, maximum = 0;
  const resolver = createLogoResolver(contextFixture(async (_url, init) => {
    assert.equal(init.method, 'HEAD');
    active += 1;
    maximum = Math.max(maximum, active);
    await new Promise((resolve) => setTimeout(resolve, 2));
    active -= 1;
    return imageHead();
  }).context);
  await Promise.all(Array.from({ length: 3 }, (_, page) => resolver.prepare(Array.from({ length: 10 }, (_, index) => channel(`https://tb.zbds.top/logo/test-${page}-${index}.png`)))));
  assert.equal(maximum, 4);
});

test('discovery, search and detail register the same repaired upstream image and preserve content IDs', async () => {
  const text = '#EXTINF:-1 tvg-logo="https://live.fanmingming.cn/tv/CCTV1.png" group-title="央视频道",CCTV-1综合\nhttps://media.example/cctv1.m3u8';
  const fixture = contextFixture(async () => new Response(text));
  await plugin.activate(fixture.context);
  const root = collectDiscoveryContent(await plugin.discover(discoveryRequest));
  const search = await plugin.search({ query: root[0].title, cursor: null, pageSize: 20 });
  const detail = await plugin.getDetail({ id: root[0].id });
  assert.equal(root[0].id, parsePlaylist(text).channels[0].id);
  assert.equal(search.items[0].id, root[0].id);
  assert.equal(detail.id, root[0].id);
  assert.equal(fixture.resources.length, 3);
  assert.ok(fixture.resources.every((entry) => entry.kind === 'image' && entry.url === 'https://raw.githubusercontent.com/fanmingming/live/main/tv/CCTV1.png'));
});
