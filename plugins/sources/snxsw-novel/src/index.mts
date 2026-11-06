/**
 * 少年小说网：公开 HTML 推荐/搜索/详情、可见完整目录和多段正文，所有 IO 经 Context。
 * activate 清理有界详情、目录和推荐快照；作品/章节保留上游数字 ID，正文分段不成为独立章节。
 * 目录以站点 select 公布的全部页为准；CSS 隐藏项先同时选中再删除，不能边删边算 nth-child。
 * 只解码页面公开 Base64 段落，不执行站点 JS、不读 Cookie/令牌；缺段、占位或超限明确失败。
 */
import { createHash } from 'node:crypto';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

const SITE = 'https://www.snxsw.com';
type Chapter = { id: string; title: string; order: number; url: string; volumeTitle: null; wordCount: null;
  updatedAt: null; isLocked: null; attributes: never[] };
let context: MgReadPluginContext | undefined;
const details = new Map<string, { at: number; value: ReturnType<typeof parseDetail> }>();
const catalogs = new Map<string, { at: number; value: Chapter[] }>();
const snapshots = new Map<string, { at: number; ids: string[] }>();
export async function activate(next: MgReadPluginContext) {
  context = next; details.clear(); catalogs.clear(); snapshots.clear(); next.log.info('snxsw_source_activated');
}
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`, position = decodeCursor(request.cursor, scope);
  const $ = load(await getText(new URL('/search.html', SITE), new URLSearchParams({ s: query }).toString()));
  const ids = listingIds($, '.txt-list .s2 a[href]');
  const page = slicePage(ids, position, request.pageSize, scope);
  return { items: await summaries(page.ids), nextCursor: page.cursor, totalCount: null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target !== null && !/^featured:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid discovery target.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid initial discovery request.');
  if (request.collectionId !== null && request.collectionId !== 'snxsw:featured') throw new Error('Invalid discovery collection.');
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
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId: 'snxsw:featured', items, continuation };
  return { kind: 'document' as const, document: { components: [{ type: 'section', id: 'snxsw-featured-section', title: '少年小说推荐',
    subtitle: null, icon: 'book', children: [{ type: 'contentCollection', id: 'snxsw:featured', layout: 'coverGrid', items, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const d = await detail(bookId(request.id));
  return { ...summary(d), description: d.description, aliases: [], catalogUrl: `${SITE}/book/${d.id}/` };
}
export async function getChapters(request: { id: string; refresh?: boolean }) { return { items: await catalog(bookId(request.id), request.refresh === true), groups: [] }; }
export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id), m = /^chapter:(\d+):(\d+)$/u.exec(request.chapterId);
  if (!m || m[1] !== id) throw new Error('Chapter identity does not match its book.');
  const chapter = (await catalog(id)).find(x => x.id === request.chapterId);
  if (!chapter) throw new Error('Chapter is not in the source catalog.');
  const base = new URL(chapter.url).pathname.replace(/\.html$/u, '');
  let url: URL | null = new URL(chapter.url), part = 0; const texts: string[] = [];
  while (url) {
    if (part >= 16) throw new Error('Chapter has too many parts; no partial body is returned.');
    const $ = load(await getText(url)), body = $('.word_read').first().clone();
    body.find('script').each((_, node) => {
      const decoded: string[] = [];
      for (const match of $(node).text().matchAll(/qsbs\.bb\('([A-Za-z0-9+/=]+)'\)/gu)) {
        const html = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(match[1]!, 'base64'));
        if (/^<p(?:\s|>)/u.test(html)) decoded.push(html);
      }
      body.find(node).replaceWith(decoded.join(''));
    });
    body.find('script,style,nav,.read_btn').remove();
    const paragraphs = body.find('p').toArray().map(n => clean($(n).text()).replace(/[-－]{0,3}>?\s*少年小说网（www\.snxsw\.com）[^！\n]{0,20}！/gu, '').trim()).filter(Boolean);
    const text = paragraphs.join('\n\n');
    if (!text || /正在手打中[，,]|内容更新后，请重新刷新|^(?:请先登录|请完成验证|订阅后阅读|Just a moment)/iu.test(text)) return ctx().errors.raise({ code: 'source_access_blocked', message: '少年小说网未返回公开正文或正文分段缺失。' });
    texts.push(text);
    if (Buffer.byteLength(texts.join('\n\n'), 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
    const nexts = [...new Set($('a[href]').toArray().filter(n => clean($(n).text()) === '下一章').map(n => $(n).attr('href')!))];
    if (nexts.length > 1) throw new Error('Conflicting next-chapter links.');
    const next = nexts.length ? sourceUrl(nexts[0]!) : null;
    if (nexts.length && !next) throw new Error('Invalid next-chapter origin.');
    if (next?.pathname === `${base}.html`) throw new Error('Chapter part loops.');
    if (next?.pathname.startsWith(`${base}_`)) {
      if (next.pathname !== `${base}_${part + 1}.html` || next.search || next.hash) throw new Error('Chapter part is missing or loops.');
      url = next;
    } else url = null;
    part++;
  }
  return { chapterId: request.chapterId, contentKind: 'novel', title: chapter.title, updatedAt: null, text: texts.join('\n\n'), pages: [], media: null };
}
async function detail(id: string) {
  const hit = details.get(id); if (hit && Date.now() - hit.at < 120000) return hit.value;
  const value = parseDetail(load(await getText(new URL(`/book/${id}/`, SITE))), id);
  if (details.size >= 64) details.delete(details.keys().next().value!);
  details.set(id, { at: Date.now(), value }); return value;
}
function parseDetail($: ReturnType<typeof load>, id: string) {
  const meta = (key: string) => clean($(`meta[property="${key}"]`).attr('content') ?? '');
  const title = meta('og:novel:book_name') || meta('og:title'); if (!title) throw new Error('Book title is missing.');
  const status = meta('og:novel:status'), date = meta('og:novel:update_time');
  const time = /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/u.test(date) ? Date.parse(`${date.replace(' ', 'T')}+08:00`) : NaN;
  const latest = sourceUrl(meta('og:novel:latest_chapter_url'));
  const latestId = latest?.pathname.match(new RegExp(`^/read/\\d+/${id}/(\\d+)\\.html$`, 'u'))?.[1] ?? null;
  return { id, title, author: meta('og:novel:author') || null, category: meta('og:novel:category') || null,
    description: meta('og:description') || null, cover: meta('og:image'), status: /完结|完本/u.test(status) ? 'completed' : /连载/u.test(status) ? 'ongoing' : 'unknown',
    updatedAt: Number.isFinite(time) ? new Date(time).toISOString() : null, latestId, latestUrl: latestId ? latest!.href : null,
    latestTitle: meta('og:novel:latest_chapter_name') };
}
function summary(d: Awaited<ReturnType<typeof detail>>) {
  return { id: `book:${d.id}`, title: d.title, contentKind: 'novel', coverOrientation: 'portrait', author: d.author,
    url: `${SITE}/book/${d.id}/`, coverUrl: cover(d.cover), description: d.description?.slice(0, 180) ?? null,
    language: 'zh-CN', status: d.status, access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: d.updatedAt,
    latestChapter: d.latestTitle ? { id: d.latestId ? `chapter:${d.id}:${d.latestId}` : null, title: d.latestTitle, url: d.latestUrl, updatedAt: d.updatedAt } : null,
    categories: d.category ? [d.category] : [], tags: [], attributes: [] };
}
async function summaries(ids: string[]) {
  const items: ReturnType<typeof summary>[] = [];
  for (let i = 0; i < ids.length; i += 4) items.push(...await Promise.all(ids.slice(i, i + 4).map(async id => summary(await detail(id)))));
  return items;
}
async function catalog(id: string, refresh = false) {
  const hit = catalogs.get(id); if (!refresh && hit && Date.now() - hit.at < 60000) return hit.value;
  const rootPath = `/book/${id}/`, root = load(await getText(new URL(rootPath, SITE))), pages: { path: string; $: ReturnType<typeof load> | null }[] = [{ path: rootPath, $: root }];
  const more = [...new Set(root('a.btn-mulu[href]').toArray().map(n => root(n).attr('href')!))];
  if (more.length) {
    if (more.length !== 1 || more[0] !== `/index/${id}/1/`) throw new Error('Catalog continuation changed.');
    const first = load(await getText(new URL(more[0], SITE)));
    const options = first('select').first().find('option').toArray().map(n => first(n).attr('value') ?? '');
    if (options.length < 2 || options.length > 100 || options[0] !== rootPath || options.some((path, i) => i > 0 && path !== `/index/${id}/${i}/`)) throw new Error('Complete catalog page list is missing or invalid.');
    options.slice(1).forEach((path, i) => pages.push({ path, $: i === 0 ? first : null }));
  }
  const items: Chapter[] = [], seen = new Set<string>();
  for (const page of pages) {
    const $ = page.$ ?? load(await getText(new URL(page.path, SITE)));
    const css = $('style').toArray().map(n => $(n).text()).join('\n');
    const selectors = [...css.matchAll(/(\.section-list\.ycxsid\s*>\s*li:nth-(?:last-)?child\(\d+\))\s*\{\s*display\s*:\s*none\s*;?\s*\}/gu)].map(m => m[1]!);
    if ($('.section-list.ycxsid').length && !selectors.length) throw new Error('Catalog visibility rules are missing.');
    // Resolve every position against the original tree before removing any hidden item.
    if (selectors.length) $(selectors.join(',')).remove();
    const links = $('.section-list').last().find('a[href]').toArray();
    if (!links.length) throw new Error('Chapter catalog page is empty.');
    for (const node of links) {
      const url = sourceUrl($(node).attr('href') ?? ''), key = url?.pathname.match(new RegExp(`^/read/\\d+/${id}/(\\d+)\\.html$`, 'u'))?.[1], title = clean($(node).text());
      if (!key || !title || seen.has(key)) throw new Error('Invalid or duplicate chapter in the complete catalog.');
      seen.add(key); items.push({ id: `chapter:${id}:${key}`, title, order: items.length, url: url!.href, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: null, attributes: [] });
      if (items.length > 5000) throw new Error('Chapter catalog exceeds the host limit; it has not been truncated.');
    }
  }
  if (catalogs.size >= 8) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(id, { at: Date.now(), value: items }); return items;
}
function listingIds($: ReturnType<typeof load>, selector: string) {
  const ids = new Set<string>(); $(selector).each((_, node) => { const u = sourceUrl($(node).attr('href') ?? '');
    const id = u?.pathname.match(/^\/book\/(\d+)\/$/u)?.[1]; if (id) ids.add(id); }); return [...ids];
}
function cover(value: string) {
  if (!value) return null; const u = sourceUrl(value);
  if (!u || u.search || u.hash || !/^\/img\/\d+\.(?:jpe?g|png|webp)$/iu.test(u.pathname)) return null;
  return ctx().resource.proxy({ kind: 'image', url: u.href, headers: { Accept: 'image/*', Referer: `${SITE}/` } });
}
async function getText(url: URL, body?: string) {
  if (url.origin !== SITE) throw new Error('Source URL is outside its origin.');
  const r = await ctx().http.fetch(url, { method: body === undefined ? 'GET' : 'POST', ...(body === undefined ? {} : { body }),
    headers: { Accept: 'text/html', Referer: `${SITE}/`, 'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': `MgRead-Source/${ctx().plugin.version} (${ctx().plugin.id})` }, signal: AbortSignal.timeout(15000) });
  if (!r.ok || (r.url && new URL(r.url).origin !== SITE)) ctx().errors.raise({ code: 'source_access_blocked', message: `少年小说网暂不可用（HTTP ${r.status}）。` });
  const text = await r.text(); if (Buffer.byteLength(text) > 2 * 1024 * 1024) throw new Error('Source page exceeds the bounded size.');
  if (/<title[^>]*>[^<]*(?:Just a moment|安全验证|访问限制)/iu.test(text)) ctx().errors.raise('source_access_blocked'); return text;
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
function bookId(value: string) { const m = /^book:(\d+)$/u.exec(value); if (!m) throw new Error('Invalid book ID.'); return m[1]!; }
function clean(value: string) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
