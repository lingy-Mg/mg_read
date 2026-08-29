/**
 * 爱丽丝书屋数据源插件实现。
 *
 * 职责：解析发现、搜索、详情、目录和正文，并复用插件私有的 HTML/投影缓存。
 * 注意：分类/首页封面补全有并发与时间预算；封面只对外暴露 Runtime 代理，缓存仍保存来源 URL。
 * TODO: - 无。
 */
import * as cheerio from 'cheerio/slim';
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
  SearchSuggestionsRequest,
  SearchSuggestionsResult,
} from './mgread-api.js';
import { PluginCache, type CachedResult, type HtmlCachePolicy } from './html-cache.js';
import {
  catalogHtmlCachePolicy, catalogProjectionCachePolicy, detailHtmlCachePolicy,
  detailProjectionCachePolicy, discoveryDetailHtmlCachePolicy,
  discoveryDetailProjectionCachePolicy, discoveryHomeHtmlCachePolicy,
  discoveryListingHtmlCachePolicy, hotSearchHtmlCachePolicy,
  rankingAttributeLimit, rankingDescriptionMaxCharacters, rankingRules,
  rankingTagLimit, searchListingHtmlCachePolicy, type RankingRule,
} from './source-cache-policy.js';
import { nonBlank } from './utils.js';
import {
  boundedPageSize,
  compactSourceText,
  decodeNovelId,
  decodePageCursor,
  discoveryMetric,
  encodePageCursor,
  findNextCatalogPage,
  mergeDiscoverySummary,
  novelIdFromUrl,
  parseCatalogTotalCount,
  parseDetailStats,
  parseSourceDate,
  parseTags,
  publicCoverUrl,
  requiredText,
  textOrNull,
} from './source-parsing.js';
import {
  buildHomeDiscoveryComponents,
  type HomeDiscoveryCollections,
} from './source-discovery.js';
import { hydrateDetailsInOrder } from './source-detail-hydration.js';

const categoryDetailMaximumConcurrency = 8;
const categoryDetailBudgetMs = 10_000;
const homeCoverBudgetMs = 4_000;
const standardDetailMaximumConcurrency = 4;

export interface SourceRules {
  readonly origin: string;
  readonly categories: readonly { readonly id: string; readonly title: string }[];
}

interface CatalogPage {
  readonly chapters: readonly CatalogChapter[];
  readonly expiresAtMs: number;
  readonly nextPage: number | null;
  readonly totalCount: number | null;
}

interface CachedProjection<T> {
  readonly expiresAtMs: number;
  readonly value: T;
}

interface CatalogChapter {
  readonly id: string;
  readonly title: string;
  readonly url: URL;
}

function loadCheerio(): Promise<typeof import('cheerio/slim')> {
  return Promise.resolve(cheerio);
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
  readonly #proxiedCoverUrls = new Map<string, string>();
  readonly #chapterCounts = new Map<string, number | null>();
  readonly #catalogPages = new Map<string, CatalogPage>();
  readonly #catalogResults = new Map<string, CachedProjection<ChaptersResult>>();
  readonly #catalogRequests = new Map<string, Promise<ChaptersResult>>();
  readonly #details = new Map<string, CachedProjection<ContentDetail>>();
  readonly #discoveryDetailRequests = new Map<string, Promise<ContentDetail>>();
  readonly #detailRequests = new Map<string, Promise<ContentDetail>>();
  readonly #htmlCache: PluginCache;

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
    this.#htmlCache = new PluginCache(context.cacheDir);
  }

  async discover(request: DiscoverRequest): Promise<DiscoverResult> {
    if (request.target === null) {
      const home = await this.#loadHomeDiscovery();
      return Object.freeze({
        kind: 'document' as const,
        document: Object.freeze({ components: buildHomeDiscoveryComponents(home, this.#categories) }),
      });
    }

    if (request.target.startsWith('ranking:')) {
      return this.#discoverRanking(request);
    }

    const categoryDetailDeadlineMs = Date.now() + categoryDetailBudgetMs;
    const category = this.#decodeCategoryTarget(request.target);
    const page = decodePageCursor(request.cursor, 'category-page');
    const pageUrl = new URL(`/lists/${category.id}.html`, this.#baseUrl);
    pageUrl.searchParams.set('page', String(page));
    const items = await this.#parseList(
      await this.#getHtml(pageUrl, undefined, discoveryListingHtmlCachePolicy),
      pageUrl,
    );
    const visible = (await this.#withDiscoveryDetails(
      items.slice(0, request.pageSize),
      {
        maximumConcurrency: categoryDetailMaximumConcurrency,
        deadlineMs: categoryDetailDeadlineMs,
        retryCoverOnFailure: false,
      },
    )).map((content) => this.#withProxiedCover(content));

    const continuation = items.length >= request.pageSize
        ? Object.freeze({ target: request.target, cursor: encodePageCursor('category-page', page + 1) })
        : null;
    const collectionId = `category-books:${category.id}`;
    const discoveryItems = Object.freeze(
      visible.map((content) => Object.freeze({
        content,
        rank: null,
        metric: discoveryMetric(content),
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

  async #discoverRanking(request: DiscoverRequest): Promise<DiscoverResult> {
    const target = request.target;
    if (target === null) throw new Error('Ranking target is required.');
    const ranking = this.#decodeRankingTarget(target);
    if (request.cursor !== null || request.collectionId !== null) {
      throw new Error('Ranking results do not support continuation.');
    }
    const pageUrl = new URL(ranking.path, this.#baseUrl);
    const items = await this.#parseList(
      await this.#getHtml(pageUrl, undefined, discoveryListingHtmlCachePolicy),
      pageUrl,
    );
    // A ranking target is a source list page, not a paged ranking widget. Keep
    // every item returned by that page, while adding the same cover and rich
    // fields used by category rows. The compact projection keeps the complete
    // page below Runtime's inline discovery-result budget; opening a book
    // still loads its full, unabridged detail on demand.
    const visible = (await this.#withRankingDetails(items))
      .map((content) => this.#withProxiedCover(content));
    const collectionId = `ranking-books:${ranking.id}`;
    const discoveryItems = Object.freeze(
      visible.map((content) => Object.freeze({
        content,
        rank: null,
        metric: discoveryMetric(content),
        recommendation: null,
      })),
    );
    return Object.freeze({
      kind: 'document' as const,
      document: Object.freeze({ components: Object.freeze([
        Object.freeze({
          type: 'section' as const,
          id: `ranking-results-section:${ranking.id}`,
          title: ranking.title,
          subtitle: null,
          children: Object.freeze([Object.freeze({
            type: 'contentCollection' as const,
            id: collectionId,
            layout: 'list' as const,
            items: discoveryItems,
            continuation: null,
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
    const items = await this.#parseList(
      await this.#getHtml(searchUrl, undefined, searchListingHtmlCachePolicy),
      searchUrl,
    );

    // Search rows deliberately match discovery rows: a detail hydration supplies
    // the cover plus all rich summary fields, while a single failed detail only
    // falls back to the safe list projection.
    const visible = (await this.#withDiscoveryDetails(items.slice(0, request.pageSize)))
      .map((content) => this.#withProxiedCover(content));
    return Object.freeze({
      items: visible,
      nextCursor:
        items.length >= request.pageSize
          ? encodePageCursor('search-page', page + 1)
          : null,
      totalCount: null,
    });
  }

  async searchSuggestions(
    request: SearchSuggestionsRequest,
  ): Promise<SearchSuggestionsResult> {
    const page = decodePageCursor(request.cursor, 'search-suggestions-page');
    const homeUrl = new URL('/', this.#baseUrl);
    if (page > 1) return Object.freeze({ items: Object.freeze([]), nextCursor: null });
    const contents = await this.#parseHotSearches(
      await this.#getHtml(homeUrl, undefined, hotSearchHtmlCachePolicy),
    );
    return Object.freeze({
      items: Object.freeze(
        contents.slice(0, boundedPageSize(request.pageSize)).map((query) => Object.freeze({
          query,
          metric: null,
        })),
      ),
      nextCursor: null,
    });
  }

  async getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
    const cached = this.#details.get(request.id);
    if (cached !== undefined && cached.expiresAtMs >= Date.now()) {
      return this.#withProxiedCover(cached.value);
    }
    const inFlight = this.#detailRequests.get(request.id);
    if (inFlight !== undefined) return this.#withProxiedCover(await inFlight);
    const pending = this.#loadCachedDetail(request, detailProjectionCachePolicy, detailHtmlCachePolicy);
    this.#detailRequests.set(request.id, pending);
    void pending.then(
      () => this.#detailRequests.delete(request.id),
      () => this.#detailRequests.delete(request.id),
    );
    return this.#withProxiedCover(await pending);
  }

  async #loadDetail(
    request: ContentReferenceRequest,
    cachePolicy: HtmlCachePolicy = detailHtmlCachePolicy,
  ): Promise<ContentDetail> {
    const novelId = decodeNovelId(request.id);
    const detailUrl = new URL(`/novel/${novelId}.html`, this.#baseUrl);
    const cheerio = await loadCheerio();
    const cachedHtml = await this.#getHtmlResult(
      detailUrl,
      detailUrl,
      cachePolicy,
    );
    const $ = cheerio.load(
      cachedHtml.body,
    );
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
    const detail = Object.freeze({
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
    // Discovery hydration and the immediately opened detail route share this
    // parsed object. Its expiry is the underlying HTML's expiry, never a new
    // hour measured from parsing, so detail freshness remains strict.
    this.#details.set(request.id, Object.freeze({
      expiresAtMs: cachedHtml.storedAtMs + cachePolicy.staleAfterMs,
      value: detail,
    }));
    return detail;
  }

  async getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const cached = this.#catalogResults.get(request.id);
    if (cached !== undefined && cached.expiresAtMs >= Date.now()) return cached.value;
    const inFlight = this.#catalogRequests.get(request.id);
    if (inFlight !== undefined) return inFlight;
    const pending = this.#loadCachedChapters(request);
    this.#catalogRequests.set(request.id, pending);
    void pending.then(
      () => this.#catalogRequests.delete(request.id),
      () => this.#catalogRequests.delete(request.id),
    );
    return pending;
  }

  async #loadChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const novelId = decodeNovelId(request.id);
    const chapters: CatalogChapter[] = [];
    const seenChapterIds = new Set<string>();
    const seenPages = new Set<number>();
    let expiresAtMs = Number.MAX_SAFE_INTEGER;
    let page: number | null = 1;
    while (page !== null) {
      if (!seenPages.add(page)) throw new Error('Catalog page repeated.');
      const catalog = await this.#catalogPage(novelId, page);
      expiresAtMs = Math.min(expiresAtMs, catalog.expiresAtMs);
      for (const chapter of catalog.chapters) {
        if (seenChapterIds.has(chapter.id)) continue;
        seenChapterIds.add(chapter.id);
        chapters.push(chapter);
      }
      page = catalog.nextPage;
    }

    const result = Object.freeze({
      items: Object.freeze(
        chapters.map((chapter, index) =>
          Object.freeze({
            id: chapter.id,
            title: chapter.title,
            order: index,
            url: chapter.url.toString(),
            volumeTitle: null,
            wordCount: null,
            updatedAt: null,
            isLocked: null,
            attributes: Object.freeze([]),
          }),
        ),
      ),
    });
    // Adding to the shelf can ask for the catalog immediately after detail.
    // Keep the fully parsed result, including page aggregation, for that route.
    this.#catalogResults.set(request.id, Object.freeze({ expiresAtMs, value: result }));
    return result;
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

  async #getHtml(
    url: URL,
    referer?: URL,
    cachePolicy?: HtmlCachePolicy,
  ): Promise<string> {
    return (await this.#getHtmlResult(url, referer, cachePolicy)).body;
  }

  async #getHtmlResult(
    url: URL,
    referer?: URL,
    cachePolicy?: HtmlCachePolicy,
  ): Promise<{ readonly body: string; readonly storedAtMs: number }> {
    const request = async (): Promise<string> => {
      this.context.log.debug('source_http_fetch_started');
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
    };
    return cachePolicy === undefined
      ? Object.freeze({ body: await request(), storedAtMs: Date.now() })
      : this.#htmlCache.getOrFetchTextResult(url, cachePolicy, request).then((result) => Object.freeze({ body: result.value, storedAtMs: result.storedAtMs }));
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

  async #parseHotSearches(html: string): Promise<readonly string[]> {
    const cheerio = await loadCheerio();
    const $ = cheerio.load(html);
    const title = $('.title').filter((_, element) =>
      compactSourceText($(element).text()) === '热门推荐小说',
    ).first();
    if (title.length === 0) return Object.freeze([]);
    const section = title.closest('.innerss');
    const seen = new Set<string>();
    const queries = section.find('.details ul.item-list > li a.titles')
      .toArray()
      .flatMap((element) => {
        const query = textOrNull($(element).text());
        if (query === null || seen.has(query)) return [];
        seen.add(query);
        return [query];
      });
    return Object.freeze(queries);
  }

  async #loadHomeDiscovery(): Promise<HomeDiscoveryCollections> {
    try {
      const homeUrl = new URL('/', this.#baseUrl);
      const html = await this.#getHtml(homeUrl, undefined, discoveryHomeHtmlCachePolicy);
      const deadlineMs = Date.now() + homeCoverBudgetMs;
      const featuredInput = (await this.#parseHomeFeatured(html, homeUrl)).slice(0, 6);
      const originalsInput = (await this.#parseHomeNamedCollection(html, homeUrl, '原创专区'))
        .slice(0, 6);
      const [featured, originalsWithCovers] = await Promise.all([
        this.#withDiscoveryDetails(featuredInput, { deadlineMs }),
        this.#withCovers(originalsInput, { deadlineMs }),
      ]);
      const originals = originalsWithCovers
        .map((content) => this.#compactHomeSummary(content));
      const popular = (await this.#parseHomeNamedCollection(html, homeUrl, '热门推荐小说'))
        .slice(0, 8)
        .map((content) => this.#compactHomeSummary(content));
      return Object.freeze({
        featured: Object.freeze(featured.map((content) => this.#withProxiedCover(content))),
        originals: Object.freeze(originals.map((content) => this.#withProxiedCover(content))),
        popular: Object.freeze(popular.map((content) => this.#withProxiedCover(content))),
      });
    } catch {
      this.context.log.debug('source_discovery_home_unavailable');
      return Object.freeze({ featured: Object.freeze([]), originals: Object.freeze([]), popular: Object.freeze([]) });
    }
  }

  async #parseHomeNamedCollection(
    html: string,
    pageUrl: URL,
    heading: string,
  ): Promise<readonly ContentSummary[]> {
    const cheerio = await loadCheerio();
    const $ = cheerio.load(html);
    const title = $('h2, .title').filter((_, element) => compactSourceText($(element).text()) === heading).first();
    if (title.length === 0) return Object.freeze([]);
    const nearest = title.closest('.innerss, .inner, .container, .hot-box');
    const section = nearest.length === 0 ? title.parent() : nearest;
    const seen = new Set<string>();
    const roots = section.find('.list-group-item, .rec_rullist > ul, .details li').toArray();
    const books = roots.flatMap((element) => this.#parseBookElement($, element, pageUrl, seen));
    const linkedBooks = section.find('a[href*="/novel/"]').toArray()
      .flatMap((element) => this.#parseBookElement($, element, pageUrl, seen));
    return Object.freeze([...books, ...linkedBooks]);
  }

  #compactHomeSummary(content: ContentSummary): ContentSummary {
    return Object.freeze({
      ...content,
      description: content.description === null ? null : content.description.slice(0, 120),
      tags: Object.freeze(content.tags.slice(0, 3)),
      attributes: Object.freeze(content.attributes.slice(0, 2)),
    });
  }

  async #parseHomeFeatured(
    html: string,
    pageUrl: URL,
  ): Promise<readonly ContentSummary[]> {
    const cheerio = await loadCheerio();
    const $ = cheerio.load(html);
    const title = $('h2, .title').filter((_, element) =>
      compactSourceText($(element).text()).includes('重磅推荐'),
    ).first();
    if (title.length === 0) return Object.freeze([]);
    const section = title.closest('.hot-box').length !== 0
      ? title.closest('.hot-box')
      : title.closest('.inner');
    const seen = new Set<string>();
    const roots = section.find('.hot-data').toArray();
    const books = roots.flatMap((element) => this.#parseBookElement($, element, pageUrl, seen));
    // The site currently wraps several recommendation cards in one
    // `.hot-data` container. Parse each novel link as well so one wrapper
    // never collapses the whole recommendation group into its first book.
    const linkedBooks = section.find('a[href*="/novel/"]')
      .toArray()
      .flatMap((element) => this.#parseBookElement($, element, pageUrl, seen));
    return Object.freeze([
      ...books,
      ...linkedBooks,
    ]);
  }

  #parseBookElement(
    $: cheerio.CheerioAPI,
    element: Element,
    pageUrl: URL,
    seen: Set<string>,
  ): readonly ContentSummary[] {
    const root = $(element);
    const links = root.is('a[href*="/novel/"]')
      ? [root]
      : root.find('a[href*="/novel/"]').toArray().map((candidate) => $(candidate));
    const link = links.find((candidate) => textOrNull(candidate.text()) !== null) ?? links[0];
    if (link === undefined) return [];
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
        coverUrl: publicCoverUrl(coverCandidate, pageUrl),
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
    if (cached !== undefined && cached.expiresAtMs >= Date.now()) return cached;

    const catalogUrl = this.#catalogPageUrl(novelId, page);
    const cheerio = await loadCheerio();
    const cachedHtml = await this.#getHtmlResult(catalogUrl, catalogUrl, catalogHtmlCachePolicy);
    const $ = cheerio.load(cachedHtml.body);
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
      expiresAtMs: cachedHtml.storedAtMs + catalogHtmlCachePolicy.staleAfterMs,
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
    return publicCoverUrl(
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
    { deadlineMs }: { readonly deadlineMs?: number } = {},
  ): Promise<readonly ContentSummary[]> {
    return hydrateDetailsInOrder(contents, {
      maximumConcurrency: standardDetailMaximumConcurrency,
      ...(deadlineMs === undefined ? {} : { deadlineMs }),
      hydrate: (content) => this.#withCover(content),
      onFailure: (content) => content,
    });
  }

  async #withDiscoveryDetails(
    contents: readonly ContentSummary[],
    {
      maximumConcurrency = standardDetailMaximumConcurrency,
      deadlineMs,
      retryCoverOnFailure = true,
    }: {
      readonly maximumConcurrency?: number;
      readonly deadlineMs?: number;
      readonly retryCoverOnFailure?: boolean;
    } = {},
  ): Promise<readonly ContentSummary[]> {
    return hydrateDetailsInOrder(contents, {
      maximumConcurrency,
      ...(deadlineMs === undefined ? {} : { deadlineMs }),
      hydrate: async (content) => mergeDiscoverySummary(
        content,
        await this.#getDiscoveryDetail({ id: content.id }),
      ),
      onFailure: (content) => retryCoverOnFailure
          ? this.#withCover(content)
          : content,
    });
  }

  async #withRankingDetails(
    contents: readonly ContentSummary[],
  ): Promise<readonly ContentSummary[]> {
    const hydrated = new Array<ContentSummary>(contents.length);
    let nextIndex = 0;
    const worker = async (): Promise<void> => {
      while (nextIndex < contents.length) {
        const index = nextIndex;
        nextIndex += 1;
        const content = contents[index]!;
        try {
          const detail = await this.#getDiscoveryDetail({ id: content.id });
          const merged = mergeDiscoverySummary(content, detail);
          hydrated[index] = Object.freeze({
            ...merged,
            description: merged.description === null
              ? null
              : merged.description.slice(0, rankingDescriptionMaxCharacters),
            tags: Object.freeze(merged.tags.slice(0, rankingTagLimit)),
            attributes: Object.freeze(merged.attributes.slice(0, rankingAttributeLimit)),
          });
        } catch {
          hydrated[index] = await this.#withCover(content);
        }
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

  async #getDiscoveryDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
    const cached = this.#details.get(request.id);
    if (cached !== undefined && cached.expiresAtMs >= Date.now()) return cached.value;
    const inFlight = this.#discoveryDetailRequests.get(request.id);
    if (inFlight !== undefined) return inFlight;
    const pending = this.#loadCachedDetail(request, discoveryDetailProjectionCachePolicy, discoveryDetailHtmlCachePolicy);
    this.#discoveryDetailRequests.set(request.id, pending);
    void pending.then(
      () => this.#discoveryDetailRequests.delete(request.id),
      () => this.#discoveryDetailRequests.delete(request.id),
    );
    return pending;
  }

  async #loadCachedDetail(
    request: ContentReferenceRequest,
    projectionPolicy: HtmlCachePolicy,
    htmlPolicy: HtmlCachePolicy,
  ): Promise<ContentDetail> {
    const cached = this.#details.get(request.id);
    if (cached !== undefined && cached.expiresAtMs >= Date.now()) return cached.value;
    const result = await this.#htmlCache.getOrFetchJsonResult(
      `detail:${request.id}`,
      projectionPolicy,
      async (): Promise<CachedResult<ContentDetail>> => {
        const detail = await this.#loadDetail(request, htmlPolicy);
        const stored = this.#details.get(request.id);
        return Object.freeze({ value: detail, storedAtMs: stored === undefined ? Date.now() : stored.expiresAtMs - htmlPolicy.staleAfterMs });
      },
      decodeDetail,
    );
    this.#details.set(request.id, Object.freeze({ expiresAtMs: result.storedAtMs + projectionPolicy.staleAfterMs, value: result.value }));
    this.#coverUrls.set(request.id, result.value.coverUrl);
    this.#chapterCounts.set(request.id, result.value.chapterCount);
    return result.value;
  }

  async #loadCachedChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const cached = this.#catalogResults.get(request.id);
    if (cached !== undefined && cached.expiresAtMs >= Date.now()) return cached.value;
    const result = await this.#htmlCache.getOrFetchJsonResult(
      `catalog:${request.id}`,
      catalogProjectionCachePolicy,
      async (): Promise<CachedResult<ChaptersResult>> => {
        const catalog = await this.#loadChapters(request);
        const stored = this.#catalogResults.get(request.id);
        return Object.freeze({ value: catalog, storedAtMs: stored === undefined ? Date.now() : stored.expiresAtMs - catalogProjectionCachePolicy.staleAfterMs });
      },
      decodeCatalog,
    );
    this.#catalogResults.set(request.id, Object.freeze({ expiresAtMs: result.storedAtMs + catalogProjectionCachePolicy.staleAfterMs, value: result.value }));
    return result.value;
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
      const $ = cheerio.load(
        await this.#getHtml(detailUrl, detailUrl, detailHtmlCachePolicy),
      );
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

  #withProxiedCover<T extends ContentSummary>(content: T): T {
    const coverUrl = content.coverUrl;
    if (coverUrl === null) return content;
    let proxied = this.#proxiedCoverUrls.get(coverUrl);
    if (proxied === undefined) {
      try {
        proxied = this.context.resource.proxy({ url: coverUrl });
        this.#proxiedCoverUrls.set(coverUrl, proxied);
      } catch {
        return content;
      }
    }
    return Object.freeze({ ...content, coverUrl: proxied });
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

  #decodeRankingTarget(target: string): RankingRule {
    const id = target.startsWith('ranking:') ? target.slice('ranking:'.length) : '';
    const ranking = rankingRules.find((candidate) => candidate.id === id);
    if (ranking === undefined) throw new Error('Ranking target is invalid.');
    return ranking;
  }
}

function decodeDetail(value: unknown): ContentDetail | undefined {
  if (!isRecord(value) || typeof value.id !== 'string' || typeof value.title !== 'string' || value.contentKind !== 'novel' || !Array.isArray(value.aliases) || !(typeof value.catalogUrl === 'string' || value.catalogUrl === null)) return undefined;
  return value as unknown as ContentDetail;
}

function decodeCatalog(value: unknown): ChaptersResult | undefined {
  if (!isRecord(value) || !Array.isArray(value.items)) return undefined;
  if (!value.items.every((item) => isRecord(item) && typeof item.id === 'string' && typeof item.title === 'string' && Number.isSafeInteger(item.order))) return undefined;
  return value as unknown as ChaptersResult;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
