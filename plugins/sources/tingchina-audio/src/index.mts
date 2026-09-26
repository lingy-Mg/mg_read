/**
 * 听中国听书原生数据源。
 *
 * 职责：调用听中国 JSON API，保留全部已确认首页题材区块，首页快照按 offset 翻阅，分类独立分页。
 * 生命周期：activate 保存当前 Runtime 上下文；播放地址只在当前插件进程内按书籍/章节缓存。
 * IO：来源请求和快速音频探测都走 ctx.http；媒体地址只经 ctx.resource.proxy 输出，不缓存媒体主体。
 * 缓存：章节投影进入 Runtime 注入的持久化插件缓存，一天内直接命中；过期章节先返回旧目录并后台刷新。
 * 缓存：签名地址按上游失效时间（无法解析时使用短 TTL）管理；未过期的地址每次播放前用 HEAD 快速探测。
 */
import { createHash } from 'node:crypto';
import { PluginCache, type PluginCachePolicy } from '@mgread/plugin-cache';
import type { MgReadPluginContext } from '@mgread/source-api';

type Json = Record<string, unknown>;
type Context = MgReadPluginContext;

const base = 'https://app.365ting.com';
const api = `${base}/listen/Apitzg2025/`;
const appHeaders = { Accept: 'application/json,text/html,*/*', 'User-Agent': 'TingShiJie/1.8.8 (m.i275.com)' };
const coverHeaders = {
  Accept: 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  Referer: base + '/',
  'User-Agent': appHeaders['User-Agent'],
};
const audioHeaders = { Accept: '*/*', 'User-Agent': 'okhttp/4.9.3' };
const playKey = 'J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K';
const categories = Object.freeze([['popular', '热门', null], ['6', '玄幻', '6'], ['7', '奇幻', '7'], ['8', '武侠', '8'], ['13', '历史', '13'], ['14', '恐怖', '14'], ['31', '评书', '31'], ['50', '儿童', '50']] as const);
const homeSections = [['best', '热门听书', 'popular'], ['xuanhuan', '玄幻', '6'], ['qihuan', '奇幻', '7'], ['wuxia', '武侠', '8'], ['lishi', '历史', '13'], ['kongbu', '恐怖', '14'], ['pingshu', '评书', '31'], ['ertong', '儿童', '50']] as const;
const playbackCacheTtlMs = 10 * 60 * 1000;
const playbackExpirySafetyMs = 5 * 1000;
const playbackProbeTimeoutMs = 1500;
const playbackCacheMaxEntries = 256;
const chapterPageConcurrency = 6;
const chapterCacheTtlMs = 24 * 60 * 60 * 1000;
const chapterCachePolicy = Object.freeze({ namespace: 'audio-chapters-v1', staleAfterMs: chapterCacheTtlMs, serveStaleWhileRevalidate: true, allowStaleOnError: true } satisfies PluginCachePolicy);
let context: Context | undefined;
const chapterLocks = new Map<string, boolean>();
const playbackCache = new Map<string, CachedPlayback>();
const playbackLocks = new Map<string, Promise<CachedPlayback>>();
let chapterCache: PluginCache | undefined;

type CachedPlayback = { url: string; expiresAt: number; mediaExpiresAt: number | null; headers: Readonly<Record<string, string>> };
type ChapterResult = Readonly<{ items: readonly ReturnType<typeof chapter>[]; groups: readonly unknown[] }>;

export async function activate(next: Context): Promise<void> {
  context = next;
  chapterCache = new PluginCache(next.cacheDir, { logger: next.log });
  chapterLocks.clear();
  playbackCache.clear();
  playbackLocks.clear();
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  if (request.cursor !== null) throw new Error('Search cursor is unsupported.');
  if (request.query.trim() === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const data = await fetchJson(`${api}search?search=${encodeURIComponent(request.query)}`);
  return frozen({ items: records(data.data).slice(0, clamp(request.pageSize)).map((value) => summary(value)), nextCursor: null, totalCount: null });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return frozen({ items: [], nextCursor: null }); }

export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    return rootDocument(request.pageSize);
  }
  if (request.target === 'category:popular' || request.target.startsWith('home:')) {
    const entry = homeSections.find(([key]) => request.target === 'home:' + key || (key === 'best' && request.target === 'category:popular'));
    if (entry === undefined) throw new Error('Discovery target is invalid.');
    const prefix = request.target + ':offset:';
    const raw = request.cursor?.startsWith(prefix) ? request.cursor.slice(prefix.length) : '';
    const offset = request.cursor === null ? 0 : /^\d+$/u.test(raw) ? Number(raw) : NaN;
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 10000) throw new Error('Discovery cursor is invalid.');
    const data = await fetchJson(api + 'appHome');
    const values = entry[0] === 'best' ? popular(data) : records(object(object(data.data)[entry[0]]).list);
    return homePage(entry, request.target, values, offset, clamp(request.pageSize), request.collectionId);
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  const page = pageFromCursor(request.cursor, request.target);
  const [id, label, upstreamCategory] = category;
  const url = upstreamCategory === null ? `${api}appHome` : `${api}appHomeByCategory?categoryId=${upstreamCategory}&page=${page}&size=${clamp(request.pageSize)}`;
  const data = await fetchJson(url);
  const values = upstreamCategory === null ? popular(data) : records(data.data).length > 0 ? records(data.data) : records(object(data.data).list);
  const collectionId = `audio:${id}`;
  const items = values.slice(0, clamp(request.pageSize)).map((value) => frozen({ content: summary(value), rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= clamp(request.pageSize) && page < 50 ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({ kind: 'document' as const, document: { components: [section(collectionId, label, items, continuation)] } });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id); const data = await fetchJson(`${api}book?bookId=${encodeURIComponent(id)}`); const payload = object(data.data);
  const nested = object(payload.bookData); const value = Object.keys(nested).length > 0 ? nested : payload; return detail(summary(value, id));
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const result = await requireChapterCache().getOrFetchJson<ChapterResult>(
    id,
    chapterCachePolicy,
    async () => ({ value: await loadChapters(id), storedAtMs: Date.now() }),
    decodeChapters,
  );
  rememberChapterLocks(result.items);
  return result;
}

async function loadChapters(id: string): Promise<ChapterResult> {
  const first = await chapterPage(id, 1); const total = positive(first.count, first.list.length);
  const pageCount = Math.min(25, Math.ceil(total / 200));
  const pages = [first, ...(await chapterPages(id, pageCount))];
  const items = pages.flatMap((value) => value.list).slice(0, 5000).map((value, order) => chapter(id, value, order));
  rememberChapterLocks(items);
  const groups = items.length === 0
    ? []
    : [frozen({ id: `group:${id}:default`, title: '节目', order: 0, episodes: items })];
  return frozen({ items, groups });
}

function rememberChapterLocks(items: readonly ReturnType<typeof chapter>[]) {
  if (chapterLocks.size + items.length > 10_000) chapterLocks.clear();
  for (const item of items) chapterLocks.set(item.id, item.isLocked === true);
}

function decodeChapters(value: unknown): ChapterResult | undefined {
  if (!isObject(value) || !Array.isArray(value.items) || !Array.isArray(value.groups)) return undefined;
  if (!value.items.every(isObject) || !value.groups.every(isObject)) return undefined;
  return value as ChapterResult;
}

async function chapterPages(id: string, pageCount: number) {
  const pages = [] as Awaited<ReturnType<typeof chapterPage>>[];
  for (let start = 2; start <= pageCount; start += chapterPageConcurrency) {
    const batch = await Promise.all(
      Array.from({ length: Math.min(chapterPageConcurrency, pageCount - start + 1) }, (_, offset) => chapterPage(id, start + offset)),
    );
    pages.push(...batch);
  }
  return pages;
}

export async function getContent(request: { id: string; chapterId: string }) {
  const ctx = requireContext();
  ctx.log.info('audio_playback_resource_requested');
  try {
    const bookId = contentId(request.id); const chapterId = chapterIdFrom(request.chapterId, bookId);
    if (chapterLocks.get(request.chapterId) === true) throw new Error('unsupported: paid audio chapter requires an account.');
    const playback = await getPlayback(bookId, chapterId);
    const result = frozen({ chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null, text: null, pages: [], media: {
      url: ctx.resource.proxy({ kind: 'audio', url: playback.url, headers: playback.headers }), resourceType: 'audio', resourcePolicy: playback.mediaExpiresAt === null ? 'sessionOnly' : 'refreshable', expiresAt: playback.mediaExpiresAt === null ? null : new Date(playback.mediaExpiresAt).toISOString(), mimeType: mime(playback.url), headers: playback.headers,
    } });
    ctx.log.info('audio_playback_resource_resolved');
    return result;
  } catch (error) {
    ctx.log.warn('audio_playback_resource_failed');
    throw error;
  }
}

async function getPlayback(bookId: string, chapterId: string): Promise<CachedPlayback> {
  const key = `${bookId}:${chapterId}`;
  const pending = playbackLocks.get(key);
  if (pending !== undefined) return pending;
  const task = resolvePlayback(key, bookId, chapterId);
  playbackLocks.set(key, task);
  try { return await task; } finally { if (playbackLocks.get(key) === task) playbackLocks.delete(key); }
}

async function resolvePlayback(key: string, bookId: string, chapterId: string): Promise<CachedPlayback> {
  const ctx = requireContext();
  const cached = playbackCache.get(key);
  if (cached !== undefined) {
    if (cached.expiresAt <= Date.now() + playbackExpirySafetyMs) {
      playbackCache.delete(key);
      ctx.log.info('audio_playback_cache_expired');
    } else if (await probePlayback(cached)) {
      ctx.log.info('audio_playback_cache_hit');
      return cached;
    } else {
      playbackCache.delete(key);
      ctx.log.info('audio_playback_cache_probe_failed');
    }
  }
  const timestamp = Date.now().toString(); const signature = md5(`${md5(`${timestamp}${playKey}`)}${playKey}`);
  const endpoint = `${api}AppGetChapterUrl2023?timeStamp=${encodeURIComponent(timestamp)}&uid=&chapterId=${encodeURIComponent(chapterId)}&addItParapet=${encodeURIComponent(signature)}&bookId=${encodeURIComponent(bookId)}`;
  const payload = await fetchJson(endpoint); const upstream = text(payload.src);
  if (!trustedAudio(upstream)) throw new Error('Playback address is unavailable.');
  const headers = { ...audioHeaders, Origin: base, Referer: `${base}/` };
  const expiry = playbackExpiry(payload, upstream);
  const resolved = { url: upstream, expiresAt: expiry.cacheExpiresAt, mediaExpiresAt: expiry.mediaExpiresAt, headers };
  if (!playbackCache.has(key) && playbackCache.size >= playbackCacheMaxEntries) {
    const oldest = playbackCache.keys().next().value;
    if (typeof oldest === 'string') playbackCache.delete(oldest);
  }
  playbackCache.set(key, resolved);
  return resolved;
}

async function probePlayback(playback: CachedPlayback): Promise<boolean> {
  try {
    const response = await requireContext().http.fetch(playback.url, { method: 'HEAD', headers: playback.headers, signal: AbortSignal.timeout(playbackProbeTimeoutMs) });
    return response.ok;
  } catch { return false; }
}

function playbackExpiry(payload: Json, url: string): { cacheExpiresAt: number; mediaExpiresAt: number | null } {
  const now = Date.now();
  const explicit = ['expiresAt', 'expireAt', 'expires', 'expireTime', 'expiration'].map((key) => timestamp(payload[key])).find((value) => value !== null);
  const mediaExpiresAt = explicit ?? urlExpiresAt(url);
  return { cacheExpiresAt: mediaExpiresAt ?? now + playbackCacheTtlMs, mediaExpiresAt };
}

function urlExpiresAt(value: string): number | null {
  try {
    const parsed = new URL(value);
    for (const key of ['expiresAt', 'expireAt', 'expires', 'expireTime', 'expiration', 'e']) {
      const result = timestamp(parsed.searchParams.get(key));
      if (result !== null) return result;
    }
    const authKey = parsed.searchParams.get('auth_key');
    const embedded = authKey?.split('-')[1];
    return timestamp(embedded);
  } catch { return null; }
}

function timestamp(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const numeric = typeof value === 'number' ? value : Number(value);
  if (Number.isFinite(numeric) && numeric > 0) {
    const milliseconds = numeric < 100_000_000_000 ? numeric * 1000 : numeric;
    return milliseconds;
  }
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : null;
}

async function fetchJson(url: string): Promise<Json> {
  const response = await requireContext().http.fetch(url, { headers: appHeaders });
  if (!response.ok) throw new Error('Source request failed.');
  const value: unknown = await response.json(); if (!isObject(value)) throw new Error('Source response is invalid.'); return value;
}
async function chapterPage(id: string, page: number) {
  const data = await fetchJson(`${api}chapter?size=200&page=${page}&sort=asc&bookId=${encodeURIComponent(id)}`); const value = object(data.data);
  return { count: number(value.count), list: records(value.list) };
}
async function rootDocument(pageSize: number) {
  const data = await fetchJson(`${api}appHome`);
  const components: object[] = [];
  for (const entry of homeSections) {
    const values = entry[0] === 'best' ? popular(data) : records(object(object(data.data)[entry[0]]).list);
    if (values.length === 0) continue;
    const result = homePage(entry, 'home:' + entry[0], values, 0, Math.min(clamp(pageSize), 4), null);
    if (result.kind === 'document') components.push(...result.document.components);
  }
  components.push({ type: 'section', id: 'audio-categories', title: '听书分类', subtitle: '按题材选择想听的内容', icon: 'explore', children: [{ type: 'categoryCollection', id: 'audio-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'audio' })) }] });
  return frozen({ kind: 'document' as const, document: { components } });
}
function homePage(entry: typeof homeSections[number], target: string, values: Json[], offset: number, size: number, collectionId: string | null) {
  const id = 'audio:' + entry[2];
  if (collectionId !== null && collectionId !== id) throw new Error('Discovery collection is invalid.');
  const items = values.slice(offset, offset + size).map(value => ({ content: summary(value), rank: null, metric: null, recommendation: null }));
  const next = offset + items.length;
  const continuation = next < values.length ? { target, cursor: target + ':offset:' + next } : null;
  if (collectionId !== null) return { kind: 'append' as const, collectionId, items, continuation };
  return { kind: 'document' as const, document: { components: [section(id, entry[1], items, continuation, 'shelf')] } };
}
function section(id: string, title: string, items: readonly unknown[], continuation: unknown, layout = 'coverGrid', icon = 'audio', subtitle: string | null = null) { return { type: 'section', id: `${id}:section`, title, subtitle, icon, children: [{ type: 'contentCollection', id, layout, items, continuation }] }; }
function summary(value: Json, idOverride?: string) {
  const id = idOverride ?? (text(value.id) || text(value.bookId)); if (id === '') throw new Error('Source item has no ID.');
  const count = number(value.count);
  const cover = imageUrl(nullable(value.bookImage) ?? nullable(value.image));
  return frozen({ id: `audio:${id}`, title: text(value.bookTitle) || text(value.title) || '未命名音频', contentKind: 'audio', coverOrientation: 'portrait', author: nullable(value.bookAnchor) ?? nullable(value.anchor), url: `${base}/book/${id}`, coverUrl: cover === null ? null : requireContext().resource.proxy({ kind: 'image', url: cover, headers: coverHeaders }), description: nullable(value.bookDesc) ?? nullable(value.desc), language: 'zh-CN', status: status(value.bookUpdateStatus), access: 'mixed', wordCount: null, chapterCount: count || null, publishedAt: null, updatedAt: null, latestChapter: count > 0 ? { id: null, title: `共${count}集`, url: null, updatedAt: null } : null, categories: nullable(value.categoryName) === null ? [] : [nullable(value.categoryName) as string], tags: [], attributes: [] });
}
function detail(item: ReturnType<typeof summary>) { return frozen({ ...item, aliases: [], catalogUrl: item.url }); }
function chapter(bookId: string, value: Json, order: number) { const id = text(value.chapterId) || text(value.id) || text(value.url); if (id === '') throw new Error('Source chapter has no ID.'); const price = number(value.price) || number(value.chapterPrice); return frozen({ id: `audio:${bookId}:${id}`, title: text(value.title) || `第${order + 1}集`, order, url: `${base}/book/${encodeURIComponent(bookId)}/${encodeURIComponent(id)}`, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: price > 0, attributes: price > 0 ? [{ key: 'price', label: '听币', value: String(price) }] : [] }); }
function popular(data: Json) { const root = object(data.data); return records(object(root.best).list).length > 0 ? records(object(root.best).list) : records(root.list); }
function contentId(id: string) { const match = /^audio:([^:]+)$/u.exec(id); if (match?.[1] === undefined) throw new Error('Content ID is invalid.'); return match[1]; }
function chapterIdFrom(id: string, bookId: string) { const match = new RegExp(`^audio:${escape(bookId)}:([^:]+)$`, 'u').exec(id); if (match?.[1] === undefined) throw new Error('Chapter ID is invalid.'); return match[1]; }
function pageFromCursor(cursor: string | null, target: string) { if (cursor === null) return 1; const value = Number(new RegExp(`^${escape(target)}:(\\d+)$`, 'u').exec(cursor)?.[1]); if (!Number.isSafeInteger(value) || value < 2 || value > 50) throw new Error('Discovery cursor is invalid.'); return value; }
function trustedAudio(value: string) { try { const host = new URL(value).hostname.toLowerCase(); return ['xmcdn.com', 'tingshijie.com', '365ting.com', 'tingchina.com', 'stream.tencentmusic.com'].some((suffix) => host === suffix || host.endsWith(`.${suffix}`)); } catch { return false; } }
function imageUrl(value: string | null) { if (value === null) return null; try { const url = new URL(value, base); return ['http:', 'https:'].includes(url.protocol) ? url.toString() : null; } catch { return null; } }
function mime(url: string) { return /\.m4a(?:$|\?)/iu.test(url) ? 'audio/mp4' : /\.aac(?:$|\?)/iu.test(url) ? 'audio/aac' : 'audio/mpeg'; }
function md5(value: string) { return createHash('md5').update(value).digest('hex'); }
function clamp(value: number) { return Math.max(1, Math.min(100, Math.floor(value))); }
function status(value: unknown) { return String(value) === '1' ? 'completed' : String(value) === '2' ? 'ongoing' : 'unknown'; }
function positive(value: number, fallback: number) { return Number.isSafeInteger(value) && value > 0 ? value : fallback; }
function object(value: unknown): Json { return isObject(value) ? value : {}; }
function records(value: unknown): Json[] { return Array.isArray(value) ? value.filter(isObject) : []; }
function text(value: unknown) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function nullable(value: unknown) { const result = text(value); return result === '' ? null : result; }
function number(value: unknown) { const result = Number(value); return Number.isFinite(result) && result >= 0 ? result : 0; }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function escape(value: string) { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
function requireChapterCache(): PluginCache { if (chapterCache === undefined) throw new Error('Source is not activated.'); return chapterCache; }
