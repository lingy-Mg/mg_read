/**
 * UAA 公开小说：书库推荐快照、JSON 搜索、SSR 详情/完整目录/游客正文。
 * 所有页面 IO 使用公开 WebView 的原生 Profile；串行操作、复用宿主页，不读取 Cookie/令牌或伪造 UA。
 * activate 清理有界元数据与分页缓存；19 位上游 ID 始终保留字符串，会员/付费目录完整保留并禁止读取。
 * 正文请求至少间隔 3.5 秒；验证页、隐藏预览、目录不一致及宿主超限明确失败，不截断或持久化正文。
 */
import { createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { load } from 'cheerio';
import type { MgReadPluginContext } from '@mgread/source-api';

const SITE = 'https://www.uaa.com';
type Raw = { id: string; title: string; author: string | null; cover: string; description: string | null;
  words: number | null; chapterCount: number | null; status: string };
type Chapter = { id: string; title: string; order: number; url: string; volumeTitle: null;
  wordCount: null; updatedAt: null; isLocked: boolean; attributes: never[] };
type Page = Awaited<ReturnType<MgReadPluginContext['webview']['open']>>;
let context: MgReadPluginContext | undefined, queue: Promise<unknown> = Promise.resolve(), lastBodyAt = 0;
const details = new Map<string, { at: number; data: Raw; chapters: Chapter[] }>();
const snapshots = new Map<string, { at: number; items: Raw[] }>();
const searches = new Map<string, { at: number; items: Raw[]; total: number; pages: number }>();
export async function activate(next: MgReadPluginContext) {
  context = next; queue = Promise.resolve(); lastBodyAt = 0; details.clear(); snapshots.clear(); searches.clear();
  next.log.info('uaa_novel_activated');
}
export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim(); if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${digest(query)}`, pos = position(request.cursor, scope), key = `${scope}:${pos.page}`;
  let hit = searches.get(key);
  if (!hit || Date.now() - hit.at > 300000) {
    const value = await withPage(async page => {
      const current = await page.getUrl();
      if (!sourceUrl(current)) await navigate(page, new URL('/novel/list', SITE), 'cn-lcard__t');
      const url = new URL('/novel/load', SITE);
      url.search = new URLSearchParams({ keyword: query, page: String(pos.page), size: '20' }).toString();
      const response = await page.fetch({ url: url.href, responseType: 'json', timeoutMs: 20000 });
      if (response.status !== 200 || (response.url && !sourceUrl(response.url))) blocked();
      const json = record(response.body), model = record(json.model);
      if (json.code !== 0 || !Array.isArray(model.data)) blocked();
      const items = model.data.map(row => apiSummary(record(row)));
      if (new Set(items.map(x => x.id)).size !== items.length) throw new Error('Search has duplicate upstream IDs.');
      const total = count(model.totalCount), pages = count(model.totalPage);
      if (total === null || pages === null || items.length > 20 || (items.length === 0 && pos.page <= pages && total > 0)) throw new Error('Invalid search pagination metadata.');
      return { at: Date.now(), items, total, pages };
    });
    if (searches.size >= 32) searches.delete(searches.keys().next().value!); searches.set(key, value); hit = value;
  }
  const slice = paginate(hit.items, pos.offset, request.pageSize);
  return { items: slice.items.map(summary), totalCount: hit.total,
    nextCursor: slice.end < hit.items.length ? `${scope}:${pos.page}:${slice.end}` : pos.page < hit.pages ? `${scope}:${pos.page + 1}:0` : null };
}
export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) { return { items: [], nextCursor: null }; }
export async function discover(request: { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number }) {
  if (request.target !== null && !/^library:[a-f0-9]{12}$/u.test(request.target)) throw new Error('Invalid library target.');
  if (request.collectionId !== null && request.collectionId !== 'uaa:library') throw new Error('Invalid library collection.');
  if (request.target === null && (request.cursor !== null || request.collectionId !== null)) throw new Error('Invalid root discovery request.');
  let target = request.target, items: Raw[];
  if (target === null) {
    const $ = load(await html('/novel/list', 'cn-lcard__t')), found = new Map<string, Raw>();
    $('.cn-lcard').each((_, node) => {
      const row = $(node), url = sourceUrl(row.attr('href') ?? ''), id = url?.pathname === '/novel/intro' ? url.searchParams.get('id') : null;
      const title = clean(row.find('.cn-lcard__t').text());
      if (!id || !nativeId(id) || !title) throw new Error('Library card identity or title is missing.');
      if (!found.has(id)) found.set(id, { id, title, author: clean(row.find('.cn-lcard__byname').first().text()) || null,
        cover: row.find('img').first().attr('src') ?? '', description: null, words: null, chapterCount: null, status: 'unknown' });
    });
    items = [...found.values()]; if (!items.length) throw new Error('Library recommendations are missing.');
    target = `library:${digest(JSON.stringify(items))}`;
    if (snapshots.size >= 4) snapshots.delete(snapshots.keys().next().value!); snapshots.set(target, { at: Date.now(), items });
  } else {
    const hit = snapshots.get(target); if (!hit || Date.now() - hit.at > 300000) throw new Error('Library snapshot expired; refresh discovery.'); items = hit.items;
  }
  const pos = position(request.cursor, target);
  if (pos.page !== 1) throw new Error('Invalid library snapshot page.');
  const slice = paginate(items, pos.offset, request.pageSize), entries = slice.items.map(data => ({ content: summary(data), rank: null, metric: null, recommendation: null }));
  const continuation = slice.end < items.length ? { target, cursor: `${target}:1:${slice.end}` } : null;
  if (request.collectionId !== null) return { kind: 'append', collectionId: 'uaa:library', items: entries, continuation };
  return { kind: 'document', document: { components: [{ type: 'section', id: 'uaa-library-section', title: '小说书库', subtitle: null, icon: 'book',
    children: [{ type: 'contentCollection', id: 'uaa:library', layout: 'coverGrid', items: entries, continuation }] }] } };
}
export async function getDetail(request: { id: string }) {
  const value = await detail(bookId(request.id));
  return { ...summary(value.data), description: value.data.description, aliases: [], catalogUrl: `${SITE}/novel/intro?id=${value.data.id}` };
}
export async function getChapters(request: { id: string; refresh?: boolean }) {
  return { items: (await detail(bookId(request.id), request.refresh === true)).chapters, groups: [] };
}
export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id), value = await detail(id), chapter = value.chapters.find(c => c.id === request.chapterId);
  if (!chapter) throw new Error('Chapter identity does not belong to this novel.');
  if (chapter.isLocked) blocked('该章节需要会员或付费权限，未提供游客完整正文。');
  const body = await withPage(async page => {
    await delay(Math.max(0, lastBodyAt + 3500 - Date.now())); lastBodyAt = Date.now();
    return navigate(page, new URL(chapter.url), 'reader-body');
  });
  const $ = load(body), reader = $('.reader-body'), visible = $('body').clone(); visible.find('script,style').remove();
  if (reader.length !== 1 || /以下正文内容已隐藏/u.test(visible.text()) || /请登录后阅读|请先登录|购买本章/u.test(reader.text())) blocked('来源返回隐藏正文或受限预览，未提供完整章节。');
  const backlink = $('a[href]').toArray().some(n => {
    const url = sourceUrl($(n).attr('href') ?? ''); return url?.pathname === '/novel/intro' && url.searchParams.get('id') === id;
  });
  if (!backlink || !clean($('h1.reader-chap').text())) throw new Error('Reader page identity is missing.');
  const text = reader.children('p').toArray().map(n => clean($(n).text())).filter(Boolean).join('\n\n');
  if (!text) blocked('来源未返回游客章节正文。');
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter exceeds the host text limit; it has not been truncated.');
  return { chapterId: chapter.id, contentKind: 'novel', title: chapter.title, updatedAt: null, text, pages: [], media: null };
}
async function detail(id: string, refresh = false) {
  const hit = details.get(id); if (!refresh && hit && Date.now() - hit.at < 120000) return hit;
  const $ = load(await html(`/novel/intro?id=${id}`, 'ndc-row')), title = clean($('h1.nd-t2').text());
  if (!title) throw new Error('Novel title is missing.');
  const chapters: Chapter[] = [], seen = new Set<string>();
  $('#ndcBody a.ndc-row').each((_, node) => {
    const row = $(node), url = sourceUrl(row.attr('href') ?? ''), key = url?.searchParams.get('id'), name = clean(row.attr('title') ?? ''), permission = clean(row.find('.ndc-acc').text());
    if (!key || !nativeId(key) || url?.pathname !== '/novel/chapter' || !name || seen.has(key) || Number(row.attr('data-no')) !== chapters.length + 1) throw new Error('Novel catalog identity or sequence is invalid.');
    if (!permission) throw new Error('Chapter permission is missing.');
    seen.add(key); chapters.push({ id: `chapter:${id}:${key}`, title: name, order: chapters.length, url: url.href,
      volumeTitle: null, wordCount: null, updatedAt: null, isLocked: permission !== '游客', attributes: [] });
  });
  const volumeCounts = $('#ndcBody .ndc-vol__h').toArray().map(n => Number(clean($(n).text()).match(/(\d+)\s*章/u)?.[1]));
  if (!chapters.length || chapters.length > 5000 || (volumeCounts.length && (volumeCounts.some(n => !Number.isSafeInteger(n)) || volumeCounts.reduce((a, b) => a + b, 0) !== chapters.length))) throw new Error('Catalog is incomplete or exceeds the host limit; it has not been truncated.');
  const wordText = $('.nd-stat').toArray().find(n => clean($(n).find('.l').text()) === '字数');
  const state = clean($('.nd-tag').first().text());
  const data: Raw = { id, title, author: clean($('.nd-author__lk').first().text()) || null, cover: $('.nd-cover img').first().attr('src') ?? '',
    description: clean($('.nd-synopsis').text()) || null, words: wordText ? wordNumber(clean($(wordText).find('.n').text())) : null,
    chapterCount: chapters.length, status: /完结|完本/u.test(state) ? 'completed' : /连载/u.test(state) ? 'ongoing' : 'unknown' };
  const value = { at: Date.now(), data, chapters }; if (details.size >= 32) details.delete(details.keys().next().value!); details.set(id, value); return value;
}
function apiSummary(row: Record<string, unknown>): Raw {
  if (typeof row.id !== 'string' || !nativeId(row.id) || !string(row.title)) throw new Error('Search novel identity is missing.');
  return { id: row.id, title: string(row.title), author: string(row.authors) || null, cover: string(row.coverUrl),
    description: clean(string(row.brief)) || null, words: count(row.wordCount), chapterCount: count(row.chapterCount), status: 'unknown' };
}
function summary(data: Raw) {
  return { id: `book:${data.id}`, title: data.title, contentKind: 'novel', coverOrientation: 'portrait', author: data.author,
    url: `${SITE}/novel/intro?id=${data.id}`, coverUrl: cover(data.cover), description: data.description?.slice(0, 180) ?? null,
    language: null, status: data.status, access: 'unknown', wordCount: data.words, chapterCount: data.chapterCount,
    publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] };
}
function cover(raw: string) {
  let url: URL; try { url = new URL(raw); } catch { return null; }
  if (url.origin !== 'https://cdn.uameta.ai' || url.username || url.password || url.search || url.hash || !/^\/file\/bucket-media\/image\/cover\/[a-f0-9]+\.(?:png|jpe?g|webp)$/iu.test(url.pathname)) return null;
  return ctx().resource.proxy({ kind: 'image', url: url.href, headers: { Accept: 'image/*', Referer: `${SITE}/` } });
}
function html(path: string, marker: string) { return withPage(page => navigate(page, new URL(path, SITE), marker)); }
async function navigate(page: Page, url: URL, marker: string) {
  if (!sourceUrl(url.href)) throw new Error('Source navigation left its origin.');
  await page.navigate(url.href, { timeoutMs: 20000 });
  let text = await page.getHtml({ timeoutMs: 20000 });
  if (!text.includes(marker)) {
    try { await page.waitForText({ text: marker, scope: 'html', timeoutMs: 15000 }); }
    catch { blocked('来源页面暂不可读或需要浏览器验证，请完成验证后重试。'); }
    text = await page.getHtml({ timeoutMs: 20000 });
  }
  const current = sourceUrl(await page.getUrl());
  if (!current || current.pathname !== url.pathname || current.searchParams.get('id') !== url.searchParams.get('id')) blocked();
  if (Buffer.byteLength(text) > 3 * 1024 * 1024) throw new Error('Source page exceeds the bounded size.');
  if (/<title[^>]*>[^<]*(?:Just a moment|Access denied|安全验证)/iu.test(text)) blocked('来源需要浏览器验证，请完成验证后重试。'); return text;
}
function withPage<T>(action: (page: Page) => Promise<T>): Promise<T> {
  const task = queue.then(async () => action(await ctx().webview.open({ visible: false, timeoutMs: 20000 })));
  queue = task.then(() => undefined, () => undefined); return task;
}
function sourceUrl(raw: string) { try { const url = new URL(raw, SITE); return url.origin === SITE && !url.username && !url.password ? url : null; } catch { return null; } }
function paginate<T>(items: T[], offset: number, size: number) { if (offset > items.length) throw new Error('Cursor exceeds its source page.');
  const selected = items.slice(offset, offset + Math.max(1, Math.min(50, Math.floor(size)))); return { items: selected, end: offset + selected.length }; }
function position(cursor: string | null, scope: string) { if (cursor === null) return { page: 1, offset: 0 };
  if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another scope.'); const m = /^(\d+):(\d+)$/u.exec(cursor.slice(scope.length + 1));
  const page = Number(m?.[1]), offset = Number(m?.[2]); if (!Number.isSafeInteger(page) || page < 1 || page > 1000000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 5000) throw new Error('Invalid cursor.'); return { page, offset }; }
function bookId(raw: string) { const value = /^book:([1-9]\d{0,19})$/u.exec(raw)?.[1]; if (!value) throw new Error('Invalid novel ID.'); return value; }
function nativeId(raw: string) { return /^[1-9]\d{0,19}$/u.test(raw); }
function digest(raw: string) { return createHash('sha256').update(raw).digest('hex').slice(0, 12); }
function count(raw: unknown) { return typeof raw === 'number' && Number.isSafeInteger(raw) && raw >= 0 ? raw : null; }
function wordNumber(raw: string) { const m = /^(\d+(?:\.\d+)?)(万|亿)?$/u.exec(raw); return m ? Math.round(Number(m[1]) * (m[2] === '亿' ? 1e8 : m[2] === '万' ? 1e4 : 1)) : null; }
function record(raw: unknown): Record<string, unknown> { return raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? raw as Record<string, unknown> : {}; }
function string(raw: unknown) { return typeof raw === 'string' ? clean(raw) : ''; }
function clean(raw: string) { return raw.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function blocked(message = '来源公开页面暂不可用，请稍后重试。'): never { return ctx().errors.raise({ code: 'source_access_blocked', message }); }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
