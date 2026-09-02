/**
 * Public HTML parser and manga image proxy for P5 Hanman.
 *
 * The entry domain may redirect, but stable identities are numeric path tokens. Runtime owns
 * HTTP and resource transport.
 */
import { createHash } from 'node:crypto';
import * as cheerio from 'cheerio/slim';
import { BoundedTextCache } from './cache.js';
import type { MgReadPluginContext } from '@mgread/source-api';

export type Context = MgReadPluginContext;

interface LatestChapter {
  readonly id: string | null;
  readonly title: string;
  readonly url: string | null;
  readonly updatedAt: null;
}

interface Summary {
  readonly id: string;
  readonly title: string;
  readonly contentKind: 'manga';
  readonly author: string | null;
  readonly url: string;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly language: null;
  readonly status: 'ongoing' | 'completed' | 'unknown';
  readonly access: 'free';
  readonly wordCount: null;
  readonly chapterCount: number | null;
  readonly publishedAt: null;
  readonly updatedAt: null;
  readonly latestChapter: LatestChapter | null;
  readonly categories: readonly string[];
  readonly tags: readonly string[];
  readonly attributes: readonly never[];
}

interface Listing {
  readonly items: readonly Summary[];
  readonly hasNext: boolean;
}

type ImagePurpose = 'cover' | 'page';

const siteOrigin = 'https://www.4p5mha.work';
const listingPolicy = Object.freeze({
  namespace: 'listing',
  staleAfterMs: 10 * 60 * 1000,
  serveStaleWhileRevalidate: true,
});
const detailPolicy = Object.freeze({
  namespace: 'detail',
  staleAfterMs: 60 * 60 * 1000,
  allowStaleOnError: false,
});

export const categories = Object.freeze([
  ['latest', '最新更新'],
  ['popular', '热门漫画'],
  ['completed', '完结漫画'],
] as const);

export class P5HanmanSource {
  readonly #cache: BoundedTextCache;
  readonly #allowedSiteOrigins = new Set([siteOrigin]);

  constructor(private readonly context: Context) {
    this.#cache = new BoundedTextCache(context.cacheDir);
  }

  async search(query: string): Promise<readonly Summary[]> {
    const normalized = clean(query);
    if (normalized === null) return Object.freeze([]);
    const url = new URL('/search', siteOrigin);
    url.searchParams.set('q', normalized);
    const html = await this.#cache.getOrFetchText(
      url,
      listingPolicy,
      async () => (await this.#fetchHtml(url)).body,
    );
    return this.#parseCards(html, url, 'unknown', '漫画', 1).items;
  }

  async discover(categoryId: string, page: number): Promise<Listing> {
    const category = categories.find(([id]) => id === categoryId);
    if (category === undefined) throw new Error('Unknown category.');
    const url = listingUrl(categoryId, page);
    const html = await this.#cache.getOrFetchText(
      url,
      listingPolicy,
      async () => (await this.#fetchHtml(url)).body,
    );
    return this.#parseCards(
      html,
      url,
      categoryId === 'completed' ? 'completed' : 'unknown',
      category[1],
      page,
    );
  }

  async getDetail(id: string) {
    const bookId = parseBookId(id);
    const url = bookUrl(bookId);
    const html = await this.#cache.getOrFetchText(
      url,
      detailPolicy,
      async () => (await this.#fetchHtml(url)).body,
    );
    const parsed = this.#parseDetail(html, bookId, url);
    return Object.freeze({
      ...parsed.summary,
      aliases: Object.freeze([]),
      catalogUrl: url.toString(),
    });
  }

  async getChapters(id: string) {
    const bookId = parseBookId(id);
    const url = bookUrl(bookId);
    const html = await this.#cache.getOrFetchText(
      url,
      detailPolicy,
      async () => (await this.#fetchHtml(url)).body,
    );
    const chapters = this.#parseDetail(html, bookId, url).chapters;
    if (chapters.length === 0) throw new Error('Catalog is empty.');
    return Object.freeze({ items: chapters });
  }

  async getContent(id: string, chapterId: string) {
    const bookId = parseBookId(id);
    const parsedChapter = parseChapterId(chapterId);
    if (parsedChapter.bookId !== bookId) {
      throw new Error('Chapter does not belong to the requested manga.');
    }
    const url = chapterUrl(parsedChapter.chapterId);
    const page = await this.#fetchHtml(url);
    const $ = cheerio.load(page.body);
    const seen = new Set<string>();
    const images: URL[] = [];
    $('.comicpage img.lazy[data-original]').each((_, element) => {
      const raw = $(element).attr('data-original');
      if (raw === undefined) return;
      const image = readImageUrl(raw, 'page');
      if (image === null || seen.has(image.toString())) return;
      seen.add(image.toString());
      images.push(image);
    });
    if (images.length === 0) throw new Error('Chapter images are missing.');
    const title = clean($('.comic-name .title,.comic-name h1,h1').first().text());
    return Object.freeze({
      chapterId,
      contentKind: 'manga' as const,
      title,
      updatedAt: null,
      text: null,
      pages: Object.freeze(
        images.map((image, index) =>
          Object.freeze({
            id: pageId(image),
            index,
            url: this.#proxyImage(image, page.finalUrl, 'page'),
            resourcePolicy: 'sessionOnly' as const,
            expiresAt: null,
            mimeType: mimeType(image),
            width: null,
            height: null,
          }),
        ),
      ),
    });
  }

  #parseCards(
    html: string,
    baseUrl: URL,
    status: Summary['status'],
    category: string,
    currentPage: number,
  ): Listing {
    const $ = cheerio.load(html);
    const seen = new Set<string>();
    const items: Summary[] = [];
    $('.mh-item,.mh-itme-top').each((_, element) => {
      const root = $(element);
      const links = root.find('a[href*="/book/"]');
      let bookId: string | null = null;
      for (const link of links.toArray()) {
        const href = $(link).attr('href');
        if (href === undefined) continue;
        bookId = bookIdFromUrl(new URL(href, baseUrl));
        if (bookId !== null) break;
      }
      const title =
        clean(root.find('.title').first().text()) ??
        clean(root.find('a[title]').first().attr('title'));
      if (bookId === null || title === null || seen.has(bookId)) return;
      seen.add(bookId);
      const coverRaw = root
        .find('.mh-cover[data-original],.lazy[data-original]')
        .first()
        .attr('data-original');
      const cover =
        coverRaw === undefined
          ? null
          : readImageUrl(new URL(coverRaw, baseUrl).toString(), 'cover');
      const author = clean(root.find('.author').first().text());
      const latest = clean(root.find('.chapter').first().text());
      items.push(
        summary({
          bookId,
          title,
          author,
          coverUrl:
            cover === null
              ? null
              : this.#proxyImage(cover, baseUrl, 'cover'),
          description: null,
          status,
          chapterCount: null,
          latest:
            latest === null
              ? null
              : Object.freeze({
                  id: null,
                  title: latest,
                  url: null,
                  updatedAt: null,
                }),
          categories: [category],
        }),
      );
    });
    const hasNext = $('.pagination a[href*="page="]')
      .toArray()
      .some((element) => {
        const href = $(element).attr('href');
        if (href === undefined) return false;
        const page = Number(new URL(href, baseUrl).searchParams.get('page'));
        return Number.isSafeInteger(page) && page > currentPage;
      });
    return Object.freeze({ items: Object.freeze(items), hasNext });
  }

  #parseDetail(html: string, bookId: string, url: URL) {
    const $ = cheerio.load(html);
    const title = clean($('.banner_detail h1,h1').first().text());
    if (title === null) throw new Error('Detail title is missing.');
    const info = $('.banner_detail .info').first();
    const authorTip = info
      .find('.tip')
      .filter((_, element) => /作者/u.test($(element).text()))
      .first();
    const author =
      clean(authorTip.find('a').first().text()) ??
      clean(authorTip.find('span').eq(1).text()) ??
      clean(/作者[：:]?\s*([^\s]+)/u.exec(authorTip.text())?.[1]);
    const statusTip = info
      .find('.tip')
      .filter((_, element) => /(?:状态|连载|完结)/u.test($(element).text()))
      .first();
    const status = parseStatus(clean(statusTip.text()));
    const description = clean(info.find('.content').first().text());
    const categories = Object.freeze(
      info
        .find('.ticai a')
        .toArray()
        .flatMap((element) => clean($(element).text()) ?? []),
    );
    const coverRaw = $('.banner_detail .cover img[data-original]')
      .first()
      .attr('data-original');
    const cover =
      coverRaw === undefined
        ? null
        : readImageUrl(new URL(coverRaw, url).toString(), 'cover');
    const seen = new Set<string>();
    const chapters: {
      readonly id: string;
      readonly title: string;
      readonly order: number;
      readonly url: string;
      readonly volumeTitle: null;
      readonly wordCount: null;
      readonly updatedAt: null;
      readonly isLocked: false;
      readonly attributes: readonly never[];
    }[] = [];
    $('.detail-list-select a[href*="/chapter/"]').each((_, element) => {
      const href = $(element).attr('href');
      const chapterTitle = clean($(element).text());
      if (href === undefined || chapterTitle === null) return;
      const chapterId = chapterIdFromUrl(new URL(href, url));
      if (chapterId === null || seen.has(chapterId)) return;
      seen.add(chapterId);
      chapters.push(
        Object.freeze({
          id: contentChapterId(bookId, chapterId),
          title: chapterTitle,
          order: chapters.length,
          url: chapterUrl(chapterId).toString(),
          volumeTitle: null,
          wordCount: null,
          updatedAt: null,
          isLocked: false,
          attributes: Object.freeze([]),
        }),
      );
    });
    const latestChapter = chapters.at(-1);
    const currentSummary = summary({
      bookId,
      title,
      author,
      coverUrl:
        cover === null ? null : this.#proxyImage(cover, url, 'cover'),
      description,
      status,
      chapterCount: chapters.length,
      latest:
        latestChapter === undefined
          ? null
          : Object.freeze({
              id: latestChapter.id,
              title: latestChapter.title,
              url: latestChapter.url,
              updatedAt: null,
            }),
      categories: categories.length === 0 ? ['漫画'] : categories,
    });
    return Object.freeze({
      summary: currentSummary,
      chapters: Object.freeze(chapters),
    });
  }

  async #fetchHtml(url: URL): Promise<{ readonly body: string; readonly finalUrl: URL }> {
    if (url.origin !== siteOrigin) throw new Error('Source URL is invalid.');
    const response = await this.context.http.fetch(url, {
      headers: { accept: 'text/html,application/xhtml+xml', referer: `${siteOrigin}/` },
    });
    if (!response.ok) throw new Error('Source page is unavailable.');
    const finalUrl = response.url === '' ? url : new URL(response.url);
    if (finalUrl.protocol !== 'https:') throw new Error('Source redirect is invalid.');
    this.#allowedSiteOrigins.add(finalUrl.origin);
    const body = await response.text();
    if (body === '' || isChallenge(body)) {
      throw new Error('Source response is unavailable.');
    }
    return Object.freeze({ body, finalUrl });
  }

  #proxyImage(url: URL, referer: URL, purpose: ImagePurpose): string {
    const image = readImageUrl(url.toString(), purpose);
    const page = this.#readAllowedReferer(referer.toString(), purpose);
    if (image === null || page === null) throw new Error('Image request is invalid.');
    return this.context.resource.proxy({
      kind: 'p5-image',
      purpose,
      url: image.toString(),
      headers: { Accept: 'image/*', Referer: page.toString() },
    });
  }

  #isAllowedReferer(url: URL): boolean {
    return this.#allowedSiteOrigins.has(url.origin);
  }

  #readAllowedReferer(value: string, purpose: ImagePurpose): URL | null {
    const referer = readHttpsUrl(value);
    if (referer === null || !this.#isAllowedReferer(referer)) return null;
    if (purpose === 'page' && !/^\/chapter\/\d+\/?$/u.test(referer.pathname)) {
      return null;
    }
    if (
      purpose === 'cover' &&
      !/^\/(?:$|update\/?$|rank\/?$|booklist\/?$|search\/?$|book\/\d+\/?$)/u.test(
        referer.pathname,
      )
    ) {
      return null;
    }
    return referer;
  }
}

function summary(input: {
  readonly bookId: string;
  readonly title: string;
  readonly author: string | null;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly status: Summary['status'];
  readonly chapterCount: number | null;
  readonly latest: LatestChapter | null;
  readonly categories: readonly string[];
}): Summary {
  return Object.freeze({
    id: contentId(input.bookId),
    title: input.title,
    contentKind: 'manga',
    author: input.author,
    url: bookUrl(input.bookId).toString(),
    coverUrl: input.coverUrl,
    description: input.description,
    language: null,
    status: input.status,
    access: 'free',
    wordCount: null,
    chapterCount: input.chapterCount,
    publishedAt: null,
    updatedAt: null,
    latestChapter: input.latest,
    categories: Object.freeze(input.categories),
    tags: Object.freeze(['漫画']),
    attributes: Object.freeze([]),
  });
}

function listingUrl(categoryId: string, page: number): URL {
  if (categoryId === 'popular') return new URL('/rank', siteOrigin);
  if (categoryId === 'completed') {
    const url = new URL('/booklist', siteOrigin);
    url.searchParams.set('end', '1');
    if (page > 1) url.searchParams.set('page', String(page));
    return url;
  }
  if (categoryId !== 'latest') throw new Error('Unknown category.');
  if (page === 1) return new URL('/update', siteOrigin);
  const url = new URL('/booklist', siteOrigin);
  url.searchParams.set('page', String(page));
  return url;
}

function contentId(bookId: string): string {
  return `manga:${bookId}`;
}

function parseBookId(value: string): string {
  const bookId = /^manga:(\d+)$/u.exec(value)?.[1];
  if (bookId === undefined) throw new Error('Content ID is invalid.');
  return bookId;
}

function contentChapterId(bookId: string, chapterId: string): string {
  return `chapter:${bookId}:${chapterId}`;
}

function parseChapterId(value: string): { readonly bookId: string; readonly chapterId: string } {
  const match = /^chapter:(\d+):(\d+)$/u.exec(value);
  if (match?.[1] === undefined || match[2] === undefined) {
    throw new Error('Chapter ID is invalid.');
  }
  return Object.freeze({ bookId: match[1], chapterId: match[2] });
}

function bookIdFromUrl(url: URL): string | null {
  return /^\/book\/(\d+)\/?$/u.exec(url.pathname)?.[1] ?? null;
}

function chapterIdFromUrl(url: URL): string | null {
  return /^\/chapter\/(\d+)\/?$/u.exec(url.pathname)?.[1] ?? null;
}

function bookUrl(bookId: string): URL {
  return new URL(`/book/${bookId}`, siteOrigin);
}

function chapterUrl(chapterId: string): URL {
  return new URL(`/chapter/${chapterId}`, siteOrigin);
}

function readImageUrl(value: string, purpose: ImagePurpose): URL | null {
  const url = readHttpsUrl(value);
  if (url === null) return null;
  if (purpose === 'page') {
    return url.hostname === 'cfpic.se8manhua.club' ? url : null;
  }
  return url.hostname === 'cover.aabamh.com' || url.hostname === 'stpic.se8manhua.club'
    ? url
    : null;
}

function readHttpsUrl(value: string): URL | null {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.username === '' && url.password === ''
      ? url
      : null;
  } catch {
    return null;
  }
}

function parseStatus(value: string | null): Summary['status'] {
  if (value?.includes('完结') === true) return 'completed';
  if (value?.includes('连载') === true) return 'ongoing';
  return 'unknown';
}

function pageId(url: URL): string {
  return `page:${createHash('sha256').update(url.toString()).digest('hex').slice(0, 24)}`;
}

function mimeType(url: URL): string | null {
  const extension = /\.([^.]+)$/u.exec(url.pathname)?.[1]?.toLowerCase();
  if (extension === 'jpg' || extension === 'jpeg') return 'image/jpeg';
  if (extension === 'png') return 'image/png';
  if (extension === 'webp') return 'image/webp';
  if (extension === 'gif') return 'image/gif';
  return null;
}

function clean(value: string | undefined): string | null {
  const normalized = value?.replace(/[\u00a0\u3000]/gu, ' ').replace(/\s+/gu, ' ').trim() ?? '';
  return normalized === '' ? null : normalized;
}

function isChallenge(body: string): boolean {
  return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body);
}
