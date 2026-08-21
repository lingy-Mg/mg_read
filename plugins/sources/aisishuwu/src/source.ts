import type * as cheerio from 'cheerio';
import type { Element } from 'domhandler';

import type {
  ChapterContent,
  ChaptersRequest,
  ChaptersResult,
  ContentAttribute,
  ContentDetail,
  ContentReferenceRequest,
  ContentRequest,
  ContentStatus,
  ContentSummary,
  DiscoverRequest,
  DiscoverResult,
  MgReadPluginContext,
  SearchRequest,
  SearchResult,
} from './mgread-api.js';
import { nonBlank } from './utils.js';

export interface SourceRules {
  readonly origin: string;
  readonly categories: readonly { readonly id: string; readonly title: string }[];
}

interface CatalogPage {
  readonly chapters: readonly CatalogChapter[];
  readonly nextPage: number | null;
  readonly totalCount: number | null;
}

interface CatalogChapter {
  readonly id: string;
  readonly title: string;
  readonly url: URL;
}

let cheerioModule: Promise<typeof import('cheerio')> | undefined;

function loadCheerio(): Promise<typeof import('cheerio')> {
  return (cheerioModule ??= import('cheerio'));
}

/**
 * Website-specific implementation. It deliberately exposes no URLs as Plugin
 * API IDs: URLs stay private implementation details and are only emitted as
 * optional metadata after origin validation.
 */
export class AliceBookHouseSource {
  readonly #baseUrl: URL;
  readonly #categories: readonly { readonly id: string; readonly title: string }[];
  readonly #coverUrls = new Map<string, string | null>();
  readonly #chapterCounts = new Map<string, number | null>();
  readonly #catalogPages = new Map<string, CatalogPage>();

  constructor(
    private readonly context: MgReadPluginContext,
    rules: SourceRules,
  ) {
    this.#baseUrl = new URL(rules.origin);
    if (this.#baseUrl.protocol !== 'https:' || this.#baseUrl.pathname !== '/') {
      throw new Error('Source origin must be an HTTPS origin without a path.');
    }
    this.#categories = Object.freeze(
      rules.categories.map((category) => {
        if (!/^\d+$/.test(category.id) || nonBlank(category.title) === null) {
          throw new Error('Source category rules are invalid.');
        }
        return Object.freeze({ id: category.id, title: category.title });
      }),
    );
  }

  async discover(request: DiscoverRequest): Promise<DiscoverResult> {
    if (request.target === null) {
      return Object.freeze({
        kind: 'document' as const,
        document: Object.freeze({ components: Object.freeze([
          Object.freeze({
            type: 'section' as const,
            id: 'source-categories-section',
            title: '分类',
            subtitle: null,
            children: Object.freeze([
              Object.freeze({ type: 'text' as const, id: 'source-categories-hint', text: '选择分类后查看书籍。' }),
              Object.freeze({
                type: 'categoryCollection' as const,
                id: 'source-categories',
                layout: 'grid' as const,
                categories: Object.freeze(this.#categories.map((category) =>
                Object.freeze({
                  id: `category:${category.id}`,
                  title: category.title,
                  target: `category:${category.id}`,
                  count: null,
                  url: null,
                }),
                )),
              }),
            ]),
          }),
        ]) }),
      });
    }

    const category = this.#decodeCategoryTarget(request.target);
    const page = decodePageCursor(request.cursor, 'category-page');
    const pageUrl = new URL(`/lists/${category.id}.html`, this.#baseUrl);
    pageUrl.searchParams.set('page', String(page));
    const items = await this.#parseList(await this.#getHtml(pageUrl), pageUrl);
    const visible = await this.#withCovers(items.slice(0, request.pageSize));

    const continuation = items.length >= request.pageSize
        ? Object.freeze({ target: request.target, cursor: encodePageCursor('category-page', page + 1) })
        : null;
    const collectionId = `category-books:${category.id}`;
    const discoveryItems = Object.freeze(
      visible.map((content) => Object.freeze({
        content,
        rank: null,
        metric: null,
        recommendation: null,
      })),
    );
    if (request.collectionId !== null) {
      if (request.collectionId !== collectionId || request.cursor === null) {
        throw new Error('Discovery continuation is invalid.');
      }
      return Object.freeze({
        kind: 'append' as const,
        collectionId,
        items: discoveryItems,
        continuation,
      });
    }
    return Object.freeze({
      kind: 'document' as const,
      document: Object.freeze({ components: Object.freeze([
        Object.freeze({
          type: 'section' as const,
          id: `category-results-section:${category.id}`,
          title: category.title,
          subtitle: null,
          children: Object.freeze([Object.freeze({
            type: 'contentCollection' as const,
            id: collectionId,
            layout: 'list' as const,
            items: discoveryItems,
            continuation,
          })]),
        }),
      ]) }),
    });
  }

  async search(request: SearchRequest): Promise<SearchResult> {
    const page = decodePageCursor(request.cursor, 'search-page');
    const searchUrl = new URL('/search.html', this.#baseUrl);
    searchUrl.searchParams.set('q', request.query);
    searchUrl.searchParams.set('f', '_all');
    searchUrl.searchParams.set('p', String(page));
    const items = await this.#parseList(await this.#getHtml(searchUrl), searchUrl);

    const visible = await this.#withCovers(items.slice(0, request.pageSize));
    return Object.freeze({
      items: visible,
      nextCursor:
        items.length >= request.pageSize
          ? encodePageCursor('search-page', page + 1)
          : null,
      totalCount: null,
    });
  }

  async getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
    const novelId = decodeNovelId(request.id);
    const detailUrl = new URL(`/novel/${novelId}.html`, this.#baseUrl);
    const cheerio = await loadCheerio();
    const $ = cheerio.load(await this.#getHtml(detailUrl, detailUrl));
    const title = requiredText($('.novel_title').first().text());
    const info = $('.novel_info').first();
    const author = textOrNull(info.find('a[href*="f=author"]').first().text());
    const description =
      textOrNull($('.jianjie p').first().text()) ??
      textOrNull($('meta[name="description"]').attr('content'));
    const category =
      textOrNull(info.find('a[href*="/lists/"]').first().text()) ??
      textOrNull($('.bread-crumbs a[href*="/lists/"]').first().text());
    const stats = parseDetailStats(info);
    const latestLink = info.find('a[href*="/book/"]').first();
    const latestHref = latestLink.attr('href');
    const latestUpdatedAt = parseSourceDate(
      $('.book_newchap .con li').first().find('em').text(),
    );
    const latestChapter =
      latestHref === undefined || textOrNull(latestLink.text()) === null
        ? null
        : Object.freeze({
            id: this.#chapterId(this.#sourceUrl(latestHref, detailUrl)),
            title: requiredText(latestLink.text()),
            url: this.#sourceUrl(latestHref, detailUrl).toString(),
            updatedAt: latestUpdatedAt,
          });

    const coverUrl = this.#coverUrl($, detailUrl);
    const contentId = `novel:${novelId}`;
    this.#coverUrls.set(contentId, coverUrl);
    this.#chapterCounts.set(contentId, stats.chapterCount);
    return Object.freeze({
      ...this.#summary({
        novelId,
        title,
        author,
        description,
        category,
        coverUrl,
        latestChapter,
        status: stats.status,
        wordCount: stats.wordCount,
        chapterCount: stats.chapterCount,
        tags: parseTags($),
        attributes: stats.attributes,
        updatedAt: latestUpdatedAt,
      }),
      aliases: Object.freeze([]),
      catalogUrl: new URL(`/other/chapters/id/${novelId}.html`, this.#baseUrl).toString(),
    });
  }

  async getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const novelId = decodeNovelId(request.id);
    const cursor = decodeCatalogCursor(request.cursor);
    const pageSize = boundedPageSize(request.pageSize);
    const catalog = await this.#catalogPage(novelId, cursor.page);
    const page = catalog.chapters.slice(cursor.offset, cursor.offset + pageSize);
    const nextCursor =
      cursor.offset + page.length < catalog.chapters.length
        ? encodeCatalogCursor(cursor.page, cursor.offset + page.length)
        : catalog.nextPage === null
        ? null
        : encodeCatalogCursor(catalog.nextPage, 0);

    return Object.freeze({
      items: Object.freeze(
        page.map((chapter, index) =>
          Object.freeze({
            id: chapter.id,
            title: chapter.title,
            order: (cursor.page - 1) * 100000 + cursor.offset + index,
            url: chapter.url.toString(),
            volumeTitle: null,
            wordCount: null,
            updatedAt: null,
            isLocked: null,
            attributes: Object.freeze([]),
          }),
        ),
      ),
      nextCursor,
      totalCount: this.#chapterCounts.get(request.id) ?? catalog.totalCount,
    });
  }

  async getContent(request: ContentRequest): Promise<ChapterContent> {
    decodeNovelId(request.id);
    const chapterUrl = this.#decodeChapterId(request.chapterId);
    const cheerio = await loadCheerio();
    const $ = cheerio.load(await this.#getHtml(chapterUrl, chapterUrl));
    const content = $('.read-content, .j_readContent, #j_chapterBox').first();
    if (content.length === 0) {
      throw new Error('Source chapter content was not found.');
    }
    content.find('script, style, iframe, #user_ad, .chapter-control, .text-head, .right-bar-list, .left-bar-list').remove();
    const title = textOrNull($('h1, .read-title, .book-title').first().text());
    const markup = (content.html() ?? '')
      .replace(/<br\s*\/?>/giu, '\n')
      .replace(/<\/(?:p|div)>/giu, '\n\n');
    const text = cheerio
      .load(`<body>${markup}</body>`)
      .text()
      .replace(/\r/g, '')
      .replace(/爱丽丝书屋[\s\S]*?Copyright\s*\d{4}/giu, '')
      .replace(/[ \t]+\n/gu, '\n')
      .replace(/\n[ \t]+/gu, '\n')
      .replace(/\n{3,}/gu, '\n\n')
      .trim();

    return Object.freeze({
      chapterId: request.chapterId,
      contentKind: 'novel',
      title,
      updatedAt: null,
      text,
      pages: Object.freeze([]),
    });
  }

  async #getHtml(url: URL, referer?: URL): Promise<string> {
    const response = await this.context.http.fetch(url, {
      headers: {
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        ...(referer === undefined ? {} : { Referer: referer.toString() }),
      },
    });
    if (!response.ok) {
      throw new Error(`Source request failed with HTTP ${response.status}.`);
    }
    return response.text();
  }

  async #parseList(html: string, pageUrl: URL): Promise<readonly ContentSummary[]> {
    const cheerio = await loadCheerio();
    const $ = cheerio.load(html);
    const roots = $('.list-group-item, .rec_rullist > ul').toArray();
    const seen = new Set<string>();
    const books = roots.flatMap((element) => this.#parseBookElement($, element, pageUrl, seen));
    if (books.length !== 0) return Object.freeze(books);
    return Object.freeze(
      $('a[href*="/novel/"]')
        .toArray()
        .flatMap((element) => this.#parseBookElement($, element, pageUrl, seen)),
    );
  }

  #parseBookElement(
    $: cheerio.CheerioAPI,
    element: Element,
    pageUrl: URL,
    seen: Set<string>,
  ): readonly ContentSummary[] {
    const root = $(element);
    const link = root.is('a[href*="/novel/"]')
      ? root
      : root.find('a[href*="/novel/"]').first();
    const href = link.attr('href');
    const title = textOrNull(link.text());
    if (href === undefined || title === null) return [];
    const sourceUrl = this.#sourceUrl(href, pageUrl);
    const novelId = novelIdFromUrl(sourceUrl);
    if (novelId === null || seen.has(novelId)) return [];
    seen.add(novelId);
    const author =
      textOrNull(root.find('a[href*="f=author"]').first().text()) ??
      textOrNull(root.find('li.four').first().text());
    const description = textOrNull(root.find('.content-txt').first().text());
    const category = textOrNull(root.find('.sev a, a[href*="/lists/"]').first().text());
    const latestLink = root.find('a[href*="/book/"]').first();
    const latestHref = latestLink.attr('href');
    const latestTitle = textOrNull(latestLink.text());
    const latestChapter =
      latestHref === undefined || latestTitle === null
        ? null
        : Object.freeze({
            id: this.#chapterId(this.#sourceUrl(latestHref, pageUrl)),
            title: latestTitle,
            url: this.#sourceUrl(latestHref, pageUrl).toString(),
            updatedAt: null,
          });
    const cover = root
      .find('img[data-src], img[data-original], img[data-lazy-src], img[src]')
      .first();
    const coverCandidate =
      cover.attr('data-src') ??
      cover.attr('data-original') ??
      cover.attr('data-lazy-src') ??
      cover.attr('src');
    return [
      this.#summary({
        novelId,
        title,
        author,
        description,
        category,
        coverUrl: _publicCoverUrl(coverCandidate, pageUrl),
        latestChapter,
      }),
    ];
  }

  #summary(input: {
    readonly novelId: string;
    readonly title: string;
    readonly author: string | null;
    readonly description: string | null;
    readonly category: string | null;
    readonly coverUrl: string | null;
    readonly latestChapter: ContentSummary['latestChapter'];
    readonly status?: ContentStatus;
    readonly wordCount?: number | null;
    readonly chapterCount?: number | null;
    readonly tags?: readonly string[];
    readonly attributes?: readonly ContentAttribute[];
    readonly updatedAt?: string | null;
  }): ContentSummary {
    return Object.freeze({
      id: `novel:${input.novelId}`,
      title: input.title,
      contentKind: 'novel',
      author: input.author,
      url: new URL(`/novel/${input.novelId}.html`, this.#baseUrl).toString(),
      coverUrl: input.coverUrl,
      description: input.description,
      language: 'zh-CN',
      status: input.status ?? ('unknown' as ContentStatus),
      access: 'unknown',
      wordCount: input.wordCount ?? null,
      chapterCount: input.chapterCount ?? null,
      publishedAt: null,
      updatedAt: input.updatedAt ?? null,
      latestChapter: input.latestChapter,
      categories: input.category === null ? Object.freeze([]) : Object.freeze([input.category]),
      tags: Object.freeze(input.tags ?? []),
      attributes: Object.freeze(input.attributes ?? []),
    });
  }

  async #catalogPage(novelId: string, page: number): Promise<CatalogPage> {
    const cacheKey = `${novelId}:${page}`;
    const cached = this.#catalogPages.get(cacheKey);
    if (cached !== undefined) return cached;

    const catalogUrl = this.#catalogPageUrl(novelId, page);
    const cheerio = await loadCheerio();
    const $ = cheerio.load(await this.#getHtml(catalogUrl, catalogUrl));
    const seen = new Set<string>();
    const chapters = $('.mulu_list a[href*="/book/"], a[href*="/book/"]')
      .toArray()
      .flatMap((element) => {
        const title = textOrNull($(element).text());
        const href = $(element).attr('href');
        if (title === null || href === undefined) return [];
        const url = this.#sourceUrl(href, catalogUrl);
        const id = this.#chapterId(url);
        if (seen.has(id)) return [];
        seen.add(id);
        return [Object.freeze({ id, title, url })];
      });
    const result = Object.freeze({
      chapters: Object.freeze(chapters),
      nextPage: findNextCatalogPage($, catalogUrl, novelId, page),
      totalCount: parseCatalogTotalCount($),
    });
    this.#catalogPages.set(cacheKey, result);
    return result;
  }

  #catalogPageUrl(novelId: string, page: number): URL {
    const url = new URL(`/other/chapters/id/${novelId}.html`, this.#baseUrl);
    if (page > 1) url.searchParams.set('page', String(page));
    return url;
  }

  #coverUrl($: cheerio.CheerioAPI, detailUrl: URL): string | null {
    const cover = $('.pic img, img.fengmian2').first();
    return _publicCoverUrl(
      $('meta[property="og:image"]').attr('content') ??
          cover.attr('data-src') ??
          cover.attr('data-original') ??
          cover.attr('data-lazy-src') ??
          cover.attr('src'),
      detailUrl,
    );
  }

  async #withCovers(
    contents: readonly ContentSummary[],
  ): Promise<readonly ContentSummary[]> {
    const hydrated = new Array<ContentSummary>(contents.length);
    let nextIndex = 0;
    const worker = async (): Promise<void> => {
      while (nextIndex < contents.length) {
        const index = nextIndex;
        nextIndex += 1;
        hydrated[index] = await this.#withCover(contents[index]!);
      }
    };
    await Promise.all(
      Array.from(
        { length: Math.min(4, contents.length) },
        () => worker(),
      ),
    );
    return Object.freeze(hydrated);
  }

  async #withCover(content: ContentSummary): Promise<ContentSummary> {
    if (content.coverUrl !== null) return content;
    if (this.#coverUrls.has(content.id)) {
      const coverUrl = this.#coverUrls.get(content.id)!;
      return coverUrl === null
          ? content
          : Object.freeze({ ...content, coverUrl });
    }
    const novelId = decodeNovelId(content.id);
    const detailUrl = new URL(`/novel/${novelId}.html`, this.#baseUrl);
    try {
      const cheerio = await loadCheerio();
      const $ = cheerio.load(await this.#getHtml(detailUrl, detailUrl));
      const coverUrl = this.#coverUrl($, detailUrl);
      this.#coverUrls.set(content.id, coverUrl);
      return coverUrl === null
          ? content
          : Object.freeze({ ...content, coverUrl });
    } catch {
      this.#coverUrls.set(content.id, null);
      return content;
    }
  }

  #sourceUrl(value: string, base: URL): URL {
    const url = new URL(value, base);
    if (url.origin !== this.#baseUrl.origin || url.protocol !== 'https:') {
      throw new Error('Source supplied an out-of-origin URL.');
    }
    return url;
  }

  #chapterId(url: URL): string {
    if (!/^\/book\/[^/]+\/[^/]+\.html$/u.test(url.pathname)) {
      throw new Error('Source chapter URL is invalid.');
    }
    return `chapter:${Buffer.from(url.pathname, 'utf8').toString('base64url')}`;
  }

  #decodeChapterId(id: string): URL {
    if (!id.startsWith('chapter:')) throw new Error('Chapter ID is invalid.');
    let path: string;
    try {
      path = Buffer.from(id.slice('chapter:'.length), 'base64url').toString('utf8');
    } catch {
      throw new Error('Chapter ID is invalid.');
    }
    return this.#sourceUrl(path, this.#baseUrl);
  }

  #decodeCategoryTarget(target: string): { readonly id: string; readonly title: string } {
    const id = target.startsWith('category:') ? target.slice('category:'.length) : '';
    const category = this.#categories.find((candidate) => candidate.id === id);
    if (category === undefined) throw new Error('Category target is invalid.');
    return category;
  }
}

function requiredText(value: string | undefined): string {
  const text = textOrNull(value);
  if (text === null) throw new Error('A required source field was empty.');
  return text;
}

function textOrNull(value: string | undefined): string | null {
  return nonBlank(value);
}

function novelIdFromUrl(url: URL): string | null {
  return /^\/novel\/(\d+)\.html$/u.exec(url.pathname)?.[1] ?? null;
}

function decodeNovelId(id: string): string {
  const match = /^novel:(\d+)$/u.exec(id);
  if (match?.[1] === undefined) throw new Error('Novel ID is invalid.');
  return match[1];
}

function decodePageCursor(cursor: string | null, scope: string): number {
  if (cursor === null) return 1;
  const match = new RegExp(`^${scope}:(\\d+)$`, 'u').exec(cursor);
  const value = match?.[1] === undefined ? Number.NaN : Number(match[1]);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error('Cursor is invalid.');
  return value;
}

function encodePageCursor(scope: string, value: number): string {
  return `${scope}:${value}`;
}

function decodeCatalogCursor(cursor: string | null): {
  readonly page: number;
  readonly offset: number;
} {
  if (cursor === null) return Object.freeze({ page: 1, offset: 0 });
  const match = /^catalog-page:(\d+):(\d+)$/u.exec(cursor);
  const page = match?.[1] === undefined ? Number.NaN : Number(match[1]);
  const offset = match?.[2] === undefined ? Number.NaN : Number(match[2]);
  if (
    !Number.isSafeInteger(page) ||
    !Number.isSafeInteger(offset) ||
    page < 1 ||
    offset < 0
  ) {
    throw new Error('Catalog cursor is invalid.');
  }
  return Object.freeze({ page, offset });
}

function encodeCatalogCursor(page: number, offset: number): string {
  return `catalog-page:${page}:${offset}`;
}

function boundedPageSize(value: number): number {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error('Chapter page size is invalid.');
  }
  return Math.min(value, 100);
}

function parseDetailStats($info: cheerio.Cheerio<Element>): {
  readonly wordCount: number | null;
  readonly chapterCount: number | null;
  readonly status: ContentStatus;
  readonly attributes: readonly ContentAttribute[];
} {
  const rows = new Map<string, string>();
  $info.find('p').each((_, element) => {
    const raw = compactSourceText($info.find(element).text());
    const separator = raw.indexOf('：');
    if (separator <= 0) return;
    rows.set(raw.slice(0, separator), raw);
  });
  const heatAndFavorites = rows.get('热度') ?? '';
  const wordAndChapters = rows.get('字数') ?? '';
  const heat = parseLabeledCount(heatAndFavorites, '热度');
  const favorites = parseLabeledCount(heatAndFavorites, '收藏');
  const wordCount = parseLabeledCount(wordAndChapters, '字数');
  const chapterCount = parseLabeledCount(wordAndChapters, '章节');
  const attributes: ContentAttribute[] = [];
  if (heat !== null) {
    attributes.push(
      Object.freeze({ key: 'heat', label: '热度', value: String(heat) }),
    );
  }
  if (favorites !== null) {
    attributes.push(
      Object.freeze({ key: 'favorites', label: '收藏', value: String(favorites) }),
    );
  }
  return Object.freeze({
    wordCount,
    chapterCount,
    status: parseContentStatus(rows.get('状态')),
    attributes: Object.freeze(attributes),
  });
}

function parseTags($: cheerio.CheerioAPI): readonly string[] {
  const tags = $('.tags_list a[href*="f=tag"], .tags_list a[href*="f%3Dtag"]')
    .toArray()
    .flatMap((element) => {
      const tag = textOrNull($(element).clone().find('em, span').remove().end().text());
      return tag === null ? [] : [tag];
    });
  return Object.freeze([...new Set(tags)].slice(0, 20));
}

function parseContentStatus(value: string | undefined): ContentStatus {
  const normalized = compactSourceText(value ?? '');
  if (/(?:连载|更新中)/u.test(normalized)) return 'ongoing';
  if (/(?:已)?完结/u.test(normalized)) return 'completed';
  if (/(?:暂停|断更|停更)/u.test(normalized)) return 'hiatus';
  return 'unknown';
}

function parseLabeledCount(value: string, label: string): number | null {
  const match = new RegExp(`${label}[：:]?([0-9]+(?:\\.[0-9]+)?)([万亿]?)`, 'u').exec(
    compactSourceText(value),
  );
  if (match?.[1] === undefined) return null;
  const number = Number(match[1]);
  const multiplier = match[2] === '万' ? 10000 : match[2] === '亿' ? 100000000 : 1;
  const result = Math.round(number * multiplier);
  return Number.isSafeInteger(result) && result >= 0 ? result : null;
}

function compactSourceText(value: string): string {
  return value.replace(/\s+/gu, '').trim();
}

function parseSourceDate(value: string): string | null {
  const match = /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})/u.exec(value);
  if (match === null) return null;
  const iso = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:00+08:00`;
  return Number.isNaN(Date.parse(iso)) ? null : new Date(iso).toISOString();
}

function parseCatalogTotalCount($: cheerio.CheerioAPI): number | null {
  const text = compactSourceText($('.book_newchap .tit, .mulu_title, .catalog_title').first().text());
  const match = /全(\d+)章/u.exec(text);
  if (match?.[1] === undefined) return null;
  const count = Number(match[1]);
  return Number.isSafeInteger(count) && count >= 0 ? count : null;
}

function findNextCatalogPage(
  $: cheerio.CheerioAPI,
  catalogUrl: URL,
  novelId: string,
  currentPage: number,
): number | null {
  const next = $('.pagination a[href], .page a[href], .pages a[href], a[rel="next"]')
    .toArray()
    .find((element) => /^(?:下一页|下页|next|›|»|>)$/iu.test(compactSourceText($(element).text())) || $(element).attr('rel') === 'next');
  const href = next === undefined ? undefined : $(next).attr('href');
  if (href === undefined) return null;
  try {
    const url = new URL(href, catalogUrl);
    if (url.origin !== catalogUrl.origin || !url.pathname.endsWith(`/id/${novelId}.html`)) {
      return null;
    }
    const value = Number(url.searchParams.get('page') ?? url.searchParams.get('p'));
    return Number.isSafeInteger(value) && value > currentPage ? value : null;
  } catch {
    return null;
  }
}

/** Cover URLs are display metadata, unlike navigation URLs. CDN origins are
 * allowed, but credentials and non-HTTP schemes are never exposed. */
function publicHttpUrl(value: string, base: URL): string | null {
  try {
    const url = new URL(value, base);
    if (
      (url.protocol !== 'http:' && url.protocol !== 'https:') ||
      url.username.length !== 0 ||
      url.password.length !== 0
    ) {
      return null;
    }
    return url.toString();
  } catch {
    return null;
  }
}

function _publicCoverUrl(value: string | undefined, base: URL): string | null {
  const normalized = textOrNull(value);
  return normalized === null ? null : publicHttpUrl(normalized, base);
}
