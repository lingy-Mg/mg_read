/**
 * 35中文网 parser and HTTP/resource boundary.
 * List pages never hydrate missing covers with per-book requests; detail remains the authoritative cover projection.
 * Only bounded list/book projections are cached in memory. HTML, chapter text, credentials, and user input are never cached or logged.
 */
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import * as cheerio from 'cheerio/slim';

import type { ContentDetail, ContentSummary, MgReadPluginContext } from './contracts.js';
import { ProjectionCache } from './projection-cache.js';

const origin = 'http://www.35ge.info';
export const categories = Object.freeze([
  ['fantasy', '玄幻魔法', '/xs/1-default-0-0-0-0-0-0-1.html'],
  ['wuxia', '武侠修真', '/xs/2-default-0-0-0-0-0-0-1.html'],
  ['urban', '都市言情', '/xs/3-default-0-0-0-0-0-0-1.html'],
  ['history', '历史军事', '/xs/4-default-0-0-0-0-0-0-1.html'],
  ['game', '游戏竞技', '/xs/5-default-0-0-0-0-0-0-1.html'],
  ['science-fiction', '科幻恐怖', '/xs/6-default-0-0-0-0-0-0-1.html'],
  ['other', '其他类型', '/xs/7-default-0-0-0-0-0-0-1.html'],
  ['completed', '完本小说', '/xs/0-default-0-0-0-0-2-0-1.html'],
] as const);

export const projectionCachePolicy = Object.freeze({
  lists: Object.freeze({ capacity: 32, freshTtlMs: 5 * 60_000, staleTtlMs: 30 * 60_000 }),
  books: Object.freeze({ capacity: 64, freshTtlMs: 10 * 60_000, staleTtlMs: 60 * 60_000 }),
});

type ChaptersProjection = Readonly<{ readonly items: readonly Readonly<Record<string, unknown>>[] }>;
interface BookProjection { readonly detail: ContentDetail; readonly chapters: ChaptersProjection }
export interface ThirtyFiveSourceOptions { readonly now?: () => number }

export class ThirtyFiveSource {
  readonly #listCache: ProjectionCache<readonly ContentSummary[]>;
  readonly #bookCache: ProjectionCache<BookProjection>;

  constructor(private readonly context: MgReadPluginContext, options: ThirtyFiveSourceOptions = {}) {
    this.#listCache = new ProjectionCache(projectionCachePolicy.lists, options.now);
    this.#bookCache = new ProjectionCache(projectionCachePolicy.books, options.now);
  }

  async search(query: string): Promise<readonly ContentSummary[]> {
    const url = new URL('/modules/article/search.php', origin);
    url.searchParams.set('searchkey', query);
    return this.#listCache.get(cacheKey('search', query), async () => {
      const $ = cheerio.load(await this.#html(url));
      return this.#parseRows($, '.novelslist2 ul li', url, null);
    });
  }

  async discover(categoryId: string, page: number): Promise<readonly ContentSummary[]> {
    const category = categories.find(([id]) => id === categoryId);
    if (category === undefined) throw new Error('Unknown category.');
    const path = category[2].replace(/-\d+\.html$/u, `-${page}.html`);
    const url = new URL(path, origin);
    return this.#listCache.get(`discover:${categoryId}:${page}`, async () => {
      const $ = cheerio.load(await this.#html(url));
      const selector = categoryId === 'completed' ? '#main div.topbooks ul li' : '#newscontent .l ul li';
      return this.#parseRows($, selector, url, category[1]);
    });
  }

  async getDetail(id: string): Promise<ContentDetail> {
    return (await this.#getBookProjection(id)).detail;
  }

  async getChapters(id: string) {
    return (await this.#getBookProjection(id)).chapters;
  }

  async getContent(id: string, chapterId: string) {
    const bookUrl = decodeBookId(id);
    const chapterUrl = decodeChapterId(chapterId, bookUrl);
    const $ = cheerio.load(await this.#html(chapterUrl));
    const content = $('#content').first();
    if (content.length === 0) throw new Error('Chapter content is missing.');
    let html = content.html() ?? '';
    html = html.replace(/<script[\s\S]*?<\/script>/giu, '');
    const paragraphs: string[] = [];
    for (const fragment of html.split(/<br\s*\/?>|<\/?p[^>]*>/giu)) {
      let line = clean(cheerio.load(`<div>${fragment}</div>`)('div').text());
      if (line === null) continue;
      line = line.replace(/[（(][^)）]*飞速小说网[^)）]*[)）]/giu, '')
        .replace(/飞速小说网\s*www[\s/／．.]*feisuxs\.com/giu, '')
        .replace(/chaptererror\s*\(\s*\)\s*;?/giu, '')
        .replace(/(?:本章未完|加入书签|章节报错|请收藏|最快更新|天才一秒记住|35中文网|35ge\.info)/giu, '')
        .trim();
      if (line !== '') paragraphs.push(line);
    }
    return Object.freeze({
      chapterId, contentKind: 'novel' as const, title: clean($('h1').first().text()), updatedAt: null,
      text: paragraphs.join('\n\n'), pages: Object.freeze([]),
    });
  }

  async resource(request: Record<string, unknown>) {
    if (request.kind !== 'image' || typeof request.url !== 'string' || typeof request.referer !== 'string') return emptyResource(400);
    const url = new URL(request.url); const referer = new URL(request.referer);
    if (url.origin !== origin || referer.origin !== origin) return emptyResource(400);
    const response = await this.context.http.fetch(url, { headers: { accept: 'image/*', referer: referer.toString() } });
    const body = new Uint8Array(await response.arrayBuffer());
    const type = response.headers.get('content-type');
    return Object.freeze({ status: response.status, headers: type === null ? {} : { 'content-type': type }, body });
  }

  #parseRows($: cheerio.CheerioAPI, selector: string, pageUrl: URL, fallbackCategory: string | null): readonly ContentSummary[] {
    const seen = new Set<string>(); const items: ContentSummary[] = [];
    for (const element of $(selector).toArray()) {
      const root = $(element);
      const link = root.find('.s2 a[href], a[href*="/xs/"]').first();
      const href = link.attr('href'); const title = clean(link.text());
      if (href === undefined || title === null) continue;
      const url = new URL(href, pageUrl);
      if (!isBookUrl(url) || seen.has(bookIdentity(url))) continue;
      seen.add(bookIdentity(url));
      const category = stripBrackets(clean(root.find('.s1').first().text())) ?? fallbackCategory;
      const latestLink = root.find('.s3 a[href]').first();
      const latestHref = latestLink.attr('href');
      items.push(summary({
        url, title, author: clean(root.find('.s4, .s5').last().text()), coverUrl: null, description: null,
        status: parseStatus(clean(root.find('.s7').first().text())), updatedAt: null,
        latestTitle: clean(latestLink.text()), latestUrl: latestHref === undefined ? null : new URL(latestHref, pageUrl),
        categories: category === null ? [] : [category],
      }));
    }
    return Object.freeze(items);
  }

  async #getBookProjection(id: string): Promise<BookProjection> {
    const bookUrl = decodeBookId(id);
    return this.#bookCache.get(`book:${bookIdentity(bookUrl)}`, async () => {
      const $ = cheerio.load(await this.#html(bookUrl));
      const title = meta($, 'og:novel:book_name') ?? clean($('#info h1').first().text());
      if (title === null) throw new Error('Detail title is missing.');
      const category = meta($, 'og:novel:category');
      const latestTitle = meta($, 'og:novel:latest_chapter_name');
      const latestRaw = meta($, 'og:novel:latest_chapter_url');
      const latestUrl = latestRaw === null ? null : new URL(latestRaw, bookUrl);
      const updatedAt = meta($, 'og:novel:update_time');
      const coverRaw = meta($, 'og:image');
      const detail = Object.freeze({
        ...summary({
          url: bookUrl,
          title,
          author: meta($, 'og:novel:author'),
          coverUrl: coverRaw === null ? null : this.#proxyImage(new URL(coverRaw, bookUrl), bookUrl),
          description: normalizeIntro(clean($('#intro').first().text()) ?? meta($, 'og:description')),
          status: parseStatus(meta($, 'og:novel:status')),
          updatedAt,
          latestTitle,
          latestUrl,
          categories: category === null ? [] : [category],
        }),
        aliases: Object.freeze([]),
        catalogUrl: bookUrl.toString(),
      });
      const headings = $('#list dl dt').toArray();
      const bodyHeading = headings.find((element) => /正文/u.test($(element).text()));
      if (bodyHeading === undefined) throw new Error('Catalog body section is missing.');
      const seen = new Set<string>();
      const chapters: Array<Readonly<Record<string, unknown>>> = [];
      $(bodyHeading).nextAll('dd').find('a[href]').each((_, element) => {
        const href = $(element).attr('href');
        const chapterTitle = clean($(element).text());
        if (href === undefined || chapterTitle === null) return;
        const chapterUrl = new URL(href, bookUrl);
        if (!sameBookChapter(chapterUrl, bookUrl) || seen.has(chapterUrl.pathname)) return;
        seen.add(chapterUrl.pathname);
        chapters.push(Object.freeze({
          id: encodeChapterId(chapterUrl), title: chapterTitle, order: chapters.length, url: chapterUrl.toString(),
          volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]),
        }));
      });
      if (chapters.length === 0) throw new Error('Catalog is empty.');
      if (chapters.length > 5000) throw new Error('Catalog exceeds the Runtime chapter limit.');
      return Object.freeze({ detail, chapters: Object.freeze({ items: Object.freeze(chapters) }) });
    });
  }

  async #html(url: URL): Promise<string> {
    const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-CN,zh;q=0.9', referer: `${origin}/` } });
    const body = await response.text();
    if (!response.ok || /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body)) throw new Error('Source page is unavailable.');
    return body;
  }
  #proxyImage(url: URL, referer: URL): string | null { return url.origin === origin ? this.context.resource.proxy({ kind: 'image', url: url.toString(), referer: referer.toString() }) : null; }
}

function summary(input: { readonly url: URL; readonly title: string; readonly author: string | null; readonly coverUrl: string | null; readonly description: string | null; readonly status: ContentSummary['status']; readonly updatedAt: string | null; readonly latestTitle: string | null; readonly latestUrl: URL | null; readonly categories: readonly string[] }): ContentSummary {
  const latestValid = input.latestUrl !== null && sameBookChapter(input.latestUrl, input.url);
  return Object.freeze({
    id: encodeBookId(input.url), title: input.title, contentKind: 'novel', author: input.author, url: input.url.toString(),
    coverUrl: input.coverUrl, description: input.description, language: 'zh-CN', status: input.status, access: 'free',
    wordCount: null, chapterCount: null, publishedAt: null, updatedAt: input.updatedAt,
    latestChapter: input.latestTitle === null ? null : Object.freeze({ id: latestValid ? encodeChapterId(input.latestUrl!) : null, title: input.latestTitle, url: latestValid ? input.latestUrl!.toString() : null, updatedAt: input.updatedAt }),
    categories: Object.freeze(input.categories), tags: Object.freeze([]), attributes: Object.freeze([]),
  });
}
function meta($: cheerio.CheerioAPI, property: string): string | null { return clean($(`meta[property="${property}"]`).first().attr('content')); }
function encodeBookId(url: URL): string { return `book:${token(bookIdentity(url))}`; }
function encodeChapterId(url: URL): string { return `chapter:${token(url.pathname)}`; }
function token(value: string): string { return Buffer.from(value, 'utf8').toString('base64url'); }
function cacheKey(scope: string, value: string): string { return `${scope}:${createHash('sha256').update(value).digest('base64url')}`; }
function decodeBookId(id: string): URL {
  const value = /^book:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Content ID is invalid.');
  const identity = Buffer.from(value, 'base64url').toString('utf8');
  if (!/^\/\d+\/\d+\/$/u.test(identity)) throw new Error('Content ID is invalid.');
  return new URL(`/xs${identity}`, origin);
}
function decodeChapterId(id: string, bookUrl: URL): URL {
  const value = /^chapter:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Chapter ID is invalid.');
  const url = new URL(Buffer.from(value, 'base64url').toString('utf8'), origin);
  if (!sameBookChapter(url, bookUrl)) throw new Error('Chapter ID is invalid.');
  return url;
}
function isBookUrl(url: URL): boolean { return url.origin === origin && /^\/(?:xs\/)?\d+\/\d+\/?$/u.test(url.pathname); }
function bookIdentity(url: URL): string { const match = /^\/(?:xs\/)?(\d+\/\d+)\/?$/u.exec(url.pathname); return match?.[1] === undefined ? '' : `/${match[1]}/`; }
function sameBookChapter(chapter: URL, book: URL): boolean { const key = bookIdentity(book); return key !== '' && chapter.origin === origin && new RegExp(`^/xs?${key.replaceAll('/', '\\/')}\\d+\\.html$`, 'u').test(chapter.pathname); }
function normalizeIntro(value: string | null): string | null { return value === null ? null : clean(value.replace(/\\[nr]/gu, '').replace(/[\r\n\u2028\u2029]+/gu, ' ')); }
function clean(value: string | undefined): string | null { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function stripBrackets(value: string | null): string | null { return value === null ? null : clean(value.replace(/^\[|\]$/gu, '')); }
function parseStatus(value: string | null): ContentSummary['status'] { if (value === null) return 'unknown'; if (/(?:全本|完本|完结)/u.test(value)) return 'completed'; if (/连载/u.test(value)) return 'ongoing'; if (/(?:停更|暂停)/u.test(value)) return 'hiatus'; return 'unknown'; }
function emptyResource(status: number) { return Object.freeze({ status, headers: Object.freeze({}), body: new Uint8Array() }); }
