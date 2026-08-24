import type * as cheerio from 'cheerio';
import type { Element } from 'domhandler';
import type {
  ChapterContent, ChaptersRequest, ChaptersResult, ContentAttribute, ContentDetail,
  ContentReferenceRequest, ContentRequest, ContentStatus, ContentSummary, DiscoverRequest,
  DiscoverResult, MgReadPluginContext, SearchRequest, SearchResult, SearchSuggestionsRequest,
  SearchSuggestionsResult,
} from './mgread-api.js';
import { PluginHtmlCache, type HtmlCachePolicy } from './html-cache.js';
import { nonBlank } from './utils.js';

export interface SourceRules { readonly origin: string; readonly categories: readonly { readonly id: string; readonly title: string }[]; }
interface CatalogChapter { readonly id: string; readonly title: string; readonly url: URL; }
let cheerioModule: Promise<typeof import('cheerio')> | undefined;
const listingPolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 10 * 60 * 1000 } satisfies HtmlCachePolicy);
const detailPolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000 } satisfies HtmlCachePolicy);
const hotSearchPolicy = Object.freeze({ namespace: 'hot-search', staleAfterMs: 24 * 60 * 60 * 1000 } satisfies HtmlCachePolicy);

function loadCheerio(): Promise<typeof import('cheerio')> { return (cheerioModule ??= import('cheerio')); }

export class ShuduguSource {
  readonly #baseUrl: URL;
  readonly #categories: readonly SourceRules['categories'][number][];
  readonly #cache: PluginHtmlCache;
  readonly #catalogs = new Map<string, readonly CatalogChapter[]>();
  readonly #details = new Map<string, ContentDetail>();
  constructor(private readonly context: MgReadPluginContext, rules: SourceRules) {
    this.#baseUrl = new URL(rules.origin);
    if (this.#baseUrl.protocol !== 'https:' || this.#baseUrl.pathname !== '/') throw new Error('Source origin is invalid.');
    this.#categories = Object.freeze(rules.categories.map((item) => {
      if (!/^[a-z]+$/.test(item.id) || nonBlank(item.title) === null) throw new Error('Source categories are invalid.');
      return Object.freeze({ id: item.id, title: item.title });
    }));
    this.#cache = new PluginHtmlCache(context.cacheDir);
  }

  async discover(request: DiscoverRequest): Promise<DiscoverResult> {
    if (request.target === null) return documentResult(Object.freeze({
      type: 'section', id: 'shudugu-categories-section', title: '小说分类', subtitle: null,
      children: Object.freeze([
        Object.freeze({ type: 'text', id: 'shudugu-categories-hint', text: '选择分类后查看书籍。' }),
        Object.freeze({ type: 'categoryCollection', id: 'shudugu-categories', layout: 'grid', categories: Object.freeze(this.#categories.map((category) => Object.freeze({
          id: `category:${category.id}`, title: category.title, target: `category:${category.id}`, count: null,
          url: new URL(`/${category.id}/`, this.#baseUrl).toString(),
        }))) }),
      ]),
    }));
    const category = this.#category(request.target);
    const page = decodePage(request.cursor, 'category-page');
    const url = this.#categoryUrl(category.id, page);
    const books = await this.#parseList(await this.#getHtml(url, listingPolicy), url);
    const visible = await this.#withDetails(books.slice(0, boundedPageSize(request.pageSize)));
    const collectionId = `category-books:${category.id}`;
    const continuation = books.length >= boundedPageSize(request.pageSize)
      ? Object.freeze({ target: request.target, cursor: `category-page:${page + 1}` }) : null;
    const items = Object.freeze(visible.map((content) => Object.freeze({ content, rank: null, metric: null, recommendation: null })));
    if (request.collectionId !== null) {
      if (request.collectionId !== collectionId || request.cursor === null) throw new Error('Discovery continuation is invalid.');
      return Object.freeze({ kind: 'append', collectionId, items, continuation });
    }
    return documentResult(Object.freeze({
      type: 'section', id: `category-section:${category.id}`, title: category.title, subtitle: null,
      children: Object.freeze([Object.freeze({ type: 'contentCollection', id: collectionId, layout: 'list', items, continuation })]),
    }));
  }

  async search(request: SearchRequest): Promise<SearchResult> {
    const page = decodePage(request.cursor, 'search-page');
    const url = new URL('/i/sor.aspx', this.#baseUrl);
    url.searchParams.set('key', request.query);
    if (page > 1) url.searchParams.set('page', String(page));
    const html = await this.#getHtml(url, listingPolicy);
    const books = await this.#parseList(html, url);
    const size = boundedPageSize(request.pageSize);
    return Object.freeze({ items: await this.#withDetails(books.slice(0, size)), nextCursor: null, totalCount: parseSearchTotal(html) });
  }

  async searchSuggestions(request: SearchSuggestionsRequest): Promise<SearchSuggestionsResult> {
    if (decodePage(request.cursor, 'suggestions-page') > 1) return Object.freeze({ items: Object.freeze([]), nextCursor: null });
    const url = new URL('/', this.#baseUrl);
    const queries = await this.#parseHotSearches(await this.#getHtml(url, hotSearchPolicy));
    return Object.freeze({ items: Object.freeze(queries.slice(0, boundedPageSize(request.pageSize)).map((query) => Object.freeze({ query, metric: null }))), nextCursor: null });
  }

  async getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
    const id = decodeNovelId(request.id);
    const url = new URL(`/${id}/`, this.#baseUrl);
    const cheerio = await loadCheerio();
    const $ = cheerio.load(await this.#getHtml(url, detailPolicy));
    const item = $('.item').first();
    const title = required(item.find('.itemtxt h1 a, .itemtxt h3 a').first().text());
    const spans = item.find('.itemtxt p span').toArray().map((element) => required($(element).text()));
    const author = textOrNull(item.find('.itemtxt a').filter((_, element) => /^作者[：:]/u.test($(element).text())).first().text().replace(/^作者[：:]/u, ''));
    const category = textOrNull(spans[1]);
    const description = textOrNull($('.des.bb').first().text());
    const wordCount = parseCount(item.find('.itemtxt h1 i').first().text(), '字');
    const status = parseStatus(spans[0]);
    const updatedAt = parseDate($('#dir > span').first().text());
    const latestLink = item.find('ul li a').last();
    const latestTitle = textOrNull(latestLink.text());
    const latestHref = latestLink.attr('href');
    const latestChapter = latestTitle === null || latestHref === undefined ? null : Object.freeze({
      id: this.#chapterId(this.#sourceUrl(latestHref, url)), title: latestTitle,
      url: this.#sourceUrl(latestHref, url).toString(), updatedAt,
    });
    const coverUrl = publicHttpUrl(item.find('img').first().attr('src'), url);
    const chapters = this.#parseCatalog($, url);
    const detail = Object.freeze({
      ...this.#summary({ id, title, author, category, coverUrl, description, status, wordCount,
        chapterCount: chapters.length, latestChapter, updatedAt }),
      aliases: Object.freeze([]), catalogUrl: url.toString(),
    });
    this.#details.set(request.id, detail);
    this.#catalogs.set(id, chapters);
    return detail;
  }

  async getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const id = decodeNovelId(request.id);
    let chapters = this.#catalogs.get(id);
    if (chapters === undefined) { chapters = (await this.getDetail({ id: request.id })).chapterCount === null ? [] : this.#catalogs.get(id) ?? []; }
    const cursor = decodeOffsetCursor(request.cursor);
    const page = cursor === 0 ? chapters : chapters.slice(cursor, cursor + boundedPageSize(request.pageSize));
    const nextCursor = cursor === 0 ? null : cursor + page.length < chapters.length ? `catalog-offset:${cursor + page.length}` : null;
    return Object.freeze({ items: Object.freeze(page.map((chapter, index) => Object.freeze({
      id: chapter.id, title: chapter.title, order: cursor + index, url: chapter.url.toString(), volumeTitle: null,
      wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]),
    }))), nextCursor, totalCount: chapters.length });
  }

  async getContent(request: ContentRequest): Promise<ChapterContent> {
    decodeNovelId(request.id);
    const chapterUrl = this.#decodeChapterId(request.chapterId);
    const cheerio = await loadCheerio();
    const $ = cheerio.load(await this.#getHtml(chapterUrl));
    const content = $('.container .con').first();
    if (content.length === 0) throw new Error('Source chapter content was not found.');
    content.find('script,style,iframe,.submenu,.prenext').remove();
    const title = textOrNull($('.submenu h1').first().text())?.split('>').pop()?.trim() ?? null;
    const markup = (content.html() ?? '').replace(/<br\s*\/?>(?=.)/giu, '\n').replace(/<\/(?:p|div)>/giu, '\n\n');
    const text = cheerio.load(`<body>${markup}</body>`).text().replace(/\r/g, '').replace(/[ \t]+\n/g, '\n').replace(/\n[ \t]+/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    return Object.freeze({ chapterId: request.chapterId, contentKind: 'novel', title, updatedAt: null, text, pages: Object.freeze([]) });
  }

  async #getHtml(url: URL, policy?: HtmlCachePolicy): Promise<string> {
    const request = async (): Promise<string> => {
      this.context.log.debug('source_http_fetch_started');
      const response = await this.context.http.fetch(url, { headers: { Accept: 'text/html,application/xhtml+xml', 'Accept-Language': 'zh-CN,zh;q=0.9' } });
      if (!response.ok) throw new Error(`Source request failed with HTTP ${response.status}.`);
      return response.text();
    };
    return policy === undefined ? request() : this.#cache.getOrFetch(url, policy, request);
  }

  async #parseList(html: string, pageUrl: URL): Promise<readonly ContentSummary[]> {
    const cheerio = await loadCheerio(); const $ = cheerio.load(html); const seen = new Set<string>();
    return Object.freeze($('.item').toArray().flatMap((element) => this.#parseBook($, element, pageUrl, seen)));
  }
  async #parseHotSearches(html: string): Promise<readonly string[]> {
    const cheerio = await loadCheerio(); const $ = cheerio.load(html); const heading = $('h2 a').filter((_, element) => textOrNull($(element).text()) === '阅读排行').first();
    if (heading.length === 0) return Object.freeze([]);
    const seen = new Set<string>();
    const queries = heading.closest('.container').find('ul.list.top > li p a[href]').toArray().flatMap((element) => {
      const query = textOrNull($(element).text());
      if (query === null || seen.has(query)) return [];
      seen.add(query);
      return [query];
    });
    return Object.freeze(queries);
  }
  #parseBook($: cheerio.CheerioAPI, element: Element, pageUrl: URL, seen: Set<string>): readonly ContentSummary[] {
    const root = $(element); const link = root.find('a[href]').toArray().map((candidate) => $(candidate)).find((candidate) => /^\/\d+\/$/u.test(candidate.attr('href') ?? ''));
    const href = link?.attr('href'); const title = textOrNull(root.find('.itemtxt h1 a, .itemtxt h3 a').first().text());
    if (href === undefined || title === null) return [];
    const url = this.#sourceUrl(href, pageUrl); const id = novelIdFromUrl(url); if (id === null || seen.has(id)) return []; seen.add(id);
    const spans = root.find('.itemtxt p span').toArray().map((candidate) => textOrNull($(candidate).text())).filter((value): value is string => value !== null);
    const author = textOrNull(root.find('.itemtxt a').filter((_, candidate) => /^作者[：:]/u.test($(candidate).text())).first().text().replace(/^作者[：:]/u, ''));
    const latest = root.find('.itemtxt ul li a').last(); const latestTitle = textOrNull(latest.text()); const latestHref = latest.attr('href');
    const latestChapter = latestTitle === null || latestHref === undefined ? null : Object.freeze({ id: this.#chapterId(this.#sourceUrl(latestHref, pageUrl)), title: latestTitle, url: this.#sourceUrl(latestHref, pageUrl).toString(), updatedAt: null });
    return [this.#summary({ id, title, author, category: textOrNull(spans[1]), coverUrl: publicHttpUrl(root.find('img').first().attr('src'), pageUrl), description: null, status: parseStatus(spans[0]), wordCount: null, chapterCount: null, latestChapter, updatedAt: null })];
  }
  #summary(input: { readonly id: string; readonly title: string; readonly author: string | null; readonly category: string | null; readonly coverUrl: string | null; readonly description: string | null; readonly status: ContentStatus; readonly wordCount: number | null; readonly chapterCount: number | null; readonly latestChapter: ContentSummary['latestChapter']; readonly updatedAt: string | null }): ContentSummary {
    return Object.freeze({ id: `novel:${input.id}`, title: input.title, contentKind: 'novel', author: input.author, url: new URL(`/${input.id}/`, this.#baseUrl).toString(), coverUrl: input.coverUrl, description: input.description, language: 'zh-CN', status: input.status, access: 'free', wordCount: input.wordCount, chapterCount: input.chapterCount, publishedAt: null, updatedAt: input.updatedAt, latestChapter: input.latestChapter, categories: input.category === null ? Object.freeze([]) : Object.freeze([input.category]), tags: Object.freeze([]), attributes: Object.freeze([]) });
  }
  async #withDetails(books: readonly ContentSummary[]): Promise<readonly ContentSummary[]> {
    const result = new Array<ContentSummary>(books.length); let next = 0;
    const worker = async (): Promise<void> => { while (next < books.length) { const index = next++; const book = books[index]!; try { const detail = await this.getDetail({ id: book.id }); result[index] = Object.freeze({ ...book, author: detail.author, url: detail.url, coverUrl: detail.coverUrl, description: detail.description, language: detail.language, status: detail.status, access: detail.access, wordCount: detail.wordCount, chapterCount: detail.chapterCount, publishedAt: detail.publishedAt, updatedAt: detail.updatedAt, latestChapter: detail.latestChapter, categories: detail.categories, tags: detail.tags, attributes: detail.attributes }); } catch { result[index] = book; } } };
    await Promise.all(Array.from({ length: Math.min(4, books.length) }, () => worker())); return Object.freeze(result);
  }
  #parseCatalog($: cheerio.CheerioAPI, base: URL): readonly CatalogChapter[] {
    const seen = new Set<string>(); return Object.freeze($('#list a[href]').toArray().flatMap((element) => { const title = textOrNull($(element).text()); const href = $(element).attr('href'); if (title === null || href === undefined) return []; const url = this.#sourceUrl(href, base); const id = this.#chapterId(url); if (seen.has(id)) return []; seen.add(id); return [Object.freeze({ id, title, url })]; }));
  }
  #category(target: string): SourceRules['categories'][number] { const id = target.startsWith('category:') ? target.slice(9) : ''; const result = this.#categories.find((category) => category.id === id); if (result === undefined) throw new Error('Category target is invalid.'); return result; }
  #categoryUrl(id: string, page: number): URL { return new URL(page === 1 ? `/${id}/` : `/${id}/${page}.html`, this.#baseUrl); }
  #sourceUrl(value: string, base: URL): URL { const url = new URL(value, base); if (url.origin !== this.#baseUrl.origin || url.protocol !== 'https:') throw new Error('Source URL is invalid.'); return url; }
  #chapterId(url: URL): string { if (!/^\/\d+\/\d+(?:-\d+)?\.html$/u.test(url.pathname)) throw new Error('Chapter URL is invalid.'); return `chapter:${Buffer.from(url.pathname).toString('base64url')}`; }
  #decodeChapterId(id: string): URL { if (!id.startsWith('chapter:')) throw new Error('Chapter ID is invalid.'); const path = Buffer.from(id.slice(8), 'base64url').toString('utf8'); return this.#sourceUrl(path, this.#baseUrl); }
}

function documentResult(section: ContentSummary extends never ? never : { readonly type: 'section'; readonly id: string; readonly title: string; readonly subtitle: null; readonly children: readonly unknown[] }): DiscoverResult { return Object.freeze({ kind: 'document', document: Object.freeze({ components: Object.freeze([section]) }) }) as DiscoverResult; }
function required(value: string): string { const result = textOrNull(value); if (result === null) throw new Error('Required source field is empty.'); return result; }
function textOrNull(value: string | undefined): string | null { return nonBlank(value); }
function novelIdFromUrl(url: URL): string | null { return /^\/(\d+)\/$/u.exec(url.pathname)?.[1] ?? null; }
function decodeNovelId(id: string): string { const value = /^novel:(\d+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Novel ID is invalid.'); return value; }
function decodePage(cursor: string | null, scope: string): number { if (cursor === null) return 1; const value = Number(new RegExp(`^${scope}:(\\d+)$`, 'u').exec(cursor)?.[1] ?? Number.NaN); if (!Number.isSafeInteger(value) || value < 1) throw new Error('Cursor is invalid.'); return value; }
function decodeOffsetCursor(cursor: string | null): number { if (cursor === null) return 0; const value = Number(/^catalog-offset:(\d+)$/u.exec(cursor)?.[1] ?? Number.NaN); if (!Number.isSafeInteger(value) || value < 1) throw new Error('Catalog cursor is invalid.'); return value; }
function boundedPageSize(value: number): number { if (!Number.isSafeInteger(value) || value < 1) throw new Error('Page size is invalid.'); return Math.min(value, 100); }
function parseSearchTotal(value: string): number | null { const count = Number(/共(\d+)本小说/u.exec(value.replace(/\s+/g, ''))?.[1] ?? Number.NaN); return Number.isSafeInteger(count) && count >= 0 ? count : null; }
function parseCount(value: string, suffix: string): number | null { const match = /([\d.]+)(万|亿)?/u.exec(value); if (match === null) return null; const number = Number(match[1]); const result = Math.round(number * (match[2] === '万' ? 10000 : match[2] === '亿' ? 100000000 : 1)); return Number.isSafeInteger(result) && result >= 0 && value.includes(suffix) ? result : null; }
function parseStatus(value: string | undefined): ContentStatus { const text = value ?? ''; if (/连载|更新中/u.test(text)) return 'ongoing'; if (/完结/u.test(text)) return 'completed'; if (/暂停|断更|停更/u.test(text)) return 'hiatus'; return 'unknown'; }
function parseDate(value: string): string | null { const match = /(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/u.exec(value); if (match === null) return null; const iso = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6] ?? '00'}+08:00`; return Number.isNaN(Date.parse(iso)) ? null : new Date(iso).toISOString(); }
function publicHttpUrl(value: string | undefined, base: URL): string | null { if (value === undefined) return null; try { const url = new URL(value, base); return (url.protocol === 'http:' || url.protocol === 'https:') && url.username === '' && url.password === '' ? url.toString() : null; } catch { return null; } }
