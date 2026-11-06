/**
 * 全本小说网：HTML 推荐/搜索/详情、HTML 首尾与公开 JSONP 中段组成的完整目录及正文。
 * activate 清理有界详情、目录和推荐快照；作品保留上游 URL slug，章节保留上游数字键。
 * JSONP 仅剥离声明的回调后解析 JSON，不执行代码；公开回调编码不涉及 Cookie/浏览器会话。
 * 中段缺失、身份不符、重复、正文占位及宿主超限均失败，不返回部分目录或截断正文。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

const SITE = 'https://www.quanben.io';
type Chapter = { id: string; title: string; order: number; url: string; volumeTitle: null; wordCount: null; updatedAt: null; isLocked: null; attributes: never[] };
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const catalogs = new Map<string, { at: number; value: Chapter[] }>();
const snapshots = new Map<string, { at: number; ids: string[] }>();
export async function activate(next: MgReadPluginContext) {
  context = next; details.clear(); catalogs.clear(); snapshots.clear(); next.log.info('quanben_source_activated');
}
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`, offset = decodeCursor(request.cursor, scope), url = new URL('/index.php', SITE);
  url.search = new URLSearchParams({ c: 'book', a: 'search', keywords: query }).toString();
  const $ = load(await getText(url)), ids = listingIds($, '.row h3 a[href]');
  const page = slicePage(ids, offset, request.pageSize, scope);
  return { items: await summaries(page.ids), nextCursor: page.cursor, totalCount: null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'quanben:featured') throw new Error('Invalid discovery collection.');
  let target = request.target, ids: string[];
  if (target === null) {
    ids = listingIds(load(await getText(new URL('/', SITE))), 'a[href]');
    if (!ids.length) throw new Error('Recommendations are missing.');
    target = `featured:${digest(ids.join(','))}`;
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!);
    snapshots.set(target, { at: Date.now(), ids });
  } else {
    const hit = snapshots.get(target);
    if (!hit || Date.now() - hit.at > 300000) throw new Error('Featured list has expired; refresh discovery.');
    ids = hit.ids;
  }
  const page = slicePage(ids, decodeCursor(request.cursor, target), request.pageSize, target);
  const items = (await summaries(page.ids)).map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = page.cursor === null ? null : { target, cursor: page.cursor };
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'quanben:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'quanben-featured-section', title: '全本推荐',
    subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: 'quanben:featured', layout: 'coverGrid', items, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const data = await detail(bookId(request.id));
  return { ...summary(data), description: data.description, aliases: [], catalogUrl: `${SITE}/n/${data.id}/list.html` };
}
export async function getChapters(request: { id: string; refresh?: boolean }) { return { items: await catalog(bookId(request.id), request.refresh === true), groups: [] }; }
export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id), match = /^chapter:([a-z0-9_-]{1,160}):([1-9]\d*)$/u.exec(request.chapterId);
  if (!match || match[1] !== id) throw new Error('Chapter identity does not match its book.');
  const chapter = (await catalog(id)).find(x => x.id === request.chapterId);
  if (!chapter) throw new Error('Chapter is not in the source catalog.');
  const $ = load(await getText(new URL(chapter.url))), body = $('#content').first().clone();
  body.find('script,style,nav').remove();
  const heading = clean($('h1').first().text());
  const paragraphs = body.find('p').toArray().map(n => clean($(n).text())).filter((x, i) => x && !(i === 0 && (x === heading || x === chapter.title)));
  const text = paragraphs.join('\n\n');
  if (!text || /正在手打中[，,]|内容更新后，请重新刷新|^(?:请先登录|请完成验证|订阅后阅读|Just a moment)/iu.test(text)) return ctx().errors.raise({ code: 'source_access_blocked', message: '全本小说网未返回公开章节正文。' });
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
  return { chapterId: request.chapterId, contentKind: 'novel', title: chapter.title, updatedAt: null, text, pages: [], media: null };
}
async function detail(id: string) {
  const hit = details.get(id); if (hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load(await getText(new URL(`/n/${id}/`, SITE))), id);
  if (details.size >= 64) details.delete(details.keys().next().value!);
  details.set(id, { at: Date.now(), value }); return value;
}
function parseDetail($: ReturnType<typeof load>, id: string) {
  const meta = (key: string) => clean($(`meta[property="${key}"]`).attr('content') ?? '');
  const title = meta('og:novel:book_name') || clean($('h1').first().text());
  if (!title) throw new Error('Book title is missing.');
  const status = meta('og:novel:status');
  return { id, title, author: meta('og:novel:author') || null, cover: meta('og:image'), description: meta('og:description') || null,
    category: meta('og:novel:category') || null, status: /完结|完本/u.test(status) ? 'completed' : /连载/u.test(status) ? 'ongoing' : 'unknown' };
}
function summary(data: Awaited<ReturnType<typeof detail>>) {
  return { id: `book:${data.id}`, title: data.title, contentKind: 'novel', coverOrientation: 'portrait', author: data.author,
    url: `${SITE}/n/${data.id}/`, coverUrl: cover(data.cover), description: data.description?.slice(0, 180) ?? null,
    language: 'zh-CN', status: data.status, access: 'unknown', wordCount: null, chapterCount: null,
    publishedAt: null, updatedAt: null, latestChapter: null, categories: data.category ? [data.category] : [], tags: [], attributes: [] };
}
async function summaries(ids: string[]) {
  const items: ReturnType<typeof summary>[] = [];
  for (let i = 0; i < ids.length; i += 4) items.push(...await Promise.all(ids.slice(i, i + 4).map(async id => summary(await detail(id)))));
  return items;
}
async function catalog(id: string, refresh = false) {
  const hit = catalogs.get(id); if (!refresh && hit && Date.now() - hit.at < 60000) return hit.value;
  const listUrl = new URL(`/n/${id}/list.html`, SITE), html = await getText(listUrl), $ = load(html);
  const blocks = $('.list3').toArray().map(n => $(n).html() ?? '');
  if (!blocks.length) throw new Error('Chapter catalog is missing.');
  const callback = /var\s+callback\s*=\s*'([A-Za-z0-9_$]{1,128})'/u.exec(html)?.[1];
  const upstreamId = /load_more\(\s*'([1-9]\d*)'/u.exec(html)?.[1];
  let middle = '';
  if (callback || upstreamId) {
    if (!callback || !upstreamId) throw new Error('Middle catalog request metadata is incomplete.');
    const api = new URL('/index.php', SITE);
    api.search = new URLSearchParams({ c: 'book', a: 'list.jsonp', callback, book_id: upstreamId, b: encodeCallback(callback) }).toString();
    const response = (await getText(api, listUrl.href)).trim(), start = response.indexOf('('), end = /\)\s*;?\s*$/u.exec(response);
    if (start < 0 || response.slice(0, start).trim() !== `d${callback}` || !end) throw new Error('Invalid catalog JSONP envelope.');
    const data = JSON.parse(response.slice(start + 1, end.index)) as { id?: unknown; content?: unknown };
    if (String(data.id) !== upstreamId || typeof data.content !== 'string' || !data.content) throw new Error('Middle catalog is missing or belongs to another book.');
    middle = data.content;
  }
  const all = load(blocks[0]! + middle + blocks.slice(1).join('')), items: Chapter[] = [], seen = new Set<string>();
  for (const node of all('a[href]').toArray()) {
    const url = sourceUrl(all(node).attr('href') ?? ''), key = url?.pathname.match(new RegExp(`^/n/${id}/([1-9]\\d*)\\.html$`, 'u'))?.[1], title = clean(all(node).text());
    if (!key || !title || seen.has(key)) throw new Error('Invalid or duplicate chapter in the complete catalog.');
    seen.add(key); items.push({ id: `chapter:${id}:${key}`, title, order: items.length, url: url!.href,
      volumeTitle: null, wordCount: null, updatedAt: null, isLocked: null, attributes: [] });
  }
  if (!items.length || items.length > 5000) throw new Error('Chapter catalog is empty or exceeds the host limit; it has not been truncated.');
  if (catalogs.size >= 8) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(id, { at: Date.now(), value: items }); return items;
}
function encodeCallback(value: string) {
  const alphabet = 'PXhw7UT1B0a9kQDKZsjIASmOezxYG4CHo5Jyfg2b8FLpEvRr3WtVnlqMidu6cN';
  return [...value].map(char => { const position = alphabet.indexOf(char);
    return alphabet[0]! + (position < 0 ? char : alphabet[(position + 3) % 62]!) + alphabet[1]!; }).join('');
}
function listingIds($: ReturnType<typeof load>, selector: string) {
  const ids = new Set<string>(); $(selector).each((_, node) => {
    const url = sourceUrl($(node).attr('href') ?? ''), id = url?.pathname.match(/^\/n\/([a-z0-9_-]{1,160})\/$/u)?.[1]; if (id) ids.add(id);
  }); return [...ids];
}
function cover(value: string) {
  let url: URL; try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.hostname !== 'img.c0m.io' || url.port || url.username || url.password || url.search || url.hash ||
    !/^\/quanben\.io\/upload\/thumbnail\/book_\d+_\d+\/book_\d+\.(?:jpe?g|png|webp)$/iu.test(url.pathname)) return null;
  return ctx().resource.proxy({ kind: 'image', url: url.href, headers: { Accept: 'image/*', Referer: `${SITE}/` } });
}
async function getText(url: URL, referer = `${SITE}/`) {
  if (url.origin !== SITE) throw new Error('Source URL is outside its origin.');
  const response = await ctx().http.fetch(url, { headers: { Accept: 'text/html,application/json', Referer: referer,
    'User-Agent': `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})` }, signal: AbortSignal.timeout(15000) });
  if (!response.ok || (response.url && new URL(response.url).origin !== SITE)) ctx().errors.raise({ code: 'source_access_blocked', message: `全本小说网暂不可用（HTTP ${response.status}）。` });
  const text = await response.text(); if (Buffer.byteLength(text) > 2 * 1024 * 1024) throw new Error('Source response exceeds the bounded size.');
  if (/<title[^>]*>[^<]*(?:Just a moment|访问限制|安全验证)/iu.test(text)) ctx().errors.raise('source_access_blocked'); return text;
}
function sourceUrl(value: string) { try { const u = new URL(value, SITE); return u.origin === SITE && !u.username && !u.password ? u : null; } catch { return null; } }
function slicePage(ids: string[], offset: number, size: number, scope: string) {
  if (offset > ids.length) throw new Error('Cursor offset exceeds its source page.');
  const selected = ids.slice(offset, offset + Math.max(1, Math.min(50, Math.floor(size)))), end = offset + selected.length;
  return { ids: selected, cursor: end < ids.length ? `${scope}:${end}` : null };
}
function decodeCursor(cursor: string | null, scope: string) {
  if (cursor === null) return 0; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const raw = cursor.slice(scope.length + 1), n = Number(raw);
  if (!/^\d+$/u.test(raw) || !Number.isSafeInteger(n) || n < 0 || n > 5000) throw new Error('Invalid cursor.'); return n;
}
function digest(value: string) { return createHash('sha256').update(value).digest('hex').slice(0, 12); }
function bookId(value: string) { const m = /^book:([a-z0-9_-]{1,160})$/u.exec(value); if (!m) throw new Error('Invalid book ID.'); return m[1]!; }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
