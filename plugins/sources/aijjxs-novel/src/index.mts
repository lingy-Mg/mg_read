/**
 * 久久小说网：公开推荐/搜索/详情、完整在线目录和章节正文，全部 IO 经公开 Context。
 * activate 清理有界详情/目录/推荐快照；作品及章节 ID 保留站点数字键，不使用目录下标。
 * 搜索续页保留公开结果编号、真实页码和页内剩余项；书籍大小不转换为字数，上传日期不伪装出版日。
 * 仅在线阅读，不抓取整本下载包；缺目录、占位、重复、未知目录分页或宿主超限均明确失败。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

const SITE = 'https://www.aijjxs.com';
type Chapter = { id: string; title: string; order: number; url: string; volumeTitle: null; wordCount: null; updatedAt: null; isLocked: null; attributes: never[] };
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const catalogs = new Map<string, { at: number; value: Chapter[] }>();
const snapshots = new Map<string, { at: number; ids: string[] }>();
export async function activate(next: MgReadPluginContext) {
  context = next; details.clear(); catalogs.clear(); snapshots.clear(); next.log.info('aijjxs_source_activated');
}
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`, position = searchPosition(request.cursor, scope);
  const page = position === null
    ? await getPage(new URL('/e/search/index.php', SITE), new URLSearchParams({ keyboard: query, show: 'title,writer' }).toString())
    : await getPage(new URL(`/search/result-${position.resultId}-${position.page}.html`, SITE));
  const route = /^\/search\/result-(\d+)-(\d+)\.html$/u.exec(page.url.pathname);
  if (!route) throw new Error('久久小说网未返回搜索结果页面，请检查搜索词或稍后重试。');
  const resultId = route[1]!, index = Number(route[2]);
  if (position && (position.resultId !== resultId || position.page !== index)) throw new Error('Search continuation changed or expired.');
  const $ = load(page.text), ids = listingIds($, '.searchTopic a.searchtitle[href]');
  const offset = position?.offset ?? 0, selected = slicePage(ids, offset, request.pageSize);
  const nextNodes = $('a[href]').toArray().filter(n => clean($(n).text()) === '下一页');
  const nextUrls = [...new Set(nextNodes.map(n => sourceUrl($(n).attr('href') ?? '', page.url)?.href ?? ''))];
  const next = nextUrls[0] ? new URL(nextUrls[0]) : null;
  if (nextUrls.length > 1 || (nextUrls.length && !next) || (next && (next.pathname !== `/search/result-${resultId}-${index + 1}.html` || next.search || next.hash))) throw new Error('Search next-page link is invalid.');
  const nextCursor = selected.end < ids.length ? `${scope}:${resultId}:${index}:${selected.end}` : next ? `${scope}:${resultId}:${index + 1}:0` : null;
  return { items: await summaries(selected.ids), nextCursor, totalCount: null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'aijjxs:featured') throw new Error('Invalid discovery collection.');
  let target = request.target, ids: string[];
  if (target === null) {
    ids = listingIds(load((await getPage(new URL('/', SITE))).text), 'a[href]');
    if (!ids.length) throw new Error('Recommendations are missing.');
    target = `featured:${digest(ids.join(','))}`;
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!);
    snapshots.set(target, { at: Date.now(), ids });
  } else {
    const hit = snapshots.get(target); if (!hit || Date.now() - hit.at > 300000) throw new Error('Featured list has expired; refresh discovery.');
    ids = hit.ids;
  }
  const selected = slicePage(ids, featuredOffset(request.cursor, target), request.pageSize);
  const items = (await summaries(selected.ids)).map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = selected.end < ids.length ? { target, cursor: `${target}:${selected.end}` } : null;
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'aijjxs:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'aijjxs-featured-section', title: '久久小说推荐',
    subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: 'aijjxs:featured', layout: 'coverGrid', items, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const data = await detail(bookId(request.id));
  return { ...summary(data), description: data.description, aliases: [], catalogUrl: `${SITE}/read/${data.id}/` };
}
export async function getChapters(request: { id: string; refresh?: boolean }) { return { items: await catalog(bookId(request.id), request.refresh === true), groups: [] }; }
export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id), match = /^chapter:(\d+):([1-9]\d*)$/u.exec(request.chapterId);
  if (!match || match[1] !== id) throw new Error('Chapter identity does not match its book.');
  const chapter = (await catalog(id)).find(x => x.id === request.chapterId);
  if (!chapter) throw new Error('Chapter is not in the source catalog.');
  const $ = load((await getPage(new URL(chapter.url))).text), body = $('#view_content_txt').first().clone();
  body.find('script,style,nav').remove(); body.find('br').replaceWith('\n'); body.find('p').append('\n');
  const text = body.text().split(/\n+/u).map(clean).filter(Boolean).join('\n\n');
  if (!text || /正在手打中[，,]|内容更新后，请重新刷新|^(?:请先登录|请完成验证|订阅后阅读|Just a moment)/iu.test(text)) return ctx().errors.raise({ code: 'source_access_blocked', message: '久久小说网未返回公开章节正文。' });
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
  return { chapterId: request.chapterId, contentKind: 'novel', title: chapter.title, updatedAt: null, text, pages: [], media: null };
}
async function detail(id: string) {
  const hit = details.get(id); if (hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load((await getPage(new URL(`/txt/${id}.html`, SITE))).text), id);
  if (details.size >= 64) details.delete(details.keys().next().value!);
  details.set(id, { at: Date.now(), value }); return value;
}
function parseDetail($: ReturnType<typeof load>, id: string) {
  const title = clean($('article.panel h3').first().text()).replace(/^《|》$/gu, '');
  if (!title) throw new Error('Book title is missing.');
  const rows = $('.kv p').toArray().map(n => clean($(n).text())), field = (label: string) => rows.find(x => x.startsWith(`${label}：`))?.slice(label.length + 1).trim() || null;
  const status = field('写作进度') ?? '';
  return { id, title, author: field('书籍作者'), category: field('书籍分类'), cover: $('.pic img').first().attr('src') ?? '',
    description: clean($('.intro-panel .desc').first().text()) || null,
    status: /完结|完本/u.test(status) ? 'completed' : /连载/u.test(status) ? 'ongoing' : 'unknown' };
}
function summary(data: Awaited<ReturnType<typeof detail>>) {
  return { id: `book:${data.id}`, title: data.title, contentKind: 'novel', coverOrientation: 'portrait', author: data.author,
    url: `${SITE}/txt/${data.id}.html`, coverUrl: cover(data.cover), description: data.description?.slice(0, 180) ?? null,
    language: 'zh-CN', status: data.status, access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null,
    categories: data.category ? [data.category] : [], tags: [], attributes: [] };
}
async function summaries(ids: string[]) {
  const items: ReturnType<typeof summary>[] = [];
  for (let i = 0; i < ids.length; i += 4) items.push(...await Promise.all(ids.slice(i, i + 4).map(async id => summary(await detail(id)))));
  return items;
}
async function catalog(id: string, refresh = false) {
  const hit = catalogs.get(id); if (!refresh && hit && Date.now() - hit.at < 60000) return hit.value;
  const $ = load((await getPage(new URL(`/read/${id}/`, SITE))).text), items: Chapter[] = [], seen = new Set<string>();
  if ($('a[href]').toArray().some(n => clean($(n).text()) === '下一页')) throw new Error('Unverified catalog pagination; no partial catalog is returned.');
  for (const node of $('ul.chapter-list li a[href]').toArray()) {
    const url = sourceUrl($(node).attr('href') ?? ''), key = url?.pathname.match(new RegExp(`^/read/\\d+/${id}/([1-9]\\d*)\\.html$`, 'u'))?.[1], title = clean($(node).text());
    if (!key || !title || seen.has(key)) throw new Error('Invalid or duplicate upstream chapter key.');
    seen.add(key); items.push({ id: `chapter:${id}:${key}`, title, order: items.length, url: url!.href, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: null, attributes: [] });
  }
  if (!items.length || items.length > 5000) throw new Error('Chapter catalog is empty or exceeds the host limit; it has not been truncated.');
  if (catalogs.size >= 8) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(id, { at: Date.now(), value: items }); return items;
}
function listingIds($: ReturnType<typeof load>, selector: string) {
  const ids = new Set<string>(); $(selector).each((_, node) => { const url = sourceUrl($(node).attr('href') ?? ''), id = url?.pathname.match(/^\/txt\/(\d+)\.html$/u)?.[1]; if (id) ids.add(id); }); return [...ids];
}
function cover(value: string) {
  let url: URL; try { url = new URL(value, SITE); } catch { return null; }
  if (url.protocol !== 'https:' || url.hostname !== 'image.jjjjxsw.com' || url.port || url.username || url.password || url.search || url.hash ||
    !/^\/UploadPic\/\d{4}-?\d{2}\/[A-Za-z0-9_-]+\.(?:jpe?g|png|webp)$/iu.test(url.pathname)) return null;
  return ctx().resource.proxy({ kind: 'image', url: url.href, headers: { Accept: 'image/*', Referer: `${SITE}/` } });
}
async function getPage(url: URL, body?: string) {
  if (url.origin !== SITE) throw new Error('Source URL is outside its origin.');
  const r = await ctx().http.fetch(url, { method: body === undefined ? 'GET' : 'POST', ...(body === undefined ? {} : { body }),
    headers: { Accept: 'text/html', Referer: `${SITE}/`, 'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})` }, signal: AbortSignal.timeout(15000) });
  const final = sourceUrl(r.url || url.href);
  if (!r.ok || !final) ctx().errors.raise({ code: 'source_access_blocked', message: `久久小说网暂不可用（HTTP ${r.status}）。` });
  const text = await r.text(); if (Buffer.byteLength(text) > 2 * 1024 * 1024) throw new Error('Source page exceeds the bounded size.');
  if (/<title[^>]*>[^<]*(?:Just a moment|安全验证|访问限制)/iu.test(text)) ctx().errors.raise('source_access_blocked');
  return { text, url: final! };
}
function sourceUrl(value: string, base: URL | string = SITE) { try { const u = new URL(value, base); return u.origin === SITE && !u.username && !u.password ? u : null; } catch { return null; } }
function slicePage(ids: string[], offset: number, size: number) {
  if (offset > ids.length) throw new Error('Cursor offset exceeds its source page.');
  const selected = ids.slice(offset, offset + Math.max(1, Math.min(50, Math.floor(size)))); return { ids: selected, end: offset + selected.length };
}
function searchPosition(cursor: string | null, scope: string) {
  if (cursor === null) return null; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const m = /^(\d{1,16}):(\d+):(\d+)$/u.exec(cursor.slice(scope.length + 1));
  const page = Number(m?.[2]), offset = Number(m?.[3]);
  if (!m || !Number.isSafeInteger(page) || page < 0 || page > 1000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1000) throw new Error('Invalid search cursor.');
  return { resultId: m[1]!, page, offset };
}
function featuredOffset(cursor: string | null, scope: string) {
  if (cursor === null) return 0; if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.');
  const raw = cursor.slice(scope.length + 1), n = Number(raw); if (!/^\d+$/u.test(raw) || !Number.isSafeInteger(n) || n < 0 || n > 5000) throw new Error('Invalid cursor.'); return n;
}
function digest(value: string) { return createHash('sha256').update(value).digest('hex').slice(0, 12); }
function bookId(value: string) { const m = /^book:(\d+)$/u.exec(value); if (!m) throw new Error('Invalid book ID.'); return m[1]!; }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
