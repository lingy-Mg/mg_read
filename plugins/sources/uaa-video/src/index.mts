/**
 * UAA 视频数据源。
 *
 * 职责：把 UAA 官方地址页发布的镜像 API 转换为搜索、发现、详情、单集目录与视频播放投影。
 * 生命周期：activate 仅保存宿主公开上下文并重置请求节流；所有网络访问发生在 Source 调用期间。
 * IO：JSON 由 ctx.http 获取；视频主体只登记到 ctx.resource.proxy，不在插件中读取、缓存或持久化。
 * 状态所有权：插件只持有当前宿主上下文和 300ms 请求节流状态，不保存标题、查询、媒体地址或凭据。
 * 注意：稳定 ID 不包含镜像域名或随机 viewId；媒体地址使用 sessionOnly，每次播放均重新解析。
 */
import type { MgReadPluginContext } from '@mgread/source-api';

type Json = Record<string, unknown>;
type Context = MgReadPluginContext;
type Channel = {
  readonly id: string;
  readonly title: string;
  readonly path: 'rank' | 'search';
  readonly parameters: Readonly<Record<string, string>>;
};
type PageProjection = {
  readonly items: readonly Json[];
  readonly currentPage: number;
  readonly totalCount: number | null;
  readonly totalPage: number | null;
};

const mainOrigin = 'https://www.uaa.com';
const apiOrigin = 'https://www.uaa001.com';
const apiRoot = apiOrigin + '/api/video/app/video/';
const minimumDelayMs = 300;
const headers = Object.freeze({
  Accept: 'application/json,text/plain,*/*',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  Referer: mainOrigin + '/video/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
});
const channels = Object.freeze<Channel[]>([
  { id: 'latest', title: '最新', path: 'search', parameters: { category: '', orderType: '1', searchType: '1' } },
  { id: 'view-ranking', title: '观看排行', path: 'search', parameters: { category: '', orderType: '3', searchType: '1' } },
  { id: 'favorite-ranking', title: '收藏排行', path: 'search', parameters: { category: '', orderType: '4', searchType: '1' } },
  { id: 'china', title: '国产视频', path: 'search', parameters: { orderType: '1', origin: '1', searchType: '1' } },
  { id: 'japan', title: '日本AV', path: 'search', parameters: { orderType: '1', origin: '2', searchType: '1' } },
  { id: 'anime', title: 'H动漫', path: 'search', parameters: { orderType: '1', origin: '3', searchType: '1' } },
  { id: 'private', title: '自拍偷拍', path: 'search', parameters: { category: '自拍偷拍', orderType: '1', searchType: '1' } },
  { id: 'streamer', title: '主播福利', path: 'search', parameters: { category: '主播福利', orderType: '1', searchType: '1' } },
  { id: 'weekly', title: '周榜', path: 'rank', parameters: { type: '1' } },
  { id: 'monthly', title: '月榜', path: 'rank', parameters: { type: '2' } },
]);

let context: Context | undefined;
let throttleTail: Promise<void> = Promise.resolve();
let earliestRequestAt = 0;

export async function activate(next: Context): Promise<void> {
  context = next;
  throttleTail = Promise.resolve();
  earliestRequestAt = 0;
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim();
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, 'search');
  const size = clampPageSize(request.pageSize);
  const result = await fetchPage('search', {
    category: '',
    keyword: query,
    orderType: '1',
    page: String(page),
    searchType: '1',
    size: String(size),
  });
  const items = summaries(result.items).slice(0, size);
  return frozen({
    items,
    nextCursor: hasNextPage(result, page, items.length, size) ? 'search:' + (page + 1) : null,
    totalCount: result.totalCount,
  });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function discover(request: {
  target: string | null;
  cursor: string | null;
  collectionId: string | null;
  pageSize: number;
}) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    return rootDocument(request.pageSize);
  }
  const channel = channelForTarget(request.target);
  const page = cursorPage(request.cursor, 'channel:' + channel.id);
  const size = clampPageSize(request.pageSize);
  const result = await fetchPage(channel.path, {
    ...channel.parameters,
    page: String(page),
    size: String(size),
  });
  const values = summaries(result.items).slice(0, size);
  const collectionId = 'video:' + channel.id;
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const continuation = hasNextPage(result, page, values.length, size)
    ? frozen({ target: request.target, cursor: 'channel:' + channel.id + ':' + (page + 1) })
    : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({
    kind: 'document' as const,
    document: {
      components: [{
        type: 'section',
        id: collectionId + ':section',
        title: channel.title,
        subtitle: null,
        icon: channel.path === 'rank' ? 'ranking' : 'video',
        children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
      }],
    },
  });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id);
  const model = await fetchIntro(id);
  const item = summary(model, id);
  return frozen({ ...item, aliases: stringList(model.titleAlias, 64), catalogUrl: stableIntroUrl(id) });
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const model = await fetchIntro(id);
  const item = summary(model, id);
  const episode = frozen({
    id: chapterId(id),
    title: '正片',
    order: 0,
    url: stableIntroUrl(id),
    volumeTitle: '默认线路',
    wordCount: null,
    updatedAt: item.updatedAt,
    isLocked: null,
    attributes: durationAttributes(model),
  });
  const group = frozen({ id: 'group:' + id + ':main', title: '默认线路', order: 0, episodes: [episode] });
  return frozen({ items: [episode], groups: [group] });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id);
  if (request.chapterId !== chapterId(id)) throw new Error('Chapter ID is invalid.');
  const model = await fetchIntro(id);
  const upstream = plainText(model.url);
  if (!safeMediaUrl(upstream)) throw new Error('Playback address is unavailable.');
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video';
  const mediaHeaders = { Referer: apiOrigin + '/video/', 'User-Agent': headers['User-Agent'] };
  return frozen({
    chapterId: request.chapterId,
    contentKind: 'video',
    title: nullableText(model.title),
    updatedAt: timestamp(model.updateTime),
    text: null,
    pages: [],
    media: {
      url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }),
      resourceType,
      resourcePolicy: 'sessionOnly',
      expiresAt: null,
      mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4',
      headers: mediaHeaders,
    },
  });
}

async function rootDocument(pageSize: number) {
  const size = Math.min(clampPageSize(pageSize), 10);
  const latest = channels[0];
  if (latest === undefined) throw new Error('Source channels are unavailable.');
  const result = await fetchPage(latest.path, { ...latest.parameters, page: '1', size: String(size) });
  const values = summaries(result.items).slice(0, size);
  const items = values.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
  const components: object[] = [];
  if (items.length > 0) {
    components.push({
      type: 'section',
      id: 'video-latest',
      title: '最新视频',
      subtitle: null,
      icon: 'newRelease',
      children: [{ type: 'contentCollection', id: 'video-latest-list', layout: 'coverGrid', items, continuation: null }],
    });
  }
  components.push({
    type: 'section',
    id: 'video-channels',
    title: '视频频道',
    subtitle: null,
    icon: 'video',
    children: [{
      type: 'categoryCollection',
      id: 'video-channel-list',
      layout: 'chips',
      categories: channels.map((channel) => ({
        id: channel.id,
        title: channel.title,
        target: 'channel:' + channel.id,
        count: null,
        url: null,
        icon: channel.path === 'rank' ? 'ranking' : 'video',
      })),
    }],
  });
  return frozen({ kind: 'document' as const, document: { components } });
}

async function fetchIntro(id: string): Promise<Json> {
  const response = await fetchJson('intro', { force: 'false', id, viewId: createViewId() });
  return object(response.model);
}

async function fetchPage(path: 'rank' | 'search', parameters: Readonly<Record<string, string>>): Promise<PageProjection> {
  const response = await fetchJson(path, parameters);
  const model = response.model;
  if (Array.isArray(model)) {
    return frozen({ items: model.filter(isObject), currentPage: 1, totalCount: null, totalPage: null });
  }
  const value = object(model);
  return frozen({
    items: records(value.data),
    currentPage: positiveInteger(value.currentPage) ?? 1,
    totalCount: nonNegativeInteger(value.totalCount),
    totalPage: positiveInteger(value.totalPage),
  });
}

async function fetchJson(path: string, parameters: Readonly<Record<string, string>>): Promise<Json> {
  const response = await throttledFetch(apiUrl(path, parameters));
  if (!response.ok) throw new Error('Source request failed.');
  let value: unknown;
  try {
    value = JSON.parse(await response.text());
  } catch {
    throw new Error('Source response is invalid.');
  }
  if (!isObject(value) || value.result !== 'success') throw new Error('Source response indicates failure.');
  return value;
}

async function throttledFetch(url: string): Promise<Response> {
  let release = (): void => undefined;
  const previous = throttleTail;
  throttleTail = new Promise<void>((resolve) => { release = resolve; });
  await previous;
  try {
    const delay = Math.max(0, earliestRequestAt - Date.now());
    if (delay > 0) await new Promise<void>((resolve) => setTimeout(resolve, delay));
    earliestRequestAt = Date.now() + minimumDelayMs;
    return await requireContext().http.fetch(url, { headers });
  } finally {
    release();
  }
}

function summaries(values: readonly Json[]) {
  const unique = new Map<string, ReturnType<typeof summary>>();
  for (const value of values) {
    const id = sourceId(value.id ?? value.videoId);
    if (id === null || nullableText(value.title) === null) continue;
    unique.set(id, summary(value, id));
  }
  return [...unique.values()];
}

function summary(value: Json, id: string) {
  const title = nullableText(value.title);
  if (title === null) throw new Error('Source item has no title.');
  const updatedAt = timestamp(value.updateTime);
  const author = nullableText(value.authors) ?? nullableText(value.author) ?? nullableText(value.uploader);
  return frozen({
    id: 'video:' + id,
    title,
    contentKind: 'video',
    author,
    url: stableIntroUrl(id),
    coverUrl: absolute(nullableText(value.coverUrl) ?? nullableText(value.cover)),
    description: nullableText(value.brief) ?? nullableText(value.description),
    language: 'zh-CN',
    status: 'unknown',
    access: 'unknown',
    wordCount: null,
    chapterCount: 1,
    publishedAt: timestamp(value.onlineTime),
    updatedAt,
    latestChapter: { id: chapterId(id), title: '正片', updatedAt, url: stableIntroUrl(id) },
    categories: stringList(value.categories, 32),
    tags: stringList(value.tags, 64),
    attributes: durationAttributes(value),
  });
}

function durationAttributes(value: Json) {
  const duration = nullableText(value.durationFormat);
  return duration === null ? [] : [frozen({ key: 'duration', label: '时长', value: duration })];
}

function channelForTarget(target: string) {
  const id = /^channel:([a-z0-9-]+)$/u.exec(target)?.[1];
  const channel = channels.find((value) => value.id === id);
  if (channel === undefined) throw new Error('Discovery target is invalid.');
  return channel;
}

function cursorPage(cursor: string | null, prefix: string) {
  if (cursor === null) return 1;
  const value = Number(new RegExp('^' + escape(prefix) + ':(\\d+)$', 'u').exec(cursor)?.[1]);
  if (!Number.isSafeInteger(value) || value < 2 || value > 10_000) throw new Error('Source cursor is invalid.');
  return value;
}

function hasNextPage(result: PageProjection, requestedPage: number, itemCount: number, pageSize: number) {
  if (result.totalPage !== null) return requestedPage < result.totalPage;
  return itemCount >= pageSize && requestedPage < 10_000;
}

function apiUrl(path: string, parameters: Readonly<Record<string, string>>) {
  const url = new URL(path, apiRoot);
  for (const [key, value] of Object.entries(parameters)) url.searchParams.set(key, value);
  return url.toString();
}

function stableIntroUrl(id: string) {
  return apiUrl('intro', { force: 'false', id });
}

function createViewId() {
  return String(Date.now()) + String(Math.floor(Math.random() * 9_000 + 1_000));
}

function chapterId(id: string) {
  return 'video:' + id + ':main';
}

function contentId(id: string) {
  const value = /^video:(\d+)$/u.exec(id)?.[1];
  if (value === undefined) throw new Error('Content ID is invalid.');
  return value;
}

function sourceId(value: unknown) {
  const id = plainText(value);
  return /^\d+$/u.test(id) ? id : null;
}

function stringList(value: unknown, limit: number) {
  const raw = Array.isArray(value) ? value.map(plainText) : plainText(value).split(/[,，|/]+/u);
  return [...new Set(raw.map((entry) => entry.trim()).filter((entry) => entry !== '').map((entry) => entry.slice(0, 256)))].slice(0, limit);
}

function timestamp(value: unknown) {
  const raw = plainText(value);
  if (raw === '') return null;
  const milliseconds = Date.parse(raw);
  return Number.isNaN(milliseconds) ? null : new Date(milliseconds).toISOString();
}

function safeMediaUrl(value: string) {
  try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
  } catch {
    return false;
  }
}

function absolute(value: string | null) {
  if (value === null) return null;
  try {
    const url = new URL(value.replaceAll('\\/', '/'), apiOrigin);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '' ? url.toString() : null;
  } catch {
    return null;
  }
}

function clampPageSize(value: number) {
  return Math.max(1, Math.min(50, Math.floor(value)));
}

function positiveInteger(value: unknown) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : null;
}

function nonNegativeInteger(value: unknown) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number >= 0 ? number : null;
}

function nullableText(value: unknown) {
  const result = plainText(value);
  return result === '' ? null : result;
}

function plainText(value: unknown) {
  return typeof value === 'string' ? value.replace(/\s+/gu, ' ').trim() : typeof value === 'number' ? String(value) : '';
}

function records(value: unknown): Json[] {
  return Array.isArray(value) ? value.filter(isObject) : [];
}

function object(value: unknown): Json {
  if (!isObject(value)) throw new Error('Source response model is invalid.');
  return value;
}

function isObject(value: unknown): value is Json {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function frozen<T>(value: T): T {
  return Object.freeze(value);
}

function escape(value: string) {
  return value.replace(/[\\^$.*+?()[\]{}|]/gu, '\\$&');
}

function requireContext(): Context {
  if (context === undefined) throw new Error('Source is not activated.');
  return context;
}
