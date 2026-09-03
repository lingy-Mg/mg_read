/**
 * 米读小说原生数据源。
 *
 * 职责：直接调用米读公开 H5 搜索/推荐接口、复现当前 H5 的 SaaS 目录签名并读取正文 CDN。
 * 生命周期：activate 注入 Runtime 上下文；书籍投影、目录与匿名 tuid 只保存在当前进程内。
 * IO：所有请求只经 ctx.http；封面只登记到 ctx.resource.proxy；不读取系统密钥链或旧规则配置。
 * 稳定标识：作品使用上游 32 位 hash_id，章节使用上游 chapterId。
 */
import { createHash } from 'node:crypto';
import type { MgReadPluginContext } from '@mgread/source-api';

type Context = MgReadPluginContext;
type Json = Record<string, unknown>;
type BookProjection = {
  readonly id: string;
  readonly title: string;
  readonly author: string;
  readonly cover: string;
  readonly description: string;
  readonly category: string;
  readonly tags: readonly string[];
  readonly chapterCount: number | null;
  readonly status: 'ongoing' | 'completed' | 'unknown';
};
type CatalogProjection = { readonly title: string; readonly rows: readonly Json[] };

const apiBase = 'https://api.midukanshu.com';
const saasBase = 'https://saasapi.midukanshu.com';
const h5Base = 'https://m.midukanshu.com';
const staticBase = 'https://book.midukanshu.com';
const signKey = 'T^xS0x31XL%wEowC';
const commonHeaders = Object.freeze({
  Accept: 'application/json, text/plain, */*',
  Origin: h5Base,
  Referer: `${h5Base}/novel/index.html`,
  'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/136.0.0.0 Mobile Safari/537.36',
});
const categories = Object.freeze([
  ['fantasy', '玄幻'], ['urban', '都市'], ['xianxia', '仙侠'], ['wuxia', '武侠'],
  ['history', '历史'], ['military', '军事'], ['science-fiction', '科幻'], ['game', '游戏'],
  ['mystery', '悬疑'], ['fan-fiction', '同人次元'], ['ancient-romance', '古代言情'],
  ['modern-romance', '现代言情'], ['light-novel', '轻小说'],
] as const);

let context: Context | undefined;
let anonymousTuid = '';
const books = new Map<string, BookProjection>();
const catalogs = new Map<string, Promise<CatalogProjection>>();

export async function activate(next: Context): Promise<void> {
  context = next;
  anonymousTuid = `${Math.random().toString(36).slice(2)}_Mdqtt.saas`;
  books.clear();
  catalogs.clear();
  next.log.info('source_activated');
}

export async function search(request: { query: string; cursor: string | null; pageSize: number }) {
  const query = request.query.trim();
  if (query === '') return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, 'search');
  const limit = clamp(request.pageSize);
  const values = (await searchBooks(query, page)).slice(0, limit);
  return frozen({
    items: values.map(summary),
    nextCursor: values.length >= limit && page < 100 ? `search:${page + 1}` : null,
    totalCount: null,
  });
}

export async function searchSuggestions(_request: { cursor: string | null; pageSize: number }) {
  return frozen({ items: [], nextCursor: null });
}

export async function discover(request: {
  target: string | null;
  cursor: string | null;
  collectionId: string | null;
  pageSize: number;
}) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
    const recommended = (await recommendations()).slice(0, Math.min(12, clamp(request.pageSize)));
    const components: object[] = [];
    if (recommended.length > 0) {
      components.push({
        type: 'section', id: 'midu-recommended', title: '猜你喜欢', subtitle: '米读当前推荐', icon: 'recommendation',
        children: [{
          type: 'contentCollection', id: 'midu-recommended-list', layout: 'shelf', continuation: null,
          items: recommended.map((book) => frozen({ content: summary(book), rank: null, metric: null, recommendation: null })),
        }],
      });
    }
    components.push({
      type: 'section', id: 'midu-categories', title: '小说分类', subtitle: '按题材发现作品', icon: 'book',
      children: [{
        type: 'categoryCollection', id: 'midu-category-list', layout: 'chips',
        categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: categoryIcon(id) })),
      }],
    });
    return frozen({ kind: 'document' as const, document: { components } });
  }
  const category = categories.find(([id]) => request.target === `category:${id}`);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  const page = cursorPage(request.cursor, request.target);
  const limit = clamp(request.pageSize);
  const [, title] = category;
  const values = (await searchBooks(title, page)).slice(0, limit);
  const collectionId = `midu-category:${category[0]}`;
  const items = values.map((book) => frozen({ content: summary(book), rank: null, metric: null, recommendation: null }));
  const continuation = values.length >= limit && page < 100
    ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` })
    : null;
  if (request.collectionId !== null) {
    if (request.collectionId !== collectionId) throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append' as const, collectionId, items, continuation });
  }
  return frozen({
    kind: 'document' as const,
    document: { components: [{
      type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: categoryIcon(category[0]),
      children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
    }] },
  });
}

export async function getDetail(request: { id: string }) {
  const id = contentId(request.id);
  let projection = books.get(id);
  if (projection === undefined) {
    const catalog = await fetchCatalog(id);
    projection = {
      id, title: catalog.title, author: '', cover: '', description: '', category: '', tags: [],
      chapterCount: catalog.rows.length, status: 'unknown',
    };
    books.set(id, projection);
  }
  const item = summary(projection);
  return frozen({ ...item, aliases: [], catalogUrl: readerUrl(id) });
}

export async function getChapters(request: { id: string }) {
  const book = contentId(request.id);
  const catalog = await fetchCatalog(book);
  const items = catalog.rows.flatMap((row, index) => {
    const nativeId = text(row.chapterId ?? row.chapter_id);
    const title = clean(text(row.title ?? row.chapterTitle ?? row.name)) ||
      (row.no === undefined ? '' : `第${String(row.no)}章`);
    if (nativeId === '' || title === '') return [];
    return [frozen({
      id: chapterId(book, nativeId), title, order: index, url: contentUrl(book, nativeId), volumeTitle: '正文',
      wordCount: null, updatedAt: null, isLocked: null, attributes: [],
    })];
  });
  if (items.length === 0) throw new Error('No chapters found.');
  const group = frozen({ id: `group:${book}:default`, title: '正文', order: 0, episodes: items });
  return frozen({ items, groups: [group] });
}

export async function getContent(request: { id: string; chapterId: string }) {
  const book = contentId(request.id);
  const nativeId = nativeChapterId(request.chapterId, book);
  const value = (await fetchText(contentUrl(book, nativeId), { headers: commonHeaders })).replaceAll('\r', '').trim();
  if (value === '') throw new Error('Chapter content is empty.');
  return frozen({
    chapterId: request.chapterId, contentKind: 'novel' as const, title: null, updatedAt: null,
    text: value, pages: [], media: null,
  });
}

async function searchBooks(query: string, page: number): Promise<BookProjection[]> {
  const payload = await postForm(`${apiBase}/fiction/search/search`, new URLSearchParams({ keyword: query, page: String(page - 1) }), `${h5Base}/novel/search.html`);
  const rows = Array.isArray(payload.data) ? payload.data : [];
  return rows.flatMap((value) => {
    const projection = projectBook(value);
    if (projection === null) return [];
    books.set(projection.id, projection);
    return [projection];
  });
}

async function recommendations(): Promise<BookProjection[]> {
  const payload = await postForm(`${apiBase}/fiction/recommend/searchPage`, new URLSearchParams(), `${h5Base}/novel/index.html`);
  const data = isRecord(payload.data) ? payload.data : {};
  const nodes = Array.isArray(data.recommendNode) ? data.recommendNode : [];
  const result: BookProjection[] = [];
  for (const node of nodes) {
    if (!isRecord(node) || !isRecord(node.nodeData) || !Array.isArray(node.nodeData.books)) continue;
    for (const raw of node.nodeData.books) {
      const projection = projectBook(raw);
      if (projection === null) continue;
      books.set(projection.id, projection);
      result.push(projection);
    }
  }
  return uniqueBooks(result);
}

function projectBook(raw: unknown): BookProjection | null {
  if (!isRecord(raw)) return null;
  const value = isRecord(raw.bookData) ? raw.bookData : raw;
  const id = text(value.book_id ?? value.id);
  const title = clean(text(value.title)) || clean(stripHtml(text(raw.emTitle ?? value.emTitle)));
  if (!/^[0-9a-f]{32}$/iu.test(id) || title === '') return null;
  const tags = Array.isArray(value.tags)
    ? value.tags.map((tag) => clean(isRecord(tag) ? text(tag.name ?? tag.title) : text(tag))).filter(Boolean)
    : [];
  const chapterCount = finiteNumber(value.chapterNum ?? value.chapter_num);
  return frozen({
    id, title, author: clean(text(value.author)), cover: safeUrl(text(value.cover ?? value.coverUrl)),
    description: clean(text(value.description)) || clean(stripHtml(text(raw.emDescription ?? value.emDescription))),
    category: clean(text(value.category)), tags, chapterCount,
    status: Number(value.end_status) === 1 ? 'completed' : Number(value.end_status) === 0 ? 'ongoing' : 'unknown',
  });
}

function summary(book: BookProjection) {
  const categoriesValue = book.category === '' ? [] : [book.category];
  return frozen({
    id: `midu:${book.id}`, title: book.title, contentKind: 'novel' as const, coverOrientation: 'portrait' as const,
    author: book.author || null, url: readerUrl(book.id), coverUrl: proxyImage(book.cover),
    description: book.description || null, language: 'zh-CN', status: book.status, access: 'unknown' as const,
    wordCount: null, chapterCount: book.chapterCount, publishedAt: null, updatedAt: null, latestChapter: null,
    categories: categoriesValue, tags: [...book.tags], attributes: [],
  });
}

async function fetchCatalog(book: string): Promise<CatalogProjection> {
  const cached = catalogs.get(book);
  if (cached !== undefined) return cached;
  const pending = loadCatalog(book).catch((error) => {
    catalogs.delete(book);
    throw error;
  });
  catalogs.set(book, pending);
  return pending;
}

async function loadCatalog(book: string): Promise<CatalogProjection> {
  const payload = await signedPost('/content/chapterList', { hash_id: book });
  if (Number(payload.code) !== 0) throw new Error(`Catalog request failed: ${clean(text(payload.message ?? payload.msg)) || 'unknown error'}.`);
  const data = isRecord(payload.data) ? payload.data : {};
  const title = clean(text(data.title)) || books.get(book)?.title || '';
  const url = safeUrl(text(data.url));
  let rows = extractRows(payload);
  if (url !== '') {
    const cdn = parseLooseJson(await fetchText(url, { headers: commonHeaders }));
    rows = extractRows(cdn);
  }
  if (title === '' || rows.length === 0) throw new Error('Catalog response is incomplete.');
  return frozen({ title, rows: Object.freeze(rows) });
}

async function signedPost(path: string, specific: Json): Promise<Json> {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const merged: Record<string, string> = {
    app: 'Mdqtt.saas', version: '300', nonce: String(Math.floor(Math.random() * 9000 + 1000)),
    time: timestamp, headerQueryTime: timestamp, tuid: anonymousTuid || `${Date.now()}_Mdqtt.saas`,
    app_source: '',
  };
  for (const [key, value] of Object.entries(specific)) {
    if (value !== undefined && value !== null && String(value) !== 'undefined' && String(value) !== 'null') merged[key] = String(value);
  }
  const canonical = `${Object.keys(merged).sort().map((key) => `${key}=${merged[key]}`).join('&')}&key=${signKey}`;
  const md5 = createHash('md5').update(canonical, 'utf8').digest('hex');
  merged.sign = Buffer.from([...md5].map((character) => character.charCodeAt(0) ^ 5)).toString('hex');
  const body = new URLSearchParams({ EncStr: Buffer.from(JSON.stringify(merged), 'utf8').toString('base64') });
  const response = await fetchText(`${saasBase}${path}`, {
    method: 'POST',
    headers: { ...commonHeaders, Referer: `${h5Base}/novel/reader.html`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  });
  const value = parseLooseJson(response);
  if (!isRecord(value)) throw new Error('Signed response is invalid.');
  return value;
}

async function postForm(url: string, body: URLSearchParams, referer: string): Promise<Json> {
  const raw = await fetchText(url, {
    method: 'POST', headers: { ...commonHeaders, Referer: referer, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  });
  const parsed = parseLooseJson(raw);
  if (!isRecord(parsed)) throw new Error('Source response is invalid.');
  return parsed;
}

async function fetchText(url: string, init: RequestInit): Promise<string> {
  const response = await requireContext().http.fetch(url, { ...init, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`Source request failed with status ${response.status}.`);
  return response.text();
}

function extractRows(value: unknown): Json[] {
  if (Array.isArray(value)) return value.filter(isRecord);
  if (!isRecord(value)) return [];
  for (const key of ['list', 'chapters', 'chapterList', 'chapter_list', 'rows']) {
    if (Array.isArray(value[key])) return value[key].filter(isRecord);
  }
  if (value.data !== undefined) {
    const nested = extractRows(value.data);
    if (nested.length > 0) return nested;
  }
  const volumes = value.volumeList ?? value.volumes ?? value.volume_list;
  if (Array.isArray(volumes)) return volumes.flatMap(extractRows);
  return [];
}

function parseLooseJson(raw: string): unknown {
  const textValue = raw.trim().replace(/^\uFEFF/u, '');
  try { return JSON.parse(textValue); } catch {
    const start = [...textValue].findIndex((character) => character === '{' || character === '[');
    if (start < 0) throw new Error('Source response is invalid.');
    for (let end = textValue.length; end > start; end -= 1) {
      try { return JSON.parse(textValue.slice(start, end)); } catch { /* keep trimming a gateway suffix */ }
    }
    throw new Error('Source response is invalid.');
  }
}

function contentId(id: string): string {
  const value = /^midu:([0-9a-f]{32})$/iu.exec(id)?.[1];
  if (value === undefined) throw new Error('Content ID is invalid.');
  return value.toLowerCase();
}

function chapterId(book: string, nativeId: string): string {
  return `midu:${book}:${encodeURIComponent(nativeId)}`;
}

function nativeChapterId(id: string, book: string): string {
  const raw = new RegExp(`^midu:${book}:([^:]+)$`, 'u').exec(id)?.[1];
  if (raw === undefined) throw new Error('Chapter ID is invalid.');
  const value = decodeURIComponent(raw);
  if (!/^[A-Za-z0-9._-]+$/u.test(value)) throw new Error('Chapter ID is invalid.');
  return value;
}

function readerUrl(book: string): string {
  return `${h5Base}/novel/reader.html?bookId=${book}&bookSource=&nodeId=undefined`;
}

function contentUrl(book: string, chapter: string): string {
  return `${staticBase}/book/chapter/master/${book}_${encodeURIComponent(chapter)}.txt`;
}

function proxyImage(value: string): string | null {
  if (value === '') return null;
  return requireContext().resource.proxy({ kind: 'image', url: value, headers: { Referer: `${h5Base}/` } });
}

function uniqueBooks(values: readonly BookProjection[]): BookProjection[] {
  const seen = new Set<string>();
  return values.filter((value) => !seen.has(value.id) && seen.add(value.id));
}

function categoryIcon(id: string) {
  if (id.includes('romance')) return 'romance' as const;
  if (id === 'fantasy') return 'fantasy' as const;
  if (id === 'xianxia' || id === 'wuxia') return 'wuxia' as const;
  if (id === 'urban') return 'urban' as const;
  if (id === 'history') return 'history' as const;
  if (id === 'military') return 'military' as const;
  if (id === 'science-fiction') return 'scienceFiction' as const;
  if (id === 'game') return 'game' as const;
  if (id === 'mystery') return 'mystery' as const;
  return 'book' as const;
}

function cursorPage(cursor: string | null, scope: string): number {
  if (cursor === null) return 1;
  const raw = cursor.startsWith(`${scope}:`) ? cursor.slice(scope.length + 1) : '';
  const page = Number(raw);
  if (!Number.isSafeInteger(page) || page < 2 || page > 100) throw new Error('Cursor is invalid.');
  return page;
}

function clamp(value: number): number { return Math.max(1, Math.min(50, Math.floor(value))); }
function clean(value: string): string { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function stripHtml(value: string): string { return value.replace(/<[^>]*>/gu, ' ').replaceAll('&nbsp;', ' '); }
function text(value: unknown): string { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
function finiteNumber(value: unknown): number | null { const result = Number(value); return Number.isFinite(result) && result >= 0 ? result : null; }
function isRecord(value: unknown): value is Json { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function safeUrl(value: string): string { try { const url = new URL(value); return /^https?:$/u.test(url.protocol) ? url.toString() : ''; } catch { return ''; } }
function frozen<T>(value: T): T { return Object.freeze(value); }
function requireContext(): Context { if (context === undefined) throw new Error('Source is not activated.'); return context; }
