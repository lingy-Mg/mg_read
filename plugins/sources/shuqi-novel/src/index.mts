/**
 * 书旗小说来源：推荐、搜索和目录来自官方网页，公开正文来自官方文本 CDN。
 * activate 注入 Context，清空有界元数据缓存；HTTP 只经 ctx.http，封面只登记 Runtime 代理。
 * 目录中的 VIP 标记是访问边界；读取正文前必须核对真实目录，不请求标为 VIP 的章节。
 * HTTP 主动使用真实 MgRead 来源标识；站点会拒绝宿主默认的精简桌面浏览器标识。
 * 不调用个人中转、不运行旧规则或私有客户端 keystore，不保存 Cookie 或登录态。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

type Search = { query: string; cursor: string | null; pageSize: number };
type Discovery = { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number };
const SITE = 'https://www.shuqi.com';
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const catalogs = new Map<string, { at: number; value: ReturnType<typeof parseCatalog> }>();
const featuredSnapshots = new Map<string, { at: number; ids: string[] }>();

export async function activate(next: MgReadPluginContext) {
  context = next; details.clear(); catalogs.clear(); featuredSnapshots.clear(); next.log.info('shuqi_source_activated');
}

export async function search(request: Search) {
  const query = request.query.trim();
  if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${createHash('sha256').update(query).digest('hex').slice(0, 20)}`;
  const position = decodeCursor(request.cursor, scope);
  const url = new URL('/search', SITE);
  url.search = new URLSearchParams({ keyword: query, page: String(position.page) }).toString();
  const $ = load(await getHtml(url));
  const ids = listingIds($);
  const next = $('a[href]').toArray().some(node => {
    if ($(node).text().trim() !== '下一页') return false;
    const href = sameSite($(node).attr('href') ?? '');
    return href !== null && href.pathname === '/search' && href.searchParams.get('keyword') === query &&
      Number(href.searchParams.get('page')) === position.page + 1;
  });
  const page = slicePage(ids, position, request.pageSize, scope, next);
  return { items: await summaries(page.ids), nextCursor: page.cursor, totalCount: null };
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }

export async function discover(request: Discovery) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'shuqi:featured') throw new Error('Invalid discovery collection.');
  let target = request.target;
  let ids: string[];
  if (target === null) {
    ids = listingIds(load(await getHtml(new URL('/', SITE))));
    target = `featured:${createHash('sha256').update(ids.join(',')).digest('hex').slice(0, 12)}`;
    if (featuredSnapshots.size >= 4) featuredSnapshots.delete(featuredSnapshots.keys().next().value!);
    featuredSnapshots.set(target, { at: Date.now(), ids });
  } else {
    const hit = featuredSnapshots.get(target);
    if (!hit || Date.now() - hit.at > 300000) throw new Error('Featured list has expired; refresh discovery.');
    ids = hit.ids;
  }
  const position = decodeCursor(request.cursor, target);
  const page = slicePage(ids, position, request.pageSize, target, false);
  const items = (await summaries(page.ids)).map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = page.cursor === null ? null : { target, cursor: page.cursor };
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'shuqi:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'shuqi-featured-section',
    title: '书旗推荐', subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: 'shuqi:featured',
      layout: 'coverGrid', items, continuation }] }] } };
}

export async function getDetail(request: { id: string }) {
  const id = bookId(request.id);
  const data = await detail(id);
  return { ...summary(data), description: data.description, aliases: [], catalogUrl: `${SITE}/chapter?bid=${id}` };
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
  if (entry.isLocked) ctx().errors.raise({ code: 'source_access_blocked', message: '书旗将本章标记为 VIP，请到书旗授权阅读。' });
  const path = `/httpserver/filecache/get_book_content_${id}_${match[2]}_3111111111_0_0.html`;
  let text: string | null = null;
  for (const host of ['c1.shuqireader.com', 'c2.shuqireader.com']) {
    let response: Response;
    try {
      response = await ctx().http.fetch(`https://${host}${path}`, { headers: sourceHeaders(), signal: AbortSignal.timeout(15000), redirect: 'error' });
    } catch {
      ctx().log.warn('shuqi_public_cdn_unavailable');
      continue;
    }
    if (!response.ok) continue;
    const raw = await response.text();
    if (Buffer.byteLength(raw) > 300000) throw new Error('Chapter response exceeds its bounded size.');
    const wrapper = /^[A-Za-z_$][\w.$]*\s*\(([\s\S]*)\);?\s*$/u.exec(raw.trim());
    let value: unknown;
    try { value = JSON.parse(wrapper?.[1] ?? raw); } catch { continue; }
    if (!Array.isArray(value)) continue;
    const body = value[0] as { id?: unknown; content?: unknown } | undefined;
    if (String(body?.id) !== match[2] || typeof body?.content !== 'string') continue;
    const $ = load(body.content, undefined, false);
    $('script,style').remove(); $('br').replaceWith('\n'); $('p').append('\n');
    text = $.root().text().replace(/\u00a0/gu, ' ').split(/\n+/u).map(clean).filter(Boolean).join('\n\n');
    if (text.length > 0) break;
  }
  if (!text || /^(?:<!doctype|<html|访问限制)/iu.test(text)) return ctx().errors.raise({ code: 'source_access_blocked', message: '书旗未返回可读的公开正文。' });
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
  return { chapterId: request.chapterId, contentKind: 'novel', title: entry.title, updatedAt: null, text, pages: [], media: null };
}

function listingIds($: ReturnType<typeof load>) {
  const ids = new Set<string>();
  $('a[href]').each((_, node) => {
    const url = sameSite($(node).attr('href') ?? '');
    const match = url === null ? null : /^\/book\/(\d+)\.html$/u.exec(url.pathname);
    if (match) ids.add(match[1]!);
  });
  return [...ids];
}

async function summaries(ids: string[]) {
  const result: ReturnType<typeof summary>[] = [];
  for (let offset = 0; offset < ids.length; offset += 4) {
    result.push(...await Promise.all(ids.slice(offset, offset + 4).map(async id => summary(await detail(id)))));
  }
  return result;
}

async function detail(id: string) {
  const hit = details.get(id);
  if (hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load(await getHtml(new URL(`/book/${id}.html`, SITE))), id);
  if (details.size >= 64) details.delete(details.keys().next().value!);
  details.set(id, { at: Date.now(), value });
  return value;
}

function parseDetail($: ReturnType<typeof load>, id: string) {
  const title = clean($('.bname').first().text());
  if (!title) throw new Error('Book title is missing.');
  const facts = $('.lastchapter li').toArray().map(node => clean($(node).text()));
  return { id, title, author: clean($('.bauthor').first().text()).replace(/^作者[：:]\s*/u, '') || null,
    cover: $('.view > img').first().attr('src') ?? '', description: clean($('.bookDesc').first().text()) || null,
    category: facts[0] || null, words: wordCount(facts[1]), status: /完结/u.test(facts[2] ?? '') ? 'completed' : /连载/u.test(facts[2] ?? '') ? 'ongoing' : 'unknown',
    updatedAt: sourceTime(facts[3]), tags: $('.tags a,.tags span').toArray().map(n => clean($(n).text())).filter(Boolean).slice(0, 32) };
}

function summary(data: Awaited<ReturnType<typeof detail>>) {
  return { id: `book:${data.id}`, title: data.title, contentKind: 'novel', coverOrientation: 'portrait',
    author: data.author, url: `${SITE}/book/${data.id}.html`, coverUrl: cover(data.cover), description: data.description?.slice(0, 180) ?? null,
    language: 'zh-CN', status: data.status, access: 'unknown', wordCount: data.words, chapterCount: null,
    publishedAt: null, updatedAt: data.updatedAt, latestChapter: null,
    categories: data.category ? [data.category] : [], tags: data.tags, attributes: [] };
}

async function catalog(id: string, refresh = false) {
  const hit = catalogs.get(id);
  if (!refresh && hit && Date.now() - hit.at < 60000) return hit.value;
  const value = parseCatalog(load(await getHtml(new URL(`/chapter?bid=${id}`, SITE))), id);
  if (catalogs.size >= 8) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(id, { at: Date.now(), value });
  return value;
}

function parseCatalog($: ReturnType<typeof load>, id: string) {
  let volume: string | null = null;
  const items: { id: string; title: string; order: number; url: string; volumeTitle: string | null; wordCount: null; updatedAt: null; isLocked: boolean; attributes: never[] }[] = [];
  const seen = new Set<string>();
  $('.chapterbox').children('.vol_name,table').each((_, block) => {
    if ($(block).hasClass('vol_name')) { volume = clean($(block).text()) || null; return; }
    $(block).find('a[href]').each((_, node) => {
      const url = sameSite($(node).attr('href') ?? '');
      const cid = url?.searchParams.get('cid');
      if (url?.pathname !== '/reader' || url.searchParams.get('bid') !== id || !cid || !/^\d+$/u.test(cid)) return;
      if (seen.has(cid)) throw new Error('Chapter catalog contains duplicate IDs.');
      seen.add(cid);
      const titleNode = $(node).clone(); titleNode.find('.vip-tag').remove();
      const title = clean(titleNode.text());
      if (!title) throw new Error('Chapter title is missing.');
      items.push({ id: `chapter:${id}:${cid}`, title, order: items.length, url: url.href, volumeTitle: volume,
        wordCount: null, updatedAt: null, isLocked: $(node).find('.vip-tag').length > 0, attributes: [] });
    });
  });
  if (items.length === 0 || items.length > 5000) throw new Error('Chapter catalog is empty or exceeds the host limit.');
  return items;
}

function cover(value: string) {
  let url: URL; try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.hostname !== 'img-tailor.11222.cn' || !url.pathname.startsWith('/bcv/') || url.username || url.password || url.port) return null;
  return ctx().resource.proxy({ kind: 'image', url: url.href, headers: { Accept: 'image/*', Referer: `${SITE}/` } });
}
async function getHtml(url: URL) {
  if (url.origin !== SITE) throw new Error('Source URL is outside its origin.');
  const response = await ctx().http.fetch(url, { headers: sourceHeaders(), signal: AbortSignal.timeout(15000) });
  if (!response.ok || (response.url && new URL(response.url).origin !== SITE)) ctx().errors.raise({ code: 'source_access_blocked', message: `书旗页面暂不可用（HTTP ${response.status}）。` });
  const html = await response.text();
  if (Buffer.byteLength(html) > 2 * 1024 * 1024) throw new Error('Source page exceeds its bounded metadata size.');
  if (/<title[^>]*>[^<]*(?:访问限制|Just a moment)/iu.test(html)) ctx().errors.raise('source_access_blocked');
  return html;
}
function sameSite(raw: string) { try { const u = new URL(raw, SITE); return u.origin === SITE && !u.username && !u.password ? u : null; } catch { return null; } }
function sourceHeaders() { return { Accept: 'text/html', Referer: `${SITE}/`, 'User-Agent': `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})` }; }
function slicePage(ids: string[], position: { page: number; offset: number }, pageSize: number, scope: string, hasNext: boolean) {
  if (position.offset > ids.length) throw new Error('Cursor offset exceeds its source page.');
  const selected = ids.slice(position.offset, position.offset + Math.max(1, Math.min(50, Math.floor(pageSize))));
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
function bookId(value: string) { const m = /^book:(\d+)$/u.exec(value); if (!m) throw new Error('Invalid book ID.'); return m[1]!; }
function wordCount(value: string | undefined) { const m = /^(\d+(?:\.\d+)?)\s*(万|亿)?字$/u.exec(value ?? ''); return m ? Math.round(Number(m[1]) * (m[2] === '亿' ? 100000000 : m[2] === '万' ? 10000 : 1)) : null; }
function sourceTime(value: string | undefined) { const m = /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/u.exec(value ?? ''); const n = Date.parse(`${m?.[0]}:00+08:00`); return Number.isFinite(n) ? new Date(n).toISOString() : null; }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
