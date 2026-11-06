/**
 * 七猫小说公开接口来源；只拥有分类、分页、作品身份、目录投影和正文解码。
 * activate 保存公开 Context 并清空有界详情缓存；所有网络经 ctx.http，封面交给 Runtime。
 * 请求签名与正文 AES 在本地完成，不调用中转服务，不持有账号、Cookie 或浏览器验证令牌。
 * 作品/章节使用官方数字 ID。搜索页码为 1-based，响应 meta.page 为 0-based；目录不截断。
 */
import { createHash, createDecipheriv } from 'node:crypto';
import type { MgReadPluginContext } from '@mgread/source-api';

type Json = Record<string, unknown>;
type Search = { query: string; cursor: string | null; pageSize: number };
type Discovery = { target: string | null; cursor: string | null; collectionId: string | null; pageSize: number };
const API = 'https://api-bc.wtzw.com';
const CHAPTER_API = 'https://api-ks.wtzw.com';
const SITE = 'https://www.qimao.com';
const SIGNING_KEY = 'd3dGiJc651gSQ8w1';
const TEXT_KEY = Buffer.from('242ccb8230d709e1');
const categories = [
  ['203', '都市人生'], ['202', '玄幻奇幻'], ['205', '武侠仙侠'],
  ['56', '历史'], ['1', '现代言情'], ['2', '古代言情'],
] as const;
let context: MgReadPluginContext | undefined;
const detailCache = new Map<string, { at: number; value: Json }>();

export async function activate(next: MgReadPluginContext) {
  context = next;
  detailCache.clear();
  next.log.info('qimao_source_activated');
}

export async function search(request: Search) {
  const query = request.query.trim();
  if (!query) return { items: [], nextCursor: null, totalCount: 0 };
  const scope = `search:${createHash('sha256').update(query).digest('hex').slice(0, 20)}`;
  const position = decodeCursor(request.cursor, scope);
  const data = await getJson(API, '/api/v5/search/words', {
    gender: '3', imei_ip: '2937357107', page: String(position.page), wd: query,
  });
  const page = paginate(array(data.books).map(summary), data.meta, position, request.pageSize, scope, 'search');
  return { items: page.items, nextCursor: page.cursor, totalCount: null };
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return { items: [], nextCursor: null };
}

export async function discover(request: Discovery) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Invalid initial discovery request.');
    return { kind: 'document' as const, document: { components: [{
      type: 'section', id: 'qimao-categories', title: '七猫小说', subtitle: null, icon: 'book',
      children: [{ type: 'categoryCollection', id: 'qimao-category-list', layout: 'chips',
        categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'book' })),
      }],
    }] } };
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (!category) throw new Error('Invalid discovery target.');
  const collectionId = `qimao:${category[0]}`;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error('Invalid discovery collection.');
  const position = decodeCursor(request.cursor, request.target);
  const data = await getJson(API, '/api/v4/category/get-list', {
    gender: '2', category_id: category[0], need_filters: '1', page: String(position.page), need_category: '1',
  });
  const page = paginate(array(data.books).map(summary), data.meta, position, request.pageSize, request.target, 'category');
  const items = page.items.map(content => ({ content, rank: null, metric: null, recommendation: null }));
  const continuation = page.cursor === null ? null : { target: request.target, cursor: page.cursor };
  if (request.collectionId !== null) return { kind: 'append' as const, collectionId, items, continuation };
  return { kind: 'document' as const, document: { components: [{
    type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'book',
    children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
  }] } };
}

export async function getDetail(request: { id: string }) {
  const id = bookId(request.id);
  const cached = detailCache.get(id);
  let book: Json;
  if (cached && Date.now() - cached.at < 120_000) book = cached.value;
  else {
    const data = await getJson(API, '/api/v4/book/detail', { id, imei_ip: '2937357107', teeny_mode: '0' });
    book = object(data.book);
    if (String(book.id) !== id) throw new Error('Book identity does not match.');
    if (detailCache.size >= 32) detailCache.delete(detailCache.keys().next().value!);
    detailCache.set(id, { at: Date.now(), value: book });
  }
  return { ...summary(book), description: clean(book.intro) || null,
    aliases: clean(book.alias_title) ? [clean(book.alias_title)] : [], catalogUrl: `${SITE}/shuku/${id}/` };
}

export async function getChapters(request: { id: string }) {
  const id = bookId(request.id);
  const data = await getJson(CHAPTER_API, '/api/v1/chapter/chapter-list', { id });
  const rows = array(data.chapter_lists);
  if (rows.length === 0 || rows.length > 5000) throw new Error('Chapter catalog is empty or exceeds the host limit.');
  const seen = new Set<string>();
  const explicitlyFree = String(object(data.meta).pay_status) === '0';
  const items = rows.map((row, order) => {
    const chapter = numericId(row.id);
    if (seen.has(chapter)) throw new Error('Chapter catalog contains duplicate IDs.');
    seen.add(chapter);
    const title = clean(row.title);
    if (!title) throw new Error('Chapter title is missing.');
    return { id: `chapter:${id}:${chapter}`, title, order, url: `${SITE}/shuku/${id}-${chapter}/`,
      volumeTitle: null, wordCount: count(row.words), updatedAt: null,
      isLocked: explicitlyFree ? false : null, attributes: [] };
  });
  return { items, groups: [] };
}

export async function getContent(request: { id: string; chapterId: string }) {
  const id = bookId(request.id);
  const match = /^chapter:(\d+):(\d+)$/u.exec(request.chapterId);
  if (!match || match[1] !== id) throw new Error('Chapter identity does not match its book.');
  const data = await getJson(CHAPTER_API, '/api/v1/chapter/content', { id, chapterId: match[2]! });
  const encoded = String(data.content ?? '');
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(encoded) || encoded.length > 300_000) throw new Error('Invalid encrypted chapter body.');
  const bytes = Buffer.from(encoded, 'base64');
  if (bytes.length <= 16 || (bytes.length - 16) % 16 !== 0) throw new Error('Invalid encrypted chapter length.');
  const decipher = createDecipheriv('aes-128-cbc', TEXT_KEY, bytes.subarray(0, 16));
  const text = Buffer.concat([decipher.update(bytes.subarray(16)), decipher.final()]).toString('utf8').replace(/^\uFEFF/u, '').trim();
  if (!text || /^(?:<!doctype|<html|\{"(?:code|error)"|访问限制)/iu.test(text)) throw new Error('Chapter body is unavailable.');
  if (Buffer.byteLength(text, 'utf8') > 48 * 1024) throw new Error('Chapter body exceeds the host text limit; it has not been truncated.');
  return { chapterId: request.chapterId, contentKind: 'novel', title: null, updatedAt: null, text, pages: [], media: null };
}

function summary(book: Json) {
  const id = numericId(book.id);
  const title = clean(book.original_title) || clean(book.title);
  if (!title) throw new Error('Book title is missing.');
  const latestTitle = clean(book.latest_chapter_title);
  const latestId = /^\d+$/u.test(String(book.latest_chapter_id)) ? String(book.latest_chapter_id) : null;
  return { id: `book:${id}`, title, contentKind: 'novel', coverOrientation: 'portrait',
    author: clean(book.original_author) || clean(book.author) || null, url: `${SITE}/shuku/${id}/`,
    coverUrl: cover(book.image_link), description: clean(book.intro).slice(0, 180) || null,
    language: 'zh-CN', status: String(book.is_over) === '1' ? 'completed' : String(book.is_over) === '0' ? 'ongoing' : 'unknown',
    access: 'unknown', wordCount: count(book.words_num), chapterCount: count(book.chapters),
    publishedAt: null, updatedAt: timestamp(book.update_time),
    latestChapter: latestTitle ? { id: latestId === null ? null : `chapter:${id}:${latestId}`, title: latestTitle,
      url: latestId === null ? null : `${SITE}/shuku/${id}-${latestId}/`, updatedAt: timestamp(book.update_time) } : null,
    categories: [clean(book.category1_name), clean(book.category2_name)].filter(Boolean),
    tags: clean(book.ptags).split(',').filter(Boolean).slice(0, 32), attributes: [] };
}

function cover(value: unknown) {
  if (typeof value !== 'string' || !value) return null;
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.username || url.password || url.port ||
    !['cdn.qimao.com', 'cdn.wtzw.com'].includes(url.hostname) || !url.pathname.startsWith('/bookimg/')) return null;
  return ctx().resource.proxy({ kind: 'image', url: url.href, headers: { Accept: 'image/*', Referer: `${SITE}/` } });
}

async function getJson(base: string, path: string, parameters: Record<string, string>) {
  const headers: Record<string, string> = { 'app-version': '51110', platform: 'android', reg: '0',
    AUTHORIZATION: '', 'application-id': 'com.kmxs.reader', 'net-env': '1', channel: 'unknown', 'qm-params': '' };
  headers.sign = sign(headers);
  const url = new URL(path, base);
  url.search = new URLSearchParams({ ...parameters, sign: sign(parameters) }).toString();
  const response = await ctx().http.fetch(url, { headers, redirect: 'error', signal: AbortSignal.timeout(15_000) });
  if (!response.ok) ctx().errors.raise({ code: 'source_access_blocked', message: `七猫接口返回 HTTP ${response.status}。` });
  const text = await response.text();
  if (Buffer.byteLength(text) > 2 * 1024 * 1024) throw new Error('Source response exceeds the bounded metadata size.');
  const result = object(JSON.parse(text));
  const data = object(result.data);
  if (Object.keys(data).length === 0) ctx().errors.raise({ code: 'source_access_blocked', message: '七猫接口未返回可读数据。' });
  return data;
}

function paginate<T>(items: T[], metadata: unknown, position: { page: number; offset: number }, pageSize: number, scope: string, kind: 'category' | 'search') {
  const size = Math.max(1, Math.min(50, Math.floor(pageSize)));
  if (position.offset > items.length) throw new Error('Cursor offset exceeds its upstream page.');
  const selected = items.slice(position.offset, position.offset + size);
  const end = position.offset + selected.length;
  const meta = object(metadata);
  const totalPages = count(kind === 'search' ? meta.total_page : meta.total_pages);
  const upstreamPage = count(meta.page);
  const matchesPage = upstreamPage === (kind === 'search' ? position.page - 1 : position.page);
  const cursor = end < items.length ? encodeCursor(scope, position.page, end)
    : matchesPage && items.length > 0 && totalPages !== null && position.page < totalPages
      ? encodeCursor(scope, position.page + 1, 0) : null;
  return { items: selected, cursor };
}

function encodeCursor(scope: string, page: number, offset: number) { return `${scope}:${page}:${offset}`; }
function decodeCursor(cursor: string | null, scope: string) {
  if (cursor === null) return { page: 1, offset: 0 };
  if (!cursor.startsWith(`${scope}:`)) throw new Error('Cursor belongs to another query or category.');
  const match = /^(\d+):(\d+)$/u.exec(cursor.slice(scope.length + 1));
  const page = Number(match?.[1]); const offset = Number(match?.[2]);
  if (!Number.isSafeInteger(page) || page < 1 || page > 10000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 50) throw new Error('Invalid cursor.');
  return { page, offset };
}
function sign(value: Record<string, string>) { return createHash('md5').update(Object.keys(value).sort().map(key => `${key}=${value[key]}`).join('') + SIGNING_KEY).digest('hex'); }
function bookId(value: string) { const match = /^book:(\d+)$/u.exec(value); if (!match) throw new Error('Invalid book ID.'); return match[1]!; }
function numericId(value: unknown) { const id = String(value ?? ''); if (!/^\d+$/u.test(id)) throw new Error('Invalid upstream ID.'); return id; }
function object(value: unknown): Json { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Json : {}; }
function array(value: unknown): Json[] { return Array.isArray(value) ? value.map(object) : []; }
function count(value: unknown) { if (value === null || value === undefined || value === '') return null; const n = Number(value); return Number.isSafeInteger(n) && n >= 0 ? n : null; }
function timestamp(value: unknown) { const n = count(value); return n !== null && n > 0 && n < 10_000_000_000 ? new Date(n * 1000).toISOString() : null; }
function clean(value: unknown) { return typeof value === 'string' ? value.replace(/<[^>]*>/gu, '').replace(/&nbsp;/gu, ' ').replace(/&amp;/gu, '&').replace(/[\s\u3000]+/gu, ' ').trim() : ''; }
function ctx(): MgReadPluginContext { if (!context) throw new Error('Source is not activated.'); return context; }
