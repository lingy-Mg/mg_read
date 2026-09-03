/**
 * Sebo Live 原生数据源。
 *
 * 职责：直接读取 hclyz 平台索引、频道清单和直播地址。
 * 生命周期：activate 注入 Runtime；平台与频道仅做进程内短缓存。
 * IO：JSON 请求走 ctx.http；封面和直播流经 ctx.resource.proxy。
 * 稳定标识：平台使用索引 address，频道使用上游地址摘要。
 */
import { createHash } from 'node:crypto';
import type { MgReadPluginContext } from '@mgread/source-api';

type Json = Record<string, unknown>;
type Context = MgReadPluginContext;
type Platform = { title: string; address: string; image: string; count: number };
type Channel = { title: string; address: string; image: string };

const base = 'http://api.hclyz.com:81/mf/';
const videoHeaders = Object.freeze({ Referer: base, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36' });
let context: Context | undefined;
let platformsCache: readonly Platform[] | undefined;
const channelCache = new Map<string, readonly Channel[]>();

export async function activate(next: Context): Promise<void> {
  context = next;
  platformsCache = undefined;
  channelCache.clear();
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  if (request.cursor !== null) throw new Error('Search cursor is unsupported.');
  const query = request.query.trim().toLocaleLowerCase('zh-CN');
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const values = (await loadPlatforms())
    .filter((item) => item.title.toLocaleLowerCase('zh-CN').includes(query))
    .slice(0, clamp(request.pageSize))
    .map(summary);
  return frozen({ items: values, nextCursor: null, totalCount: values.length });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document' as const, document: { components: [{ type: 'section', id: 'live-platform-entry', title: '直播平台', subtitle: '浏览全部平台', icon: 'video', children: [{ type: 'categoryCollection', id: 'live-platform-categories', layout: 'chips', categories: [{ id: 'all', title: '全部平台', target: 'category:all', count: null, url: null, icon: 'video' }] }] }] } });
  }
  if (request.target !== 'category:all') throw new Error('Discovery target is invalid.');
  const page = cursorPage(request.cursor, request.target);
  const limit = clamp(request.pageSize);
  const platforms = await loadPlatforms();
  const start = (page - 1) * limit;
  const values = platforms.slice(start, start + limit);
  const collectionId = 'live:platforms';
  const items = values.map((value) => frozen({ content: summary(value), rank: null, metric: null, recommendation: null }));
  const continuation = start + values.length < platforms.length ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({ kind: 'document' as const, document: { components: [{ type: 'section', id: 'live-platforms-section', title: '全部平台', subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } });
}

export async function getDetail(request: { id: string }) {
  const address = contentId(request.id);
  const platform = (await loadPlatforms()).find((item) => item.address === address) ?? { title: address, address, image: '', count: 0 };
  const channels = await loadChannels(address);
  const item = summary({ ...platform, count: channels.length });
  return frozen({ ...item, description: `${platform.title}，共 ${channels.length} 个直播频道。`, aliases: [], catalogUrl: joinUrl(address) });
}

export async function getChapters(request: { id: string }) {
  const address = contentId(request.id);
  const channels = await loadChannels(address);
  const items = channels.map((channel, index) => chapter(address, channel, index));
  return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:${encodeKey(address)}:live`, title: '直播频道', order: 0, episodes: items })] });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const address = contentId(request.id);
  const key = chapterKey(request.chapterId, address);
  const channels = await loadChannels(address);
  const channel = channels.find((value) => streamKey(value.address) === key);
  if (channel === undefined || !safeUrl(channel.address)) throw new Error('Chapter ID is invalid.');
  const resourceType = /\.m3u8(?:$|[?#])/iu.test(channel.address) ? 'hls' : 'video';
  return frozen({ chapterId: request.chapterId, contentKind: 'video', title: channel.title, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: channel.address, headers: videoHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: videoHeaders } });
}

async function loadPlatforms(): Promise<readonly Platform[]> {
  if (platformsCache !== undefined) return platformsCache;
  const json = await fetchJson(joinUrl('json.txt'));
  const values: Platform[] = [];
  for (const item of records(json.pingtai)) {
    const title = decoded(item.title);
    const address = text(item.address);
    if (title === '' || address === '' || number(item.Number) <= 0) continue;
    values.push({ title, address, image: text(item.xinimg), count: number(item.Number) });
  }
  platformsCache = Object.freeze(values);
  return platformsCache;
}

async function loadChannels(address: string): Promise<readonly Channel[]> {
  const cached = channelCache.get(address);
  if (cached !== undefined) return cached;
  const json = await fetchJson(joinUrl(address));
  const values: Channel[] = [];
  for (const item of records(json.zhubo)) {
    const title = decoded(item.title);
    const stream = text(item.address);
    if (title !== '' && safeUrl(stream)) values.push({ title, address: stream, image: text(item.img) });
  }
  const result = Object.freeze(values);
  channelCache.set(address, result);
  return result;
}

async function fetchJson(url: string): Promise<Json> {
  const response = await requireContext().http.fetch(url, { headers: { Accept: 'application/json,text/plain,*/*' } });
  if (!response.ok) throw new Error('Source request failed.');
  const value: unknown = await response.json();
  if (!isObject(value)) throw new Error('Source response is invalid.');
  return value;
}

function summary(item: Platform) {
  const id = encodeKey(item.address);
  return frozen({ id: `live:${id}`, title: item.title, contentKind: 'video', coverOrientation: 'landscape', author: 'Live', url: joinUrl(item.address), coverUrl: proxyImage(item.image), description: `${item.count} 个直播频道`, language: null, status: 'ongoing', access: 'free', wordCount: null, chapterCount: item.count || null, publishedAt: null, updatedAt: null, latestChapter: { id: null, title: `${item.count} 个频道`, url: null, updatedAt: null }, categories: ['直播'], tags: [], attributes: [] });
}

function chapter(address: string, channel: Channel, index: number) {
  return frozen({ id: `live:${encodeKey(address)}:${streamKey(channel.address)}`, title: channel.title, order: index, url: null, volumeTitle: '直播频道', wordCount: null, updatedAt: null, isLocked: null, attributes: [] });
}

function joinUrl(path: string) { return new URL(path.replace(/^\/+/, ''), base).toString(); }
function streamKey(url: string) { return createHash('sha256').update(url).digest('hex').slice(0, 24); }
function contentId(id: string) { const encoded = /^live:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined) throw new Error('Content ID is invalid.'); return decodeKey(encoded); }
function chapterKey(id: string, address: string) { const prefix = `live:${encodeKey(address)}:`; if (!id.startsWith(prefix) || id.length === prefix.length) throw new Error('Chapter ID is invalid.'); return id.slice(prefix.length); }
function proxyImage(value: string) { if (!safeUrl(value)) return null; return requireContext().resource.proxy({ kind: 'image', url: value, headers: { Referer: base } }); }
function safeUrl(value: string) { try { const url = new URL(value); return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === ''; } catch { return false; } }
function decoded(value: unknown) { const raw = text(value); try { return decodeURIComponent(raw); } catch { return raw; } }
function cursorPage(cursor: string | null, target: string) { if (cursor === null) return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''; const page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000) throw new Error('Cursor is invalid.'); return page; }
function encodeKey(value: string) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeKey(value: string) { if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error('Source key is invalid.'); return Buffer.from(value, 'base64url').toString('utf8'); }
function records(value: unknown): Json[] { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value: unknown) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function number(value: unknown) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; }
function clamp(value: number) { return Math.max(1, Math.min(60, Math.floor(value))); }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
