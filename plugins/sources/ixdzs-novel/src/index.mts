/**
 * 爱下电子书来源：站点推荐/搜索/详情、POST 完整目录和公开 HTML 正文。
 * activate 注入 Context 并清空有界详情、目录及推荐快照；所有 IO 经 ctx.http 或资源代理。
 * 作品使用官方数字书号；章节使用接口提供的 ordernum（站点 pN.html 的章节键），不使用数组下标。
 * 不读取、拼接或重放验证令牌；只有正文 section 可公开读取时返回文本，挑战页明确失败。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

type Search = { query: string; cursor: string | null; pageSize: number };
type Discovery = { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number };
const SITE = 'https://ixdzs8.com';
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const catalogs = new Map<string, { at: number; value: ReturnType<typeof parseCatalog> }>();
const snapshots = new Map<string, { at: number; ids: string[] }>();

export async function activate(next: MgReadPluginContext) {
  context = next; details.clear(); catalogs.clear(); snapshots.clear(); next.log.info('ixdzs_source_activated');
}

export async function search(request: Search) {
  const query = request.query.trim();
  if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`;
  const position = decodeCursor(request.cursor, scope);
  const url = new URL('/bsearch', SITE);
  url.search = new URLSearchParams({ q: query, page: String(position.page) }).toString();
  const $ = load(await getText(url));
  const ids = listingIds($);
  const hasNext = $('a[href]').toArray().some(node => {
    if (!/^(?:下一页|下一頁|下页|下一页[>»])$/u.test(clean($(node).text()))) return false;
    const next = sourceUrl($(node).attr('href') ?? '');
    return next?.pathname === '/bsearch' && next.searchParams.get('q') === query && Number(next.searchParams.get('page')) === position.page + 1;
  });
  const page = slicePage(ids, position, request.pageSize, scope, hasNext);
  return { items: await summaries(page.ids), nextCursor: page.cursor, totalCount: null };
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }

export async function discover(request: Discovery) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'ixdzs:featured') throw new Error('Invalid discovery collection.');
  let target = request.target;
  let ids: string[];
  if (target === null) {
    ids = listingIds(load(await getText(new URL('/', SITE))));
    target = `featured:${digest(ids.join(','))}`;
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!);
    snapshots.set(target, { at: Date.now(), ids });
  } else {
    const hit = snapshots.get(target);
    if (!hit || Date.now() - hit.at > 300000) throw new Error('Featured list has expired; refresh discovery.');
    ids = hit.ids;
  }
  const page = slicePage(ids, decodeCursor(request.cursor, target), request.pageSize, target, false);
  const items = (await summaries(page.ids)).map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = page.cursor === null ? null : { target, cursor: page.cursor };
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'ixdzs:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'ixdzs-featured-section', title: '爱下推荐',
    subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: 'ixdzs:featured', layout: 'coverGrid', items, continuation }] }] } };
}

export async function getDetail(request: { id: string }) {
  const data = await detail(bookId(request.id));
  return { ...summary(data), description: data.description, aliases: [], catalogUrl: `${SITE}/read/${data.id}/` };
}

export async function getChapters(request: { id: string; refresh?: boolean }) {
  return { items: await catalog(bookId(request.id), request.refresh === true), groups: [] };
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id);
  const match = /^chapter:(\d+):(\d+)$/u.exec(request.chapterId);
  if (!match || match[1] !== id) throw new Error('Chapter identity does not match its book.');
  const entry = (await catalog(id)).find(chapter => chapter.id === request.chapterId);
  if (!entry) throw new Error('Chapter is not in the source catalog.');
  const $ = load(await getText(new URL(`/read/${id}/p${match[2]}.html`, SITE)));
  const section = $('section').first().clone();
  section.find('script,style,nav,h1,h2').remove(); section.find('br').replaceWith('\n'); section.find('p').append('\n');
  const text = section.text().replace(/\u00a0/gu, ' ').split(/\n+/u).map(clean).filter(Boolean).join('\n\n');
  if (!text || /^(?:请完成验证|访问限制|Just a moment)/iu.test(text)) return ctx().errors.raise({
    code: 'source_access_blocked', message: '爱下电子书未返回公开正文，页面可能需要站点验证。',
  });
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
  return { chapterId: request.chapterId, contentKind: 'novel', title: entry.title, updatedAt: null, text, pages: [], media: null };
}

async function detail(id: string) {
  const hit = details.get(id);
  if (hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load(await getText(new URL(`/read/${id}/`, SITE))), id);
  if (details.size >= 64) details.delete(details.keys().next().value!);
  details.set(id, { at: Date.now(), value });
  return value;
}
function parseDetail($: ReturnType<typeof load>, id: string) {
  const meta = (key: string) => clean($(`meta[property="${key}"]`).attr('content') ?? '');
  const title = meta('og:novel:book_name') || clean($('.n-text h1').first().text());
  if (!title) throw new Error('Book title is missing.');
  const latestUrl = sourceUrl(meta('og:novel:latest_chapter_url'));
  const latest = latestUrl === null ? null : new RegExp(`^/read/${id}/p(\\d+)\\.html$`, 'u').exec(latestUrl.pathname)?.[1] ?? null;
  const status = meta('og:novel:status') || clean($('.n-text .lz').text());
  const date = Date.parse(meta('og:novel:update_time'));
  return { id, title, author: meta('og:novel:author') || clean($('.n-text .bauthor').first().text()) || null,
    cover: meta('og:image') || $('.n-img img').first().attr('src') || '', description: clean($('#intro').text()) || meta('og:description') || null,
    category: meta('og:novel:category') || null, words: wordCount(clean($('.nsize').text())),
    status: /完结/u.test(status) ? 'completed' : /连载/u.test(status) ? 'ongoing' : 'unknown',
    updatedAt: Number.isFinite(date) ? new Date(date).toISOString() : null,
    latest, latestTitle: meta('og:novel:latest_chapter_name'), tags: $('.tags a').toArray().map(n => clean($(n).text())).filter(Boolean).slice(0, 32) };
}
function summary(data: Awaited<ReturnType<typeof detail>>) {
  return { id: `book:${data.id}`, title: data.title, contentKind: 'novel', coverOrientation: 'portrait', author: data.author,
    url: `${SITE}/read/${data.id}/`, coverUrl: cover(data.cover), description: data.description?.slice(0, 180) ?? null,
    language: 'zh-CN', status: data.status, access: 'unknown', wordCount: data.words, chapterCount: null,
    publishedAt: null, updatedAt: data.updatedAt, latestChapter: data.latestTitle ? { id: data.latest ? `chapter:${data.id}:${data.latest}` : null,
      title: data.latestTitle, url: data.latest ? `${SITE}/read/${data.id}/p${data.latest}.html` : null, updatedAt: data.updatedAt } : null,
    categories: data.category ? [data.category] : [], tags: data.tags, attributes: [] };
}
async function summaries(ids: string[]) {
  const items: ReturnType<typeof summary>[] = [];
  for (let i = 0; i < ids.length; i += 4) items.push(...await Promise.all(ids.slice(i, i + 4).map(async id => summary(await detail(id)))));
  return items;
}

async function catalog(id: string, refresh = false) {
  const hit = catalogs.get(id);
  if (!refresh && hit && Date.now() - hit.at < 60000) return hit.value;
  const raw = await getText(new URL('/novel/clist/', SITE), { method: 'POST', headers: {
    ...sourceHeaders(), 'Content-Type': 'application/x-www-form-urlencoded',
  }, body: new URLSearchParams({ bid: id }).toString() });
  const data = JSON.parse(raw) as { data?: unknown };
  const value = parseCatalog(data.data, id);
  if (catalogs.size >= 8) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(id, { at: Date.now(), value });
  return value;
}
function parseCatalog(value: unknown, id: string) {
  if (!Array.isArray(value)) throw new Error('Chapter catalog is missing.');
  const items: { id: string; title: string; order: number; url: string; volumeTitle: string | null; wordCount: null; updatedAt: null; isLocked: null; attributes: never[] }[] = [];
  let volume: string | null = null;
  const seen = new Set<string>();
  for (const valueRow of value) {
    const row = valueRow as { ctype?: unknown; ordernum?: unknown; title?: unknown };
    if (String(row.ctype) === '1') { volume = typeof row.title === 'string' ? clean(row.title) || null : null; continue; }
    if (String(row.ctype) !== '0') throw new Error('Unknown chapter row type.');
    const key = String(row.ordernum ?? '');
    if (!/^[1-9]\d*$/u.test(key) || !Number.isSafeInteger(Number(key)) || seen.has(key)) throw new Error('Invalid or duplicate upstream chapter key.');
    seen.add(key);
    const title = typeof row.title === 'string' ? clean(row.title) : '';
    if (!title) throw new Error('Chapter title is missing.');
    items.push({ id: `chapter:${id}:${key}`, title, order: items.length, url: `${SITE}/read/${id}/p${key}.html`, volumeTitle: volume,
      wordCount: null, updatedAt: null, isLocked: null, attributes: [] });
  }
  if (items.length === 0 || items.length > 5000) throw new Error('Chapter catalog is empty or exceeds the host limit.');
  return items;
}
function listingIds($: ReturnType<typeof load>) {
  const ids = new Set<string>();
  $('a[href]').each((_, node) => {
    const url = sourceUrl($(node).attr('href') ?? '');
    const m = url === null ? null : /^\/read\/(\d+)\/$/u.exec(url.pathname);
    if (m) ids.add(m[1]!);
  });
  return [...ids];
}
function cover(value: string) {
  let url: URL; try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.hostname !== 'img22.ixdzs.com' || url.username || url.password || url.port ||
    !/^\/[a-f0-9]{2}\/[a-f0-9]{2}\/[a-f0-9]{20,64}\.(?:jpe?g|png|webp)$/iu.test(url.pathname)) return null;
  return ctx().resource.proxy({ kind: 'image', url: url.href, headers: {
    Accept: 'image/*', Referer: `${SITE}/`, 'User-Agent': sourceHeaders()['User-Agent'],
  } });
}
async function getText(url: URL, init: RequestInit = {}) {
  if (url.origin !== SITE) throw new Error('Source URL is outside its origin.');
  const response = await ctx().http.fetch(url, { ...init, headers: init.headers ?? sourceHeaders(), signal: AbortSignal.timeout(15000) });
  if (!response.ok || (response.url && new URL(response.url).origin !== SITE)) ctx().errors.raise({ code: 'source_access_blocked', message: `爱下电子书页面暂不可用（HTTP ${response.status}）。` });
  const text = await response.text();
  if (Buffer.byteLength(text) > 2 * 1024 * 1024) throw new Error('Source response exceeds the bounded metadata size.');
  if (/<title[^>]*>[^<]*(?:Just a moment|访问限制|安全验证)/iu.test(text)) ctx().errors.raise('source_access_blocked');
  return text;
}
function sourceHeaders() { return { Accept: 'text/html,application/json', Referer: `${SITE}/`, 'User-Agent': `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})` }; }
function sourceUrl(raw: string) { try { const u = new URL(raw, SITE); return u.origin === SITE && !u.username && !u.password ? u : null; } catch { return null; } }
function slicePage(ids: string[], position: { page: number; offset: number }, size: number, scope: string, hasNext: boolean) {
  if (position.offset > ids.length) throw new Error('Cursor offset exceeds its source page.');
  const selected = ids.slice(position.offset, position.offset + Math.max(1, Math.min(50, Math.floor(size))));
  const end = position.offset + selected.length;
  return { ids: selected, cursor: end < ids.length ? `${scope}:${position.page}:${end}` : hasNext ? `${scope}:${position.page + 1}:0` : null };
}
function decodeCursor(cursor: string | null, scope: string) {
  if (cursor === null) return { page: 1, offset: 0 };
  if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const match = /^(\d+):(\d+)$/u.exec(cursor.slice(scope.length + 1));
  const page = Number(match?.[1]), offset = Number(match?.[2]);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000 || (scope.startsWith('featured:') && page !== 1)) throw new Error('Invalid cursor.');
  return { page, offset };
}
function digest(value: string) { return createHash('sha256').update(value).digest('hex').slice(0, 12); }
function bookId(value: string) { const m = /^book:(\d+)$/u.exec(value); if (!m) throw new Error('Invalid book ID.'); return m[1]!; }
function wordCount(value: string) { const m = /^(\d+(?:\.\d+)?)\s*(万|亿)?字$/u.exec(value); return m ? Math.round(Number(m[1]) * (m[2] === '亿' ? 100000000 : m[2] === '万' ? 10000 : 1)) : null; }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
