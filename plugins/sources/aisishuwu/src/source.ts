import type * as cheerio from 'cheerio';
import type { Element } from 'domhandler';

import type {
  ChapterContent,
  ChaptersRequest,
  ChaptersResult,
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
        tabs: Object.freeze([]),
        selectedTabId: null,
        nextCursor: null,
        sections: Object.freeze([
          Object.freeze({
            id: 'source-categories',
            title: '分类',
            subtitle: null,
            layout: 'categories' as const,
            items: Object.freeze([]),
            categories: Object.freeze(
              this.#categories.map((category) =>
                Object.freeze({
                  id: `category:${category.id}`,
                  title: category.title,
                  target: `category:${category.id}`,
                  count: null,
                  url: null,
                }),
              ),
            ),
          }),
        ]),
      });
    }

    const category = this.#decodeCategoryTarget(request.target);
    const page = decodePageCursor(request.cursor, 'category-page');
    const pageUrl = new URL(`/lists/${category.id}.html`, this.#baseUrl);
    pageUrl.searchParams.set('page', String(page));
    const items = await this.#parseList(await this.#getHtml(pageUrl), pageUrl);
    const visible = items.slice(0, request.pageSize);

    return Object.freeze({
      tabs: Object.freeze([]),
      selectedTabId: null,
      nextCursor:
        items.length >= request.pageSize
          ? encodePageCursor('category-page', page + 1)
          : null,
      sections: Object.freeze([
        Object.freeze({
          id: `category-results:${category.id}:${page}`,
          title: category.title,
          subtitle: null,
          layout: 'list' as const,
          categories: Object.freeze([]),
          items: Object.freeze(
            visible.map((content) =>
              Object.freeze({
                content,
                rank: null,
                metric: null,
                recommendation: null,
              }),
            ),
          ),
        }),
      ]),
    });
  }

  async search(request: SearchRequest): Promise<SearchResult> {
    const page = decodePageCursor(request.cursor, 'search-page');
    const searchUrl = new URL('/search.html', this.#baseUrl);
    searchUrl.searchParams.set('q', request.query);
    searchUrl.searchParams.set('f', '_all');
    searchUrl.searchParams.set('p', String(page));
    const items = await this.#parseList(await this.#getHtml(searchUrl), searchUrl);

    return Object.freeze({
      items: Object.freeze(items.slice(0, request.pageSize)),
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
    const author = textOrNull($('.novel_info a[href*="f=author"]').first().text());
    const description =
      textOrNull($('.jianjie p').first().text()) ??
      textOrNull($('meta[name="description"]').attr('content'));
    const category = textOrNull($('.bread-crumbs a[href*="/lists/"]').first().text());
    const latestLink = $('.novel_info a[href*="/book/"]').first();
    const latestHref = latestLink.attr('href');
    const latestChapter =
      latestHref === undefined || textOrNull(latestLink.text()) === null
        ? null
        : Object.freeze({
            id: this.#chapterId(this.#sourceUrl(latestHref, detailUrl)),
            title: requiredText(latestLink.text()),
            url: this.#sourceUrl(latestHref, detailUrl).toString(),
            updatedAt: null,
          });

    return Object.freeze({
      ...this.#summary({
        novelId,
        title,
        author,
        description,
        category,
        coverUrl: this.#coverUrl($, detailUrl),
        latestChapter,
      }),
      aliases: Object.freeze([]),
      catalogUrl: new URL(`/other/chapters/id/${novelId}.html`, this.#baseUrl).toString(),
    });
  }

  async getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const novelId = decodeNovelId(request.id);
    const offset = decodePageCursor(request.cursor, 'chapter-offset') - 1;
    const catalogUrl = new URL(`/other/chapters/id/${novelId}.html`, this.#baseUrl);
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
    const page = chapters.slice(offset, offset + request.pageSize);

    return Object.freeze({
      items: Object.freeze(
        page.map((chapter, index) =>
          Object.freeze({
            id: chapter.id,
            title: chapter.title,
            order: offset + index,
            url: chapter.url.toString(),
            volumeTitle: null,
            wordCount: null,
            updatedAt: null,
            isLocked: null,
            attributes: Object.freeze([]),
          }),
        ),
      ),
      nextCursor:
        offset + page.length < chapters.length
          ? encodePageCursor('chapter-offset', offset + page.length + 1)
          : null,
      totalCount: chapters.length,
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
    return [
      this.#summary({
        novelId,
        title,
        author,
        description,
        category,
        coverUrl: null,
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
      status: 'unknown' as ContentStatus,
      access: 'unknown',
      wordCount: null,
      chapterCount: null,
      publishedAt: null,
      updatedAt: null,
      latestChapter: input.latestChapter,
      categories: input.category === null ? Object.freeze([]) : Object.freeze([input.category]),
      tags: Object.freeze([]),
      attributes: Object.freeze([]),
    });
  }

  #coverUrl($: cheerio.CheerioAPI, detailUrl: URL): string | null {
    const candidate =
      $('meta[property="og:image"]').attr('content') ??
      $('.pic img, img.fengmian2').first().attr('data-src') ??
      $('.pic img, img.fengmian2').first().attr('src');
    return candidate === undefined ? null : publicHttpUrl(candidate, detailUrl);
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
