/**
 * Elkoparts public-page parser and MgRead projection.
 *
 * Responsibilities: own stable source IDs, same-origin navigation, HTML parsing, bounded catalog fan-out,
 * and source-resource proxy requests. This module never owns shelf/progress state and never uses browser sessions.
 */

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
  DiscoveryContentItem,
  DiscoveryContinuation,
  MgReadPluginContext,
  ResourceResponse,
  SearchRequest,
  SearchResult,
  SearchSuggestionsRequest,
  SearchSuggestionsResult,
} from './mgread-api.js';

const sourceOrigin = 'http://www.elkoparts.net';
const catalogPageLimit = 250;
const catalogConcurrency = 8;

const categories = Object.freeze([
  { id: '1', title: '玄幻奇幻', icon: 'fantasy' as const },
  { id: '2', title: '武侠仙侠', icon: 'wuxia' as const },
  { id: '3', title: '都市言情', icon: 'urban' as const },
  { id: '4', title: '历史军事', icon: 'history' as const },
  { id: '5', title: '网游竞技', icon: 'game' as const },
  { id: '6', title: '科幻灵异', icon: 'scienceFiction' as const },
  { id: '7', title: '女生频道', icon: 'romance' as const },
]);

interface BookKey { readonly group: string; readonly book: string }
interface ChapterKey extends BookKey { readonly chapter: string }

export class ElkopartsSource {
  readonly #context: MgReadPluginContext;

  constructor(context: MgReadPluginContext) {
    this.#context = context;
  }

  async discover(request: DiscoverRequest): Promise<DiscoverResult> {
    const pageSize = boundedPageSize(request.pageSize);
    if (request.target === null) {
      if (request.cursor !== null || request.collectionId !== null) throw new Error('Initial discovery request is invalid.');
      const home = await this.#fetchHtml(new URL('/', sourceOrigin));
      const latest = this.#parseRowBooks(home, new URL('/', sourceOrigin)).slice(0, pageSize);
      return {
        kind: 'document',
        document: {
          components: [
            {
              type: 'section',
              id: 'elkoparts-latest-section',
              title: '最近更新',
              subtitle: null,
              icon: 'newRelease',
              children: [{
                type: 'contentCollection',
                id: 'elkoparts-latest',
                layout: 'compact',
                items: latest.map(toDiscoveryItem),
                continuation: null,
              }],
            },
            {
              type: 'section',
              id: 'elkoparts-categories-section',
              title: '小说分类',
              subtitle: null,
              icon: 'category',
              children: [{
                type: 'categoryCollection',
                id: 'elkoparts-categories',
                layout: 'chips',
                categories: categories.map((category) => ({
                  id: `category-${category.id}`,
                  title: category.title,
                  target: `category:${category.id}`,
                  count: null,
                  url: new URL(`/ksl/${category.id}/1.html`, sourceOrigin).toString(),
                  icon: category.icon,
                })),
              }],
            },
          ],
        },
      };
    }

    const category = decodeCategory(request.target);
    const page = decodePageCursor(request.cursor);
    const collectionId = `elkoparts-category-${category.id}`;
    if (request.collectionId !== null && request.collectionId !== collectionId) {
      throw new Error('Discovery collection is invalid.');
    }
    const pageUrl = new URL(`/ksl/${category.id}/${page}.html`, sourceOrigin);
    const html = await this.#fetchHtml(pageUrl);
    const items = this.#parseCategoryBooks(html, pageUrl).slice(0, pageSize).map(toDiscoveryItem);
    const nextPage = findNextCategoryPage(html, category.id, page);
    const continuation: DiscoveryContinuation | null = nextPage === null
      ? null
      : { target: request.target, cursor: String(nextPage) };
    if (request.collectionId !== null) {
      return { kind: 'append', collectionId, items, continuation };
    }
    return {
      kind: 'document',
      document: {
        components: [{
          type: 'section',
          id: `${collectionId}-section`,
          title: category.title,
          subtitle: null,
          children: [{
            type: 'contentCollection',
            id: collectionId,
            layout: 'coverGrid',
            items,
            continuation,
          }],
        }],
      },
    };
  }

  async search(request: SearchRequest): Promise<SearchResult> {
    if (request.cursor !== null) throw new Error('Search cursor is not supported.');
    const query = request.query.trim();
    if (query.length === 0) return { items: [], nextCursor: null, totalCount: 0 };
    const url = new URL('/search.php', sourceOrigin);
    url.searchParams.set('keyWord', query);
    const html = await this.#fetchHtml(url);
    return {
      items: this.#parseRowBooks(html, url).slice(0, boundedPageSize(request.pageSize)),
      nextCursor: null,
      totalCount: null,
    };
  }

  searchSuggestions(_request: SearchSuggestionsRequest): SearchSuggestionsResult {
    return { items: [], nextCursor: null };
  }

  async getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
    const key = decodeBookId(request.id);
    const url = bookUrl(key);
    const html = await this.#fetchHtml(url);
    const title = textFromMatch(html, /<div\s+class=["'][^"']*info[^"']*["'][^>]*>[\s\S]*?<h1[^>]*>([\s\S]*?)<\/h1>/iu);
    if (title === null) throw new Error('Source detail title is missing.');
    const infoLines = captures(html, /<p[^>]*>([\s\S]*?)<\/p>/giu).map((value) => compact(decodeHtml(stripTags(value))));
    const author = prefixedValue(infoLines, '作者：');
    const category = prefixedValue(infoLines, '类别：');
    const statusText = prefixedValue(infoLines, '状态：');
    const coverTag = firstCapture(html, /<div\s+class=["'][^"']*imgbox[^"']*["'][^>]*>[\s\S]*?(<img\b[^>]*>)/iu);
    const cover = this.#coverProxy(normalizeSourceUrl(coverTag === null ? undefined : attribute(coverTag, 'src'), url));
    const description = normalizeDescription(
      textFromMatch(html, /<div\s+class=["'][^"']*\bxdesc\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/iu)
      ?? textFromMatch(html, /<div\s+class=["'][^"']*\bdesc\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/iu),
    );
    const latestBlock = firstCapture(html, /<p[^>]*>\s*最新(?:章节)?[：:]([\s\S]*?)<\/p>/iu) ?? '';
    const latest = firstLink(latestBlock, /^https?:\/\/www\.elkoparts\.net\/kanshu\/\d+\/\d+\/\d+\.html$|^\/kanshu\/\d+\/\d+\/\d+\.html$/u);
    const latestUrl = normalizeSourceUrl(latest?.href, url);
    const latestTitle = latest?.title ?? null;
    const chapterCount = parseChapterCount(html);
    return {
      ...summary({
        key,
        title,
        author,
        category,
        coverUrl: cover,
        description,
        status: contentStatus(statusText),
        chapterCount,
        latestChapter: latestUrl === null || latestTitle === null
          ? null
          : { id: chapterIdFromUrl(latestUrl), title: latestTitle, url: latestUrl.toString(), updatedAt: null },
      }),
      aliases: [],
      catalogUrl: url.toString(),
    };
  }

  async getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
    const key = decodeBookId(request.id);
    const firstUrl = bookUrl(key);
    const firstHtml = await this.#fetchHtml(firstUrl);
    const pageUrls = catalogPageUrls(firstHtml, firstUrl).slice(0, catalogPageLimit);
    const htmlPages = new Array<string>(pageUrls.length);
    htmlPages[0] = firstHtml;
    let nextIndex = 1;
    const worker = async (): Promise<void> => {
      while (nextIndex < pageUrls.length) {
        const index = nextIndex;
        nextIndex += 1;
        htmlPages[index] = await this.#fetchHtml(pageUrls[index]!);
      }
    };
    await Promise.all(Array.from({ length: Math.min(catalogConcurrency, Math.max(0, pageUrls.length - 1)) }, worker));

    const seen = new Set<string>();
    const chapters = htmlPages.flatMap((html, pageIndex) => this.#parseChapterPage(html, pageUrls[pageIndex]!, key))
      .filter((chapter) => {
        if (seen.has(chapter.id)) return false;
        seen.add(chapter.id);
        return true;
      })
      .slice(0, 5000)
      .map((chapter, order) => ({ ...chapter, order }));
    return { items: chapters };
  }

  async getContent(request: ContentRequest): Promise<ChapterContent> {
    const book = decodeBookId(request.id);
    const chapter = decodeChapterId(request.chapterId);
    if (book.group !== chapter.group || book.book !== chapter.book) {
      throw new Error('Chapter does not belong to the requested content.');
    }
    const url = chapterUrl(chapter);
    const html = await this.#fetchHtml(url);
    const title = textFromMatch(html, /<h1\s+class=["'][^"']*title[^"']*["'][^>]*>([\s\S]*?)<\/h1>/iu);
    const contentHtml = firstCapture(html, /<div\s+class=["'][^"']*content[^"']*["'][^>]*\bid=["']content["'][^>]*>([\s\S]*?)<\/div>/iu)
      ?? firstCapture(html, /<div\s+id=["']content["'][^>]*>([\s\S]*?)<\/div>/iu)
      ?? '';
    const raw = contentHtml
      .replace(/<script\b[\s\S]*?<\/script>/giu, '')
      .replace(/<style\b[\s\S]*?<\/style>/giu, '')
      .replace(/<br\s*\/?\s*>/giu, '\n')
      .replace(/<p(?:\s[^>]*)?>/giu, '\n')
      .replace(/<\/p\s*>/giu, '\n');
    const decoded = decodeHtml(stripTags(raw));
    const paragraphs = decoded.split(/\r?\n/u)
      .map(compact)
      .filter((line) => line.length !== 0 && !isBoilerplate(line));
    return {
      chapterId: request.chapterId,
      contentKind: 'novel',
      title,
      updatedAt: null,
      text: paragraphs.join('\n\n'),
      pages: [],
    };
  }

  async resource(request: Record<string, unknown>): Promise<ResourceResponse> {
    const rawUrl = request.url;
    if (typeof rawUrl !== 'string') return emptyResource(400);
    let url: URL;
    try {
      url = new URL(rawUrl);
    } catch {
      return emptyResource(400);
    }
    if (url.origin !== sourceOrigin || !/^\/(?:files\/article\/image|images)\//u.test(url.pathname)) {
      return emptyResource(400);
    }
    const response = await this.#context.http.fetch(url, { method: 'GET' });
    const contentType = response.headers.get('content-type');
    if (contentType !== null && !contentType.toLowerCase().startsWith('image/')) return emptyResource(502);
    return {
      status: response.status,
      headers: contentType === null ? {} : { 'content-type': contentType },
      body: new Uint8Array(await response.arrayBuffer()),
    };
  }

  #parseRowBooks(html: string, pageUrl: URL): ContentSummary[] {
    const results: ContentSummary[] = [];
    const seen = new Set<string>();
    for (const root of captures(html, /<li\b[^>]*>([\s\S]*?)<\/li>/giu)) {
      const titleLink = firstLink(classBlock(root, 's2') ?? '', /\/kanshu\/\d+\/\d+\//u);
      const url = normalizeSourceUrl(titleLink?.href, pageUrl);
      const title = titleLink?.title ?? null;
      if (url === null || title === null) continue;
      const key = bookKeyFromUrl(url);
      const id = encodeBookId(key);
      if (seen.has(id)) continue;
      seen.add(id);
      const latestLink = firstLink(classBlock(root, 's3') ?? '', /\.html(?:[?#]|$)/u);
      const latestUrl = normalizeSourceUrl(latestLink?.href, pageUrl);
      const latestTitle = latestLink?.title ?? null;
      const category = stripBrackets(textFromHtml(classBlock(root, 's1') ?? ''));
      results.push(summary({
        key,
        title,
        author: textFromHtml(classBlock(root, 's4') ?? ''),
        category,
        coverUrl: this.#coverProxy(coverUrl(key)),
        description: null,
        status: 'unknown',
        chapterCount: null,
        latestChapter: latestUrl === null || latestTitle === null
          ? null
          : { id: chapterIdFromUrl(latestUrl), title: latestTitle, url: latestUrl.toString(), updatedAt: null },
      }));
    }
    return results;
  }

  #parseCategoryBooks(html: string, pageUrl: URL): ContentSummary[] {
    const results: ContentSummary[] = [];
    const seen = new Set<string>();
    for (const root of captures(html, /<div\s+class=["'][^"']*\bitem\b[^"']*["'][^>]*>([\s\S]*?<\/dl>)\s*<\/div>/giu)) {
      const titleLink = firstLink(firstCapture(root, /<dt[^>]*>([\s\S]*?)<\/dt>/iu) ?? '', /\/kanshu\/\d+\/\d+\//u);
      const url = normalizeSourceUrl(titleLink?.href, pageUrl);
      const title = titleLink?.title ?? null;
      if (url === null || title === null) continue;
      const key = bookKeyFromUrl(url);
      const id = encodeBookId(key);
      if (seen.has(id)) continue;
      seen.add(id);
      const imageTag = firstCapture(root, /(<img\b[^>]*>)/iu);
      const authorBlock = firstCapture(root, /<dt[^>]*>[\s\S]*?<span[^>]*>([\s\S]*?)<\/span>/iu) ?? '';
      results.push(summary({
        key,
        title,
        author: textFromHtml(authorBlock),
        category: null,
        coverUrl: this.#coverProxy(normalizeSourceUrl(imageTag === null ? undefined : attribute(imageTag, 'src'), pageUrl) ?? coverUrl(key)),
        description: textFromMatch(root, /<dd[^>]*>([\s\S]*?)<\/dd>/iu),
        status: 'unknown',
        chapterCount: null,
        latestChapter: null,
      }));
    }
    if (results.length !== 0) return results;
    return this.#parseRowBooks(html, pageUrl);
  }

  #parseChapterPage(html: string, pageUrl: URL, key: BookKey): Omit<ChaptersResult['items'][number], 'order'>[] {
    const expectedPrefix = `/kanshu/${key.group}/${key.book}/`;
    const scope = firstCapture(
      html,
      /<h2\s+class=["'][^"']*layout-tit[^"']*["'][^>]*>[^<]*正文<\/h2>\s*<div\s+class=["'][^"']*section-box[^"']*["'][^>]*>([\s\S]*?)<\/div>/iu,
    ) ?? '';
    const results: Omit<ChaptersResult['items'][number], 'order'>[] = [];
    for (const link of links(scope)) {
      const url = normalizeSourceUrl(link.href, pageUrl);
      const title = link.title;
      if (url === null || title === null || !url.pathname.startsWith(expectedPrefix) || !/\/\d+\.html$/u.test(url.pathname)) continue;
      results.push({
        id: chapterIdFromUrl(url),
        title,
        url: url.toString(),
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: [],
      });
    }
    return results;
  }

  async #fetchHtml(url: URL): Promise<string> {
    assertSourceUrl(url);
    const response = await this.#context.http.fetch(url, { method: 'GET' });
    if (!response.ok) throw new Error('Source request failed.');
    return response.text();
  }

  #coverProxy(url: URL | null): string | null {
    if (url === null) return null;
    return this.#context.resource.proxy({ url: url.toString() });
  }
}

function summary(input: {
  readonly key: BookKey;
  readonly title: string;
  readonly author: string | null;
  readonly category: string | null;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly status: ContentStatus;
  readonly chapterCount: number | null;
  readonly latestChapter: ContentSummary['latestChapter'];
}): ContentSummary {
  return {
    id: encodeBookId(input.key),
    title: input.title,
    contentKind: 'novel',
    author: input.author,
    url: bookUrl(input.key).toString(),
    coverUrl: input.coverUrl,
    description: input.description,
    language: 'zh-CN',
    status: input.status,
    access: 'free',
    wordCount: null,
    chapterCount: input.chapterCount,
    publishedAt: null,
    updatedAt: null,
    latestChapter: input.latestChapter,
    categories: input.category === null ? [] : [input.category],
    tags: [],
    attributes: [],
  };
}

function toDiscoveryItem(content: ContentSummary): DiscoveryContentItem {
  return { content, rank: null, metric: null, recommendation: null };
}

function boundedPageSize(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Page size is invalid.');
  return Math.min(value, 50);
}

function decodeCategory(target: string): (typeof categories)[number] {
  const id = target.startsWith('category:') ? target.slice('category:'.length) : '';
  const category = categories.find((candidate) => candidate.id === id);
  if (category === undefined) throw new Error('Discovery target is invalid.');
  return category;
}

function decodePageCursor(cursor: string | null): number {
  if (cursor === null) return 1;
  if (!/^\d+$/u.test(cursor)) throw new Error('Discovery cursor is invalid.');
  const page = Number(cursor);
  if (!Number.isSafeInteger(page) || page < 1 || page > 10_000) throw new Error('Discovery cursor is invalid.');
  return page;
}

function findNextCategoryPage(html: string, categoryId: string, currentPage: number): number | null {
  const expected = currentPage + 1;
  const expectedPath = `/ksl/${categoryId}/${expected}.html`;
  const found = links(html).some((link) => new URL(link.href, sourceOrigin).pathname === expectedPath);
  return found ? expected : null;
}

function catalogPageUrls(html: string, firstUrl: URL): URL[] {
  const urls = [firstUrl];
  const seen = new Set([firstUrl.toString()]);
  for (const tag of html.match(/<option\b[^>]*>/giu) ?? []) {
    const url = normalizeSourceUrl(attribute(tag, 'value'), firstUrl);
    if (url !== null && !seen.has(url.toString())) {
      seen.add(url.toString());
      urls.push(url);
    }
  }
  return urls;
}

function parseChapterCount(html: string): number | null {
  const values = [...html.matchAll(/<option\b[^>]*>([\s\S]*?)<\/option>/giu)]
    .flatMap((match) => {
      const range = decodeHtml(stripTags(match[1] ?? '')).match(/-\s*(\d+)\s*章/u);
      return range === null ? [] : [Number(range[1])];
    });
  return values.length === 0 ? null : Math.max(...values);
}

function prefixedValue(lines: readonly string[], prefix: string): string | null {
  const line = lines.find((candidate) => candidate.startsWith(prefix));
  return line === undefined ? null : text(line.slice(prefix.length));
}

function contentStatus(value: string | null): ContentStatus {
  if (value === null) return 'unknown';
  if (/完结|完本/u.test(value)) return 'completed';
  if (/连载/u.test(value)) return 'ongoing';
  if (/停更|暂停/u.test(value)) return 'hiatus';
  return 'unknown';
}

function normalizeDescription(value: string | null): string | null {
  return value === null ? null : text(value.replace(/^简介[：:]?/u, ''));
}

function stripBrackets(value: string | null): string | null {
  return value === null ? null : text(value.replace(/^\[/u, '').replace(/\]$/u, ''));
}

function compact(value: string): string {
  return value.replace(/\u00a0/gu, ' ').replace(/\s+/gu, ' ').trim();
}

function text(value: string): string | null {
  const normalized = compact(value);
  return normalized.length === 0 ? null : normalized;
}

function isBoilerplate(value: string): boolean {
  return /本章未完|加入书签|推荐本书|返回目录|章节报错|下一章|上一章/u.test(value);
}

function captures(input: string, pattern: RegExp): string[] {
  return [...input.matchAll(pattern)].flatMap((match) => match[1] === undefined ? [] : [match[1]]);
}

function firstCapture(input: string, pattern: RegExp): string | null {
  return input.match(pattern)?.[1] ?? null;
}

function classBlock(input: string, className: string): string | null {
  const escaped = escapeRegExp(className);
  return firstCapture(
    input,
    new RegExp(`<span\\s+class=["'][^"']*\\b${escaped}\\b[^"']*["'][^>]*>([\\s\\S]*?)<\\/span>`, 'iu'),
  );
}

function textFromMatch(input: string, pattern: RegExp): string | null {
  const value = firstCapture(input, pattern);
  return value === null ? null : textFromHtml(value);
}

function textFromHtml(input: string): string | null {
  return text(decodeHtml(stripTags(input)));
}

function links(input: string): { readonly href: string; readonly title: string | null }[] {
  return [...input.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)].flatMap((match) => {
    const href = attribute(match[1] ?? '', 'href');
    if (href === undefined) return [];
    return [{ href, title: textFromHtml(match[2] ?? '') }];
  });
}

function firstLink(
  input: string,
  hrefPattern: RegExp,
): { readonly href: string; readonly title: string | null } | undefined {
  return links(input).find((link) => hrefPattern.test(link.href));
}

function attribute(tag: string, name: string): string | undefined {
  const escaped = escapeRegExp(name);
  const match = tag.match(new RegExp(`\\b${escaped}\\s*=\\s*(["'])([\\s\\S]*?)\\1`, 'iu'));
  return match?.[2] === undefined ? undefined : decodeHtml(match[2]);
}

function stripTags(input: string): string {
  return input.replace(/<[^>]+>/gu, '');
}

function decodeHtml(input: string): string {
  const named: Readonly<Record<string, string>> = {
    amp: '&', apos: "'", gt: '>', lt: '<', nbsp: ' ', quot: '"',
  };
  return input.replace(/&(#(?:x[0-9a-f]+|\d+)|[a-z]+);/giu, (entity, body: string) => {
    const normalized = body.toLowerCase();
    if (normalized.startsWith('#x')) return codePoint(Number.parseInt(normalized.slice(2), 16), entity);
    if (normalized.startsWith('#')) return codePoint(Number.parseInt(normalized.slice(1), 10), entity);
    return named[normalized] ?? entity;
  });
}

function codePoint(value: number, fallback: string): string {
  return Number.isSafeInteger(value) && value >= 0 && value <= 0x10ffff
    ? String.fromCodePoint(value)
    : fallback;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function encodeBookId(key: BookKey): string {
  return `novel:${key.group}:${key.book}`;
}

function decodeBookId(id: string): BookKey {
  const match = id.match(/^novel:(\d+):(\d+)$/u);
  if (match === null) throw new Error('Content ID is invalid.');
  return { group: match[1]!, book: match[2]! };
}

function bookKeyFromUrl(url: URL): BookKey {
  const match = url.pathname.match(/^\/kanshu\/(\d+)\/(\d+)\//u);
  if (match === null) throw new Error('Source content URL is invalid.');
  return { group: match[1]!, book: match[2]! };
}

function chapterIdFromUrl(url: URL): string {
  const key = chapterKeyFromUrl(url);
  return `chapter:${key.group}:${key.book}:${key.chapter}`;
}

function decodeChapterId(id: string): ChapterKey {
  const match = id.match(/^chapter:(\d+):(\d+):(\d+)$/u);
  if (match === null) throw new Error('Chapter ID is invalid.');
  return { group: match[1]!, book: match[2]!, chapter: match[3]! };
}

function chapterKeyFromUrl(url: URL): ChapterKey {
  const match = url.pathname.match(/^\/kanshu\/(\d+)\/(\d+)\/(\d+)\.html$/u);
  if (match === null) throw new Error('Source chapter URL is invalid.');
  return { group: match[1]!, book: match[2]!, chapter: match[3]! };
}

function bookUrl(key: BookKey): URL {
  return new URL(`/kanshu/${key.group}/${key.book}/`, sourceOrigin);
}

function chapterUrl(key: ChapterKey): URL {
  return new URL(`/kanshu/${key.group}/${key.book}/${key.chapter}.html`, sourceOrigin);
}

function coverUrl(key: BookKey): URL {
  return new URL(`/files/article/image/${key.group}/${key.book}/${key.book}s.jpg`, sourceOrigin);
}

function normalizeSourceUrl(value: string | undefined, base: URL): URL | null {
  if (value === undefined || value.trim().length === 0) return null;
  const url = new URL(value, base);
  assertSourceUrl(url);
  return url;
}

function assertSourceUrl(url: URL): void {
  if (url.origin !== sourceOrigin || url.protocol !== 'http:') throw new Error('Source URL is outside the allowed origin.');
}

function emptyResource(status: number): ResourceResponse {
  return { status, headers: {}, body: new Uint8Array() };
}
