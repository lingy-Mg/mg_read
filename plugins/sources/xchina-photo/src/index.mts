/**
 * 小黄书混合来源：套图、短篇/带目录小说和视频使用各自公开内容类型。
 * IO 经 ctx.http 与资源代理；章节入口验证使用宿主 WebView，不读取凭据或持有正文缓存。
 * 身份保留旧套图 ID；短篇使用稳定全文章节，长篇只使用真实目录路径。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { base, clean, encode, entry, fromId, idOf, resource, sitePath, type Entry } from './identity.js';
import { chapterGate, detail, fictionChapters, fictionText, listing, nextPage, photoImages, searchLists, videoUrl, type Item } from './parsers.js';
import { readSessionChapter, resetChapterSession } from './chapter-session.js';
let context: MgReadPluginContext | undefined;
const channels = [
  ['latest', '最新套图', '/photos', 'manga'], ['hot', '热门套图', '/photos?sort=hot', 'manga'],
  ['comment', '评论最多', '/photos?sort=comment', 'manga'], ['recent', '最近评论', '/photos?sort=recent', 'manga'],
  ['fiction', '小说', '/fictions', 'book'], ['video', '视频', '/videos', 'video'],
] as const;
const headers = { Accept: 'text/html,application/xhtml+xml,*/*;q=0.8', Referer: base + '/' };
const ctx = () => { if (!context) throw new Error('Source is not activated.'); return context; };
export async function activate(next: MgReadPluginContext) { context = next; resetChapterSession(); next.log.info('source_activated'); }
async function get(path: string) {
  const response = await ctx().http.fetch(base + sitePath(path), { headers, signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw new Error(`Source request failed (${response.status}).`);
  return response.text();
}
function proxy(url: string, path: string, kind: 'image' | 'hls' | 'video') {
  return ctx().resource.proxy({ kind, url: resource(url), headers: { Referer: base + path } });
}
function summary(value: Item) {
  return { id: idOf(value), title: value.title, contentKind: value.kind,
    coverOrientation: value.kind === 'video' ? 'landscape' : 'portrait', author: value.author || null,
    url: base + value.path, coverUrl: value.cover ? proxy(value.cover, value.path, 'image') : null,
    description: value.description, language: 'zh-CN', status: 'unknown', access: 'unknown',
    wordCount: null, chapterCount: value.kind === 'novel' ? null : 1, publishedAt: null, updatedAt: null,
    latestChapter: null, categories: [], tags: [], attributes: [] };
}
type Cursor = { scope: string; path: string; offset: number; pending: string[] };
function cursor(raw: string | null, scope: string, path: string): Cursor {
  if (!raw) return { scope, path, offset: 0, pending: [] };
  if (raw.length > 8192) throw new Error('Cursor is invalid.');
  const v = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as Cursor;
  if (v.scope !== scope || !Number.isSafeInteger(v.offset) || v.offset < 0 || !Array.isArray(v.pending) || v.pending.length > 3) throw new Error('Cursor is invalid.');
  const validate = (s: string) => { const u = new URL(sitePath(s), base); if (!/^\/(photos|videos|fictions)(?:\/\d+)?$/u.test(u.pathname) && u.pathname !== '/search') throw new Error('Cursor path is invalid.'); };
  validate(v.path); v.pending.forEach(validate); return v;
}
async function page(v: Cursor, size: number, supplied?: string) {
  const html = supplied ?? await get(v.path), values = listing(html), limit = Math.max(1, Math.min(50, Math.floor(size)));
  const items = values.slice(v.offset, v.offset + limit).map(summary);
  const next = v.offset + limit < values.length ? { ...v, offset: v.offset + limit } : (() => {
    const pending = [...v.pending], path = nextPage(html, v.path) ?? pending.shift();
    return path ? { ...v, path, offset: 0, pending } : null;
  })();
  return { items, nextCursor: next ? encode(JSON.stringify(next)) : null };
}
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = clean(request.query); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const path = `/search?q=${encodeURIComponent(query)}`, state = cursor(request.cursor, `search:${query}`, path);
  if (!request.cursor) {
    const html = await get(path), paths = searchLists(html, query);
    if (!paths.length) return { ...await page(state, request.pageSize, html), totalCount: null };
    state.path = paths.shift()!; state.pending = paths;
  }
  return { ...await page(state, request.pageSize), totalCount: null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target === null) return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'xchina-channels', title: '小黄书', subtitle: null, icon: 'manga', children: [{ type: 'categoryCollection', id: 'xchina-channel-list', layout: 'chips', categories: channels.map(([id, title, , icon]) => ({ id, title, target: `channel:${id}`, count: null, url: null, icon })) }] }] } };
  const channel = channels.find(([id]) => request.target === `channel:${id}`);
  if (!channel) throw new Error('Discovery target is invalid.');
  const result = await page(cursor(request.cursor, request.target, channel[2]), request.pageSize), collectionId = `xchina:${channel[0]}`;
  const items = result.items.map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = result.nextCursor ? { target: request.target, cursor: result.nextCursor } : null;
  if (request.collectionId !== null) { if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.'); return { kind: 'append' as const, collectionId, items, continuation }; }
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: channel[3], children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const e = fromId(request.id), html = await get(e.path), value = summary(detail(html, e));
  return { ...value, chapterCount: e.kind === 'novel' ? fictionChapters(html, e).length : 1, aliases: [], catalogUrl: base + e.path };
}
function chapter(id: string, title: string, order: number, path: string) {
  return { id, title, order, url: base + path, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] };
}
async function chapters(e: Entry) {
  const id = idOf(e);
  if (e.kind !== 'novel') return [chapter(`${id}:main`, e.kind === 'manga' ? '全部' : '播放', 0, e.path)];
  return fictionChapters(await get(e.path), e).map((value, order) => chapter(`${id}:chapter:${encode(value.path)}`, value.title, order, value.path));
}
export async function getChapters(request: { id: string }) { return { items: await chapters(fromId(request.id)), groups: [] }; }
export async function getContent(request: { id: string; chapterId: string }) {
  const e = fromId(request.id), prefix = { chapterId: request.chapterId, contentKind: e.kind, title: null, updatedAt: null, text: null, pages: [] };
  if (e.kind === 'novel') {
    const value = (await chapters(e)).find(x => x.id === request.chapterId);
    if (!value) throw new Error('Chapter ID is invalid.');
    const path = sitePath(value.url), html = await get(path);
    return { ...prefix, ...fictionText(chapterGate(html, path) ? await readSessionChapter(ctx(), path) : html) };
  }
  if (request.chapterId !== `${request.id}:main`) throw new Error('Chapter ID is invalid.');
  const html = await get(e.path);
  if (e.kind === 'manga') return { ...prefix, pages: photoImages(html, e).map((url, index) => ({ id: `page:${index + 1}`, index, url: proxy(url, e.path, 'image'), mimeType: new URL(url).pathname.endsWith('.webp') ? 'image/webp' : null, width: null, height: null })) };
  const url = videoUrl(html), resourceType = /\.m3u8(?:$|[?#])/iu.test(url) ? 'hls' : 'video';
  return { ...prefix, media: { url: proxy(url, e.path, resourceType), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: { Referer: base + e.path } } };
}
