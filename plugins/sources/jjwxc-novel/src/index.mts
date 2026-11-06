/**
 * 晋江官方公开阅读：移动站推荐/搜索/正文、桌面站详情和完整目录；IO 只经公开 Context。
 * activate 清理有界详情、目录和推荐快照；作品/章节保留官方数字 ID，卷标题仅作元数据。
 * 搜索参数按站点 GB18030 编码，页面按实际 charset 解码；VIP/锁定目录项完整保留并禁止请求正文。
 * 不接入账户、订阅、付费 API、Cookie 或设备验证参数；正文缺失、目录重复及宿主超限均明确失败。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import iconv from 'iconv-lite';
import type { MgReadPluginContext } from '@mgread/source-api';

const MOBILE = 'https://m.jjwxc.net', DESKTOP = 'https://www.jjwxc.net';
type Chapter = { id: string; title: string; order: number; url: string; volumeTitle: string | null;
  wordCount: number | null; updatedAt: string | null; isLocked: boolean; attributes: never[] };
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const catalogs = new Map<string, { at: number; value: Chapter[] }>();
const snapshots = new Map<string, { at: number; ids: string[] }>();
export async function activate(next: MgReadPluginContext) {
  context = next; details.clear(); catalogs.clear(); snapshots.clear(); next.log.info('jjwxc_source_activated');
}
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`, position = searchPosition(request.cursor, scope);
  const path = position.page === 1 ? '/search' : `/search/index/page/${position.page}`;
  const url = new URL(path, MOBILE);
  const keyword = [...iconv.encode(query, 'gb18030')].map(byte => `%${byte.toString(16).padStart(2, '0').toUpperCase()}`).join('');
  url.search = `version=1&kw=${keyword}&t=1`;
  const $ = load(await getHtml(url)), ids = listingIds($);
  const published = (await summaries(ids)).filter(item => item.chapterCount > 0);
  const nextNodes = $('a[href]').toArray().filter(n => clean($(n).text()) === '下一页');
  const nextUrls = [...new Set(nextNodes.map(n => pageUrl($(n).attr('href') ?? '', url)?.href ?? ''))];
  const next = nextUrls[0] ? new URL(nextUrls[0]) : null;
  if (nextUrls.length > 1 || (nextUrls.length && !next) || (next && (next.origin !== MOBILE || next.pathname !== `/search/index/page/${position.page + 1}`))) throw new Error('Search next-page link changed.');
  const slice = slicePage(published.map(item => item.id), position.offset, request.pageSize);
  const nextCursor = slice.end < published.length ? `${scope}:${position.page}:${slice.end}` : next ? `${scope}:${position.page + 1}:0` : null;
  const byId = new Map(published.map(item => [item.id, item]));
  return { items: slice.ids.map(id => byId.get(id)!), nextCursor, totalCount: null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'jjwxc:featured') throw new Error('Invalid discovery collection.');
  let target = request.target, ids: string[];
  if (target === null) {
    ids = listingIds(load(await getHtml(new URL('/', MOBILE))));
    if (!ids.length) throw new Error('Recommendations are missing.');
    target = `featured:${digest(ids.join(','))}`;
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!);
    snapshots.set(target, { at: Date.now(), ids });
  } else {
    const hit = snapshots.get(target); if (!hit || Date.now() - hit.at > 300000) throw new Error('Featured list has expired; refresh discovery.');
    ids = hit.ids;
  }
  const slice = slicePage(ids, featuredOffset(request.cursor, target), request.pageSize);
  const items = (await summaries(slice.ids)).map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = slice.end < ids.length ? { target, cursor: `${target}:${slice.end}` } : null;
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'jjwxc:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'jjwxc-featured-section', title: '晋江推荐',
    subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: 'jjwxc:featured', layout: 'coverGrid', items, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const data = await detail(bookId(request.id));
  return { ...summary(data), description: data.description, aliases: [], catalogUrl: `${DESKTOP}/onebook.php?novelid=${data.id}` };
}
export async function getChapters(request: { id: string; refresh?: boolean }) { return { items: await catalog(bookId(request.id), request.refresh === true), groups: [] }; }
export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id), m = /^chapter:(\d+):([1-9]\d*)$/u.exec(request.chapterId);
  if (!m || m[1] !== id) throw new Error('Chapter identity does not match its book.');
  const chapter = (await catalog(id)).find(x => x.id === request.chapterId);
  if (!chapter) throw new Error('Chapter is not in the source catalog.');
  if (chapter.isLocked) return ctx().errors.raise({ code: 'source_access_blocked', message: '该章节为 VIP 或已锁定，不提供公开正文。' });
  const $ = load(await getHtml(new URL(`/book2/${id}/${m[2]}`, MOBILE))), body = $('ul.content_ul').first().clone();
  body.find('script,style,button').remove(); body.find('br').replaceWith('\n'); body.find('p').append('\n');
  const text = body.text().split(/\n+/u).map(clean).filter(Boolean).join('\n\n');
  if (!text || /^(?:请先登录|请登录后阅读|该章节已锁定|请完成验证|Just a moment)/iu.test(text)) return ctx().errors.raise({ code: 'source_access_blocked', message: '晋江未返回公开章节正文。' });
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
  return { chapterId: request.chapterId, contentKind: 'novel', title: chapter.title, updatedAt: chapter.updatedAt, text, pages: [], media: null };
}
async function detail(id: string) {
  const hit = details.get(id); if (hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load(await getHtml(new URL(`/onebook.php?novelid=${id}`, DESKTOP))), id);
  if (details.size >= 64) details.delete(details.keys().next().value!);
  details.set(id, { at: Date.now(), value }); return value;
}
function parseDetail($: ReturnType<typeof load>, id: string) {
  const title = clean($('h1').first().text()); if (!title) throw new Error('Book title is missing.');
  const intro = $('#novelintro').first().clone(); intro.find('script,style').remove();
  const status = clean($('[itemprop=updataStatus]').first().text());
  return { id, title, author: clean($('[itemprop=author]').first().text()) || null, cover: $('.noveldefaultimage').first().attr('src') ?? '',
    chapterCount: $('#oneboolt tr[itemprop=chapter]').length,
    description: clean(intro.text()) || null, words: numeric(clean($('[itemprop=wordCount]').first().text()).replace(/字$/u, '')),
    category: clean($('[itemprop=genre]').first().text()) || null,
    status: /完成|完结|完本/u.test(status) ? 'completed' : /连载/u.test(status) ? 'ongoing' : 'unknown' };
}
function summary(data: Awaited<ReturnType<typeof detail>>) {
  return { id: `book:${data.id}`, title: data.title, contentKind: 'novel', coverOrientation: 'portrait', author: data.author,
    url: `${MOBILE}/book2/${data.id}`, coverUrl: cover(data.cover), description: data.description?.slice(0, 180) ?? null,
    language: 'zh-CN', status: data.status, access: 'unknown', wordCount: data.words, chapterCount: data.chapterCount, publishedAt: null, updatedAt: null, latestChapter: null,
    categories: data.category ? [data.category] : [], tags: [], attributes: [] };
}
async function summaries(ids: string[]) {
  const items: ReturnType<typeof summary>[] = [];
  for (let i = 0; i < ids.length; i += 4) items.push(...await Promise.all(ids.slice(i, i + 4).map(async id => summary(await detail(id)))));
  return items;
}
async function catalog(id: string, refresh = false) {
  const hit = catalogs.get(id); if (!refresh && hit && Date.now() - hit.at < 60000) return hit.value;
  const $ = load(await getHtml(new URL(`/onebook.php?novelid=${id}`, DESKTOP))), items: Chapter[] = [], seen = new Set<string>();
  let started = false, volume: string | null = null;
  for (const row of $('#oneboolt tr').toArray()) {
    const cells = $(row).children('td');
    if (clean(cells.eq(0).text()) === '章节' && clean(cells.eq(1).text()) === '标题') { started = true; continue; }
    if ($(row).attr('itemprop') !== 'chapter') {
      if (started && cells.length === 1 && !cells.find('a').length) volume = clean(cells.text()) || null;
      continue;
    }
    const headline = $(row).find('[itemprop=headline]').first(), anchor = headline.find('a[itemprop=url]').first();
    const raw = anchor.attr('href') || anchor.attr('rel') || '';
    const url = raw ? officialChapterUrl(raw) : null;
    if (raw && (!url || url.searchParams.get('novelid') !== id)) throw new Error('Chapter link belongs to another book or origin.');
    const key = url?.searchParams.get('chapterid') ?? clean(cells.eq(0).text());
    const title = clean(anchor.text() || headline.text());
    if (!/^[1-9]\d*$/u.test(key) || !title || seen.has(key)) throw new Error('Invalid or duplicate official chapter key.');
    const publicLink = Boolean(anchor.attr('href') && url?.origin === DESKTOP && url.pathname === '/onebook.php');
    const locked = !publicLink || /\[VIP\]|该章节已被锁定|章节已锁定/u.test(headline.text());
    const dateCell = clean(cells.last().text());
    seen.add(key); items.push({ id: `chapter:${id}:${key}`, title, order: items.length, url: `${MOBILE}/book2/${id}/${key}`,
      volumeTitle: volume, wordCount: numeric(clean($(row).find('[itemprop=wordCount]').first().text())), updatedAt: sourceDate(dateCell), isLocked: locked, attributes: [] });
  }
  if (!items.length || items.length > 5000) throw new Error('Chapter catalog is empty or exceeds the host limit; it has not been truncated.');
  if (catalogs.size >= 8) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(id, { at: Date.now(), value: items }); return items;
}
function listingIds($: ReturnType<typeof load>) {
  const ids = new Set<string>(); $('a[href]').each((_, node) => { const u = pageUrl($(node).attr('href') ?? '', MOBILE);
    const key = u?.origin === MOBILE ? u.pathname.match(/^\/book2\/([1-9]\d*)$/u)?.[1] : null; if (key) ids.add(key); }); return [...ids];
}
function officialChapterUrl(raw: string) {
  try { const u = new URL(raw, DESKTOP); if (u.username || u.password || u.port || !['http:', 'https:'].includes(u.protocol)) return null;
    if (!((u.hostname === 'www.jjwxc.net' && u.pathname === '/onebook.php') || (u.hostname === 'my.jjwxc.net' && u.pathname === '/onebook_vip.php'))) return null;
    // HTTP links in the desktop catalog identify the same official HTTPS page; no request is made here.
    u.protocol = 'https:'; return u; } catch { return null; }
}
function cover(value: string) {
  let u: URL; try { u = new URL(value, DESKTOP); } catch { return null; }
  if (u.protocol !== 'https:' || !/^i[1-9]-static\.jjwxc\.net$/u.test(u.hostname) || u.username || u.password || u.port || u.search || u.hash ||
    !/^\/[A-Za-z0-9_./%-]+\.(?:jpe?g|png|gif|webp)$/iu.test(u.pathname)) return null;
  return ctx().resource.proxy({ kind: 'image', url: u.href, headers: { Accept: 'image/*', Referer: `${DESKTOP}/` } });
}
async function getHtml(url: URL) {
  if (![MOBILE, DESKTOP].includes(url.origin)) throw new Error('Source URL is outside the official read-only origins.');
  const r = await ctx().http.fetch(url, { headers: { Accept: 'text/html', Referer: `${url.origin}/`,
    'User-Agent': `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})` }, signal: AbortSignal.timeout(15000) });
  if (!r.ok || (r.url && !pageUrl(r.url, url))) ctx().errors.raise({ code: 'source_access_blocked', message: `晋江公开页面暂不可用（HTTP ${r.status}）。` });
  const bytes = await r.arrayBuffer(); if (bytes.byteLength > 2 * 1024 * 1024) throw new Error('Source page exceeds the bounded size.');
  const charset = /charset\s*=\s*["']?utf-?8/iu.test(r.headers.get('content-type') ?? '') ? 'utf-8' : 'gb18030';
  const html = new TextDecoder(charset).decode(bytes);
  if (/<title[^>]*>[^<]*(?:Just a moment|安全验证|访问限制)/iu.test(html)) ctx().errors.raise('source_access_blocked'); return html;
}
function pageUrl(value: string, base: URL | string) { try { const u = new URL(value, base); return [MOBILE, DESKTOP].includes(u.origin) && !u.username && !u.password ? u : null; } catch { return null; } }
function slicePage(ids: string[], offset: number, size: number) {
  if (offset > ids.length) throw new Error('Cursor offset exceeds its source page.');
  const selected = ids.slice(offset, offset + Math.max(1, Math.min(50, Math.floor(size)))); return { ids: selected, end: offset + selected.length };
}
function searchPosition(cursor: string | null, scope: string) {
  if (cursor === null) return { page: 1, offset: 0 }; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const m = /^(\d+):(\d+)$/u.exec(cursor.slice(scope.length + 1)), page = Number(m?.[1]), offset = Number(m?.[2]);
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000) throw new Error('Invalid search cursor.'); return { page, offset };
}
function featuredOffset(cursor: string | null, scope: string) {
  if (cursor === null) return 0; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const raw = cursor.slice(scope.length + 1), n = Number(raw); if (!/^\d+$/u.test(raw) || !Number.isSafeInteger(n) || n < 0 || n > 5000) throw new Error('Invalid cursor.'); return n;
}
function sourceDate(value: string) { const m = /\d{4}-\d\d-\d\d \d\d:\d\d:\d\d/u.exec(value); if (!m) return null;
  const n = Date.parse(`${m[0].replace(' ', 'T')}+08:00`); return Number.isFinite(n) ? new Date(n).toISOString() : null; }
function numeric(value: string) { if (!/^\d+$/u.test(value)) return null; const n = Number(value); return Number.isSafeInteger(n) && n >= 0 ? n : null; }
function digest(value: string) { return createHash('sha256').update(value).digest('hex').slice(0, 12); }
function bookId(value: string) { const m = /^book:([1-9]\d*)$/u.exec(value); if (!m) throw new Error('Invalid book ID.'); return m[1]!; }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
