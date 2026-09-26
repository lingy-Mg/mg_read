/**
 * JMComic mobile API data source.
 * Owns search, category browsing, detail, catalog, chapter image identities and JM stripe restoration.
 * activate only retains the public context. API JSON travels through ctx.http; image URLs are registered
 * with ctx.resource.proxy and decoded by getResource when Flutter reads the loopback URL.
 * Album and chapter IDs are stable source numbers; the proxy handler accepts only known CDN photo paths.
 */
import { createDecipheriv, createHash } from 'node:crypto';
import type { MgReadPluginContext, PluginImageResourceResponse } from '@mgread/source-api';
import { restoreImage } from './image.js';

type Json = Record<string, unknown>;
type Channel = { readonly id: string; readonly title: string };
const apiHosts = ['www.cdnhth.club', 'www.cdngwc.cc', 'www.cdngwc.net', 'www.cdngwc.club', 'www.cdnhjk.cc'];
const imageHosts = new Set(['cdn-msp.jmapiproxy1.cc', 'cdn-msp.jmapiproxy2.cc', 'cdn-msp2.jmapiproxy2.cc', 'cdn-msp3.jmapiproxy2.cc', 'cdn-msp.jmapinodeudzn.net']);
const imageDomain = 'cdn-msp.jmapiproxy1.cc';
const channels: readonly Channel[] = [
  { id: 'doujin', title: '同人' }, { id: 'single', title: '单本' }, { id: 'short', title: '短篇' },
  { id: 'another', title: '其他' }, { id: 'hanman', title: '韩漫' }, { id: 'meiman', title: '美漫' },
  { id: 'doujin_cosplay', title: 'Cosplay' }, { id: '3D', title: '3D' },
];
const version = '2.0.19';
const agent = 'Mozilla/5.0 (Linux; Android 9; V1938CT Build/PQ3A.190705.11211812; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36';
let context: MgReadPluginContext | undefined;
let apiHost = apiHosts[0] ?? '';
const recentSummaries = new Map<string, ReturnType<typeof summary>>();

export function activate(next: MgReadPluginContext): void { context = next; apiHost = apiHosts[0] ?? ''; recentSummaries.clear(); next.log.info('source_activated'); }

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim();
  if (!query) return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const { page, offset } = cursorState(request.cursor, 'search');
  const data = await apiGet('/search', { search_query: query, main_tag: '0', page: String(page), o: 'mr', t: 'a' });
  if (sourceId(data.redirect_aid) !== null) {
    const id = sourceId(data.redirect_aid)!;
    const detail = await apiGet('/album', { id });
    return frozen({ items: [summary(detail, id)], nextCursor: null, totalCount: 1 });
  }
  const all = records(data.content).map(item => summaryOrNull(item)).filter(notNull);
  const cached = recentSummaries.get(query);
  if (page === 1 && cached !== undefined) {
    const existing = all.findIndex(item => item.id === cached.id);
    if (existing >= 0) all.splice(existing, 1);
    all.unshift(cached);
  }
  const size = clamp(request.pageSize);
  return frozen({ items: all.slice(offset, offset + size), nextCursor: nextCursor('search', data, page, offset, size, all.length),
    totalCount: nonNegative(data.total) });
}

export function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return frozen({ items: [], nextCursor: null }); }

export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }): Promise<{kind:'document';document:{components:object[]}}|{kind:'append';collectionId:string;items:object[];continuation:{target:string;cursor:string}|null}> {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const preview=await discover({target:'category:hanman',cursor:null,collectionId:null,pageSize:Math.min(10,clamp(request.pageSize))});
    return frozen({ kind: 'document' as const, document: { components: [...(preview.kind==='document'?preview.document.components:[]), { type: 'section', id: 'jm-categories', title: '禁漫天堂',
      subtitle: '漫画分类', icon: 'manga', children: [{ type: 'categoryCollection', id: 'jm-category-list', layout: 'chips',
        categories: channels.map(channel => ({ id: channel.id, title: channel.title, target: `category:${channel.id}`, count: null, url: null, icon: 'manga' })) }] }] } });
  }
  const channel = channels.find(value => request.target === `category:${value.id}`);
  if (channel === undefined) throw new Error('Discovery target is invalid.');
  const { page, offset } = cursorState(request.cursor, request.target);
  const data = await apiGet('/categories/filter', { page: String(page), order: '', c: channel.id, o: 'mv' });
  const all = records(data.content).map(item => summaryOrNull(item)).filter(notNull);
  const size = clamp(request.pageSize);
  const values = all.slice(offset, offset + size);
  const collectionId = `jm:${channel.id}`;
  const items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null }));
  const cursor = nextCursor(request.target, data, page, offset, size, all.length);
  const continuation = cursor === null ? null : frozen({ target: request.target, cursor });
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({ kind: 'document' as const, document: { components: [{ type: 'section', id: `${collectionId}:section`,
    title: channel.title, subtitle: null, icon: 'manga', children: [{ type: 'contentCollection', id: collectionId,
      layout: 'coverGrid', items, continuation }] }] } });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id);
  const data = await apiGet('/album', { id });
  const item = summary(data, id);
  const series = records(data.series);
  const tags = stringList(data.tags);
  const description = clean(text(data.description));
  return frozen({ ...item, description: description || null, tags, categories: tags, chapterCount: series.length || 1,
    aliases: [], catalogUrl: albumUrl(id) });
}

export async function getChapters(request: { id: string }) {
  const id = contentId(request.id);
  const data = await apiGet('/album', { id });
  const series = records(data.series).toSorted((left, right) => Number(left.sort) - Number(right.sort));
  const entries = series.length === 0 ? [{ id, name: text(data.name) || '正篇' }] : series;
  const items = entries.map((entry, index) => {
    const photo = sourceId(entry.id);
    if (photo === null) return null;
    return frozen({ id: `manga:${id}:${photo}`, title: text(entry.name) || `第 ${index + 1} 话`, order: index,
      url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
  }).filter(notNull);
  return frozen({ items, groups: [] });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = contentId(request.id);
  const photo = chapterId(request.chapterId, id);
  const data = await apiGet('/chapter', { id: photo });
  const images = Array.isArray(data.images) ? data.images : [];
  if (images.length === 0) throw new Error('Chapter images are unavailable.');
  const scrambleId = await fetchScrambleId(photo);
  const pages: Array<{ id: string; index: number; url: string; resourcePolicy: 'sessionOnly'; expiresAt: null;
    mimeType: string; width: null; height: null }> = [];
  for (const entry of images) {
    const name = text(entry);
    if (!/^[A-Za-z0-9_-]{1,80}\.(?:jpe?g|png|webp|gif)$/iu.test(name)) continue;
    const url = `https://${imageDomain}/media/photos/${photo}/${name}`;
    const segments = segmentCount(scrambleId, photo, name);
    const isGif = name.toLowerCase().endsWith('.gif');
    const index = pages.length;
    pages.push(frozen({ id: `page:${photo}:${name}`, index,
      url: requireContext().resource.proxy(segments === 0 || isGif
        ? { kind: 'image', url, headers: imageHeaders() }
        : { kind: 'image', url, handler: 'jm-stripes-v1', params: { url, segments }, headers: imageHeaders() }),
      resourcePolicy: 'sessionOnly' as const, expiresAt: null,
      mimeType: segments === 0 || isGif ? mimeType(name) : 'image/png', width: null, height: null }));
  }
  if (pages.length === 0) throw new Error('Chapter images are unavailable.');
  return frozen({ chapterId: request.chapterId, contentKind: 'manga' as const, title: text(data.name) || null,
    updatedAt: null, text: null, pages: Object.freeze(pages) });
}

export async function getResource(request: { handler?: unknown; params?: unknown }): Promise<PluginImageResourceResponse> {
  if (request.handler !== 'jm-stripes-v1' || !isObject(request.params)) throw new Error('Image handler is invalid.');
  const url = text(request.params.url);
  const segments = request.params.segments;
  if (!safePhotoUrl(url) || typeof segments !== 'number' || !Number.isSafeInteger(segments) ||
      segments < 2 || segments > 20 || segments % 2 !== 0) {
    throw new Error('Image request is invalid.');
  }
  const response = await requireContext().http.fetch(url, { headers: imageHeaders() });
  if (!response.ok || response.body === null) throw new Error('Image request failed.');
  const bytes = await boundedImage(response);
  const decoded = await restoreImage(bytes, segments);
  if (decoded.byteLength > 24 * 1024 * 1024) throw new Error('Decoded image is too large.');
  return { bytes: decoded, mimeType: 'image/png' };
}

async function apiGet(path: string, params: Readonly<Record<string, string>>): Promise<Json> {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const headers = { 'User-Agent': agent, token: md5(timestamp + '18comicAPP'), tokenparam: `${timestamp},${version}` };
  let last: unknown;
  for (const host of [apiHost, ...apiHosts.filter(value => value !== apiHost)]) {
    const url = new URL(path, `https://${host}`);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    try {
      const response = await requireContext().http.fetch(url, { headers });
      if (!response.ok) throw new Error(`API status ${response.status}`);
      const shell: unknown = await response.json();
      if (!isObject(shell) || typeof shell.data !== 'string') throw new Error('API response is invalid.');
      const key = Buffer.from(md5(timestamp + '185Hcomic3PAPP7R'), 'utf8');
      const decipher = createDecipheriv('aes-256-ecb', key, null);
      const plain = Buffer.concat([decipher.update(Buffer.from(shell.data, 'base64')), decipher.final()]);
      const data: unknown = JSON.parse(plain.toString('utf8'));
      if (!isObject(data)) throw new Error('API data is invalid.');
      apiHost = host;
      return data;
    } catch (error) { last = error; }
  }
  throw new Error(`JM API is unavailable: ${last instanceof Error ? last.message : 'unknown'}`);
}

async function fetchScrambleId(photo: string): Promise<number> {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const url = new URL('/chapter_view_template', `https://${apiHost}`);
  for (const [key, value] of Object.entries({ id: photo, mode: 'vertical', page: '0', app_img_shunt: '1', express: 'off', v: timestamp })) {
    url.searchParams.set(key, value);
  }
  const response = await requireContext().http.fetch(url, { headers: { 'User-Agent': agent,
    token: md5(timestamp + '18comicAPPContent'), tokenparam: `${timestamp},${version}` } });
  if (!response.ok) throw new Error('Scramble information is unavailable.');
  const match = /var\s+scramble_id\s*=\s*(\d+)\s*;/u.exec(await response.text());
  const value = Number(match?.[1]);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error('Scramble information is invalid.');
  return value;
}

function segmentCount(scrambleId: number, photo: string, filename: string): number {
  const id = Number(photo);
  if (id < scrambleId) return 0;
  if (id < 268850) return 10;
  const name = filename.slice(0, filename.lastIndexOf('.'));
  const hex = md5(photo + name);
  return (hex.charCodeAt(hex.length - 1) % (id < 421926 ? 10 : 8)) * 2 + 2;
}

async function boundedImage(response: Response): Promise<Uint8Array> {
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > 16 * 1024 * 1024) throw new Error('Image is too large.');
  const reader = response.body!.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      length += result.value.byteLength;
      if (length > 16 * 1024 * 1024) throw new Error('Image is too large.');
      chunks.push(result.value);
    }
  } catch (error) { await reader.cancel().catch(() => {}); throw error; }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

function summaryOrNull(value: Json) { const id = sourceId(value.id); return id === null || !text(value.name) ? null : summary(value, id); }
function summary(value: Json, id: string) {
  const title = text(value.name) || id;
  const result = frozen({ id: `manga:${id}`, title, contentKind: 'manga' as const, coverOrientation: 'portrait' as const,
    author: stringList(value.author).join(', ') || null, url: albumUrl(id),
    coverUrl: requireContext().resource.proxy({ kind: 'image', url: `https://${imageDomain}/media/albums/${id}_3x4.jpg`, headers: imageHeaders() }),
    description: clean(text(value.description)) || null, language: 'zh-CN', status: 'unknown' as const,
    access: 'unknown' as const, wordCount: null, chapterCount: null, publishedAt: null,
    updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] });
  recentSummaries.set(title, result);
  if (recentSummaries.size > 2048) recentSummaries.delete(recentSummaries.keys().next().value!);
  return result;
}
function imageHeaders() { return { Accept: 'image/*', 'X-Requested-With': 'com.JMComic3.app', Referer: `https://${apiHost}/`, 'User-Agent': agent }; }
function albumUrl(id: string) { return `https://18comic.vip/album/${id}`; }
function safePhotoUrl(value: string) { try { const url = new URL(value); return url.protocol === 'https:' && imageHosts.has(url.hostname) &&
  url.username === '' && url.password === '' && url.port === '' &&
  /^\/media\/photos\/\d+\/[A-Za-z0-9_-]{1,80}\.(?:jpe?g|png|webp)$/iu.test(url.pathname) && url.search === '' && url.hash === '';
} catch { return false; } }
function mimeType(name: string) { const lower = name.toLowerCase(); return lower.endsWith('.png') ? 'image/png' : lower.endsWith('.webp') ? 'image/webp' : lower.endsWith('.gif') ? 'image/gif' : 'image/jpeg'; }
function md5(value: string) { return createHash('md5').update(value).digest('hex'); }
function contentId(value: string) { const match = /^manga:(\d+)$/u.exec(value); if (!match) throw new Error('Content ID is invalid.'); return match[1]!; }
function chapterId(value: string, album: string) { const match = new RegExp(`^manga:${album}:(\\d+)$`, 'u').exec(value); if (!match) throw new Error('Chapter ID is invalid.'); return match[1]!; }
function sourceId(value: unknown) { const id = text(value); return /^\d+$/u.test(id) ? id : null; }
function cursorState(cursor: string | null, target: string) {
  if (cursor === null) return { page: 1, offset: 0 };
  if (!cursor.startsWith(`${target}:`)) throw new Error('Cursor is invalid.');
  const match = /^(\d+):(\d+)$/u.exec(cursor.slice(target.length + 1));
  const page = Number(match?.[1]); const offset = Number(match?.[2]);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000 ||
      page === 1 && offset === 0) throw new Error('Cursor is invalid.');
  return { page, offset };
}
function nextCursor(target: string, data: Json, page: number, offset: number, size: number, count: number) {
  if (offset + size < count) return `${target}:${page}:${offset + size}`;
  const total = nonNegative(data.total);
  return total === null ? count >= 80 ? `${target}:${page + 1}:0` : null : page * 80 < total ? `${target}:${page + 1}:0` : null;
}
function nonNegative(value: unknown) { const number = Number(value); return Number.isSafeInteger(number) && number >= 0 ? number : null; }
function records(value: unknown): Json[] { return Array.isArray(value) ? value.filter(isObject) : []; }
function stringList(value: unknown): string[] { return Array.isArray(value) ? value.map(text).filter(Boolean) : text(value).split(/[,，/]/u).map(part => part.trim()).filter(Boolean); }
function isObject(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value: unknown) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function clean(value: string) { return value.replace(/<[^>]+>/gu, ' ').replace(/&nbsp;/giu, ' ').replace(/&amp;/giu, '&').replace(/\s+/gu, ' ').trim(); }
function clamp(value: number) { return Math.max(1, Math.min(50, Math.floor(value))); }
function notNull<T>(value: T | null): value is T { return value !== null; }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext() { if (context === undefined) throw new Error('Source is not activated.'); return context; }
