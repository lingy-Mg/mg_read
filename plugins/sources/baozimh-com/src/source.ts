/**
 * Baozimh manga parser and HTTP/resource boundary.
 * Requests start from the current public entry; redirects and parsed resources retain their complete URLs without an origin or protocol gate.
 * Detail and catalog share one bounded book-page projection; image bytes are fetched and streamed only by Runtime.
 * HTML, manga pages, credentials, signed media URLs, and user input are never cached or logged.
 */
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import * as cheerio from 'cheerio/slim';

import type { ContentDetail, ContentSummary, MgReadPluginContext } from './contracts.js';
import { ProjectionCache } from './projection-cache.js';

const entryUrl = 'https://cn.bzmgcn.com';
export const categories = Object.freeze([
  ['china', '國漫', '/classify?type=all&region=cn&state=all&filter=*'],
  ['japan', '日本', '/classify?type=all&region=jp&state=all&filter=*'],
  ['korea', '韓國', '/classify?type=all&region=kr&state=all&filter=*'],
  ['romance', '戀愛', '/classify?type=lianai&region=all&state=all&filter=*'],
  ['action', '熱血', '/classify?type=rexie&region=all&state=all&filter=*'],
  ['fantasy', '玄幻', '/classify?type=xuanhuan&region=all&state=all&filter=*'],
  ['adventure', '冒險', '/classify?type=mouxian&region=all&state=all&filter=*'],
  ['comedy', '搞笑', '/classify?type=gaoxiao&region=all&state=all&filter=*'],
] as const);

export const projectionCachePolicy = Object.freeze({
  lists: Object.freeze({ capacity: 32, freshTtlMs: 5 * 60_000, staleTtlMs: 30 * 60_000 }),
  books: Object.freeze({ capacity: 64, freshTtlMs: 10 * 60_000, staleTtlMs: 60 * 60_000 }),
});

type ChaptersProjection = Readonly<{ readonly items: readonly Readonly<Record<string, unknown>>[] }>;
interface BookProjection { readonly detail: ContentDetail; readonly chapters: ChaptersProjection }
export interface BaozimhSourceOptions { readonly now?: () => number }

export class BaozimhSource {
  readonly #listCache: ProjectionCache<readonly ContentSummary[]>;
  readonly #bookCache: ProjectionCache<BookProjection>;

  constructor(private readonly context: MgReadPluginContext, options: BaozimhSourceOptions = {}) {
    this.#listCache = new ProjectionCache(projectionCachePolicy.lists, options.now);
    this.#bookCache = new ProjectionCache(projectionCachePolicy.books, options.now);
  }

  async search(query: string): Promise<readonly ContentSummary[]> {
    const url = new URL('/search', entryUrl); url.searchParams.set('q', query);
    return this.#listCache.get(cacheKey('search', query), async () => { const response = await this.#html(url); return this.parseCards(response.body, response.url); });
  }

  async discover(categoryId: string): Promise<readonly ContentSummary[]> {
    const category = categories.find(([id]) => id === categoryId);
    if (category === undefined) throw new Error('Unknown category.');
    const url = new URL(category[2], entryUrl);
    return this.#listCache.get(`discover:${categoryId}`, async () => { const response = await this.#html(url); return this.parseCards(response.body, response.url); });
  }

  parseCards(html: string, pageUrl: URL): readonly ContentSummary[] {
    const $ = cheerio.load(html); const seen = new Set<string>(); const items: ContentSummary[] = [];
    $('div.comics-card').each((_, element) => {
      const card = $(element); const poster = card.find('a.comics-card__poster[href]').first();
      const href = poster.attr('href'); const title = clean(poster.attr('title')) ?? clean(card.find('h3').first().text());
      if (href === undefined || title === null) return;
      const url = new URL(href, pageUrl); if (!isBookUrl(url) || seen.has(url.toString())) return; seen.add(url.toString());
      const image = poster.find('amp-img[src]').first().attr('src');
      const tags = unique(card.find('.tab').toArray().map((node) => $(node).text()));
      items.push(summary({ id: encodeBookId(url), url, title, author: clean(card.find('small.tags').first().text()),
        coverUrl: image === undefined ? null : this.#proxyImage(new URL(decodeEntities(image), pageUrl), pageUrl),
        description: null, status: 'unknown', latest: null, categories: tags }));
    });
    return Object.freeze(items);
  }

  async getDetail(id: string): Promise<ContentDetail> {
    return (await this.#getBookProjection(id)).detail;
  }

  async getChapters(id: string) {
    return (await this.#getBookProjection(id)).chapters;
  }

  async getContent(id: string, chapterId: string) {
    decodeBookId(id); const chapterUrl = decodeChapterId(chapterId, id); const response = await this.#html(chapterUrl); const $ = cheerio.load(response.body);
    const seen = new Set<string>(); const pages: Array<Readonly<Record<string, unknown>>> = [];
    $('amp-img.comic-contain__item[src]').each((_, element) => {
      const image = $(element); const raw = image.attr('src'); if (raw === undefined) return;
      const url = new URL(decodeEntities(raw), response.url);
      if (/default_cover/iu.test(url.pathname) || seen.has(url.toString())) return; seen.add(url.toString());
      const index = pages.length;
      pages.push(Object.freeze({ id: `page:${index + 1}`, index, url: this.#proxyImage(url, response.url), mimeType: imageMime(url),
        width: dimension(image.attr('width')), height: dimension(image.attr('height')) }));
    });
    if (pages.length === 0) throw new Error('Chapter images are missing.');
    return Object.freeze({ chapterId, contentKind: 'manga' as const, title: clean($('.header .text .title').first().text()) ?? clean($('title').text()),
      updatedAt: null, text: null, pages: Object.freeze(pages) });
  }

  async #getBookProjection(id: string): Promise<BookProjection> {
    const requestedUrl = decodeBookId(id);
    return this.#bookCache.get(`book:${requestedUrl.toString()}`, async () => {
      const response = await this.#html(requestedUrl); const finalUrl = response.url;
      const $ = cheerio.load(response.body);
      const title = meta($, 'og:novel:book_name') ?? clean($('title').text())?.replace(/^\P{L}+/u, '').replace(/\s+-\s+包子漫畫.*$/u, '') ?? null;
      if (title === null) throw new Error('Detail title is missing.');
      const categories = splitTags(meta($, 'og:novel:category'));
      const coverRaw = meta($, 'og:image'); const latestTitle = meta($, 'og:novel:latest_chapter_name'); const latestRaw = meta($, 'og:novel:latest_chapter_url');
      const latestUrl = latestRaw === null ? null : new URL(latestRaw, finalUrl);
      const detail = Object.freeze({
        ...summary({ id, url: finalUrl, title, author: meta($, 'og:novel:author'), coverUrl: coverRaw === null ? null : this.#proxyImage(new URL(coverRaw, finalUrl), finalUrl),
          description: meta($, 'og:description') ?? clean($('.comics-detail__desc').first().text()), status: parseStatus(meta($, 'og:novel:status')),
          latest: latestTitle === null ? null : { title: latestTitle, url: latestUrl }, categories }),
        aliases: Object.freeze([]), catalogUrl: finalUrl.toString(),
      });
      const chapters: Array<Readonly<Record<string, unknown>>> = []; const seen = new Set<string>();
      $('#chapter-items a.comics-chapters__item[href]').each((_, element) => {
        const link = $(element); const href = link.attr('href'); const chapterTitle = clean(link.find('span').first().text()) ?? clean(link.text());
        if (href === undefined || chapterTitle === null) return;
        const direct = directChapterUrl(new URL(decodeEntities(href), finalUrl));
        if (direct === null || seen.has(direct.toString())) return; seen.add(direct.toString());
        chapters.push(Object.freeze({ id: encodeChapterId(id, direct), title: chapterTitle, order: chapters.length, url: direct.toString(), volumeTitle: null,
          wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) }));
      });
      if (chapters.length === 0) throw new Error('Catalog is empty.');
      if (chapters.length > 5000) throw new Error('Catalog exceeds the Runtime chapter limit.');
      return Object.freeze({ detail, chapters: Object.freeze({ items: Object.freeze(chapters) }) });
    });
  }

  async #html(url: URL): Promise<{ readonly body: string; readonly url: URL }> {
    const response = await this.context.http.fetch(url, { redirect: 'follow', headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-TW,zh;q=0.9', referer: new URL('/', url).toString() } });
    const body = await response.text(); if (!response.ok || isChallenge(body)) throw new Error('Source page is unavailable.');
    return Object.freeze({ body, url: new URL(response.url || url.toString()) });
  }
  #proxyImage(url: URL, referer: URL): string { return this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/avif,image/webp,image/*,*/*;q=0.8', Referer: referer.toString() } }); }
}

function summary(input: { readonly id: string; readonly url: URL; readonly title: string; readonly author: string | null; readonly coverUrl: string | null;
  readonly description: string | null; readonly status: ContentSummary['status']; readonly latest: { readonly title: string; readonly url: URL | null } | null;
  readonly categories: readonly string[] }): ContentSummary {
  return Object.freeze({ id: input.id, title: input.title, contentKind: 'manga', author: input.author, url: input.url.toString(), coverUrl: input.coverUrl,
    description: input.description, language: 'zh-TW', status: input.status, access: 'free', wordCount: null, chapterCount: null, publishedAt: null,
    updatedAt: null, latestChapter: input.latest === null ? null : Object.freeze({ id: input.latest.url === null ? null : encodeChapterId(input.id, input.latest.url),
      title: input.latest.title, url: input.latest.url?.toString() ?? null, updatedAt: null }), categories: Object.freeze(input.categories), tags: Object.freeze(input.categories), attributes: Object.freeze([]) });
}
function meta($: cheerio.CheerioAPI, name: string): string | null { return clean($(`meta[name="${name}"],meta[property="${name}"]`).first().attr('content')); }
function encodeBookId(url: URL): string { return `comic:${token(url.toString())}`; }
function decodeBookId(id: string): URL { const value = /^comic:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (value === undefined) throw new Error('Content ID is invalid.'); const url = new URL(Buffer.from(value, 'base64url').toString('utf8'), entryUrl); if (!isBookUrl(url)) throw new Error('Content ID is invalid.'); return url; }
function encodeChapterId(bookId: string, url: URL): string { return `chapter:${token(bookId)}:${token(url.toString())}`; }
function decodeChapterId(id: string, bookId: string): URL { const match = /^chapter:([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$/u.exec(id); if (match?.[1] === undefined || match[2] === undefined || Buffer.from(match[1], 'base64url').toString('utf8') !== bookId) throw new Error('Chapter ID is invalid.'); const url = new URL(Buffer.from(match[2], 'base64url').toString('utf8'), entryUrl); if (!isChapterUrl(url)) throw new Error('Chapter ID is invalid.'); return url; }
function token(value: string): string { return Buffer.from(value, 'utf8').toString('base64url'); }
function cacheKey(scope: string, value: string): string { return `${scope}:${createHash('sha256').update(value).digest('base64url')}`; }
function isBookUrl(url: URL): boolean { return /^\/comic\/[A-Za-z0-9_-]+\/?$/u.test(url.pathname); }
function isChapterUrl(url: URL): boolean { return /^\/comic\/chapter\/[A-Za-z0-9_-]+\/\d+_\d+\.html$/u.test(url.pathname); }
function directChapterUrl(url: URL): URL | null { if (url.pathname !== '/user/page_direct') return isChapterUrl(url) ? url : null; const comicId = url.searchParams.get('comic_id'); const section = url.searchParams.get('section_slot'); const chapter = url.searchParams.get('chapter_slot'); if (comicId === null || !/^[A-Za-z0-9_-]+$/u.test(comicId) || !/^\d+$/u.test(section ?? '') || !/^\d+$/u.test(chapter ?? '')) return null; return new URL(`/comic/chapter/${comicId}/${section}_${chapter}.html`, url.origin); }
function imageMime(url: URL): string | null { const ext = /\.([A-Za-z0-9]+)$/u.exec(url.pathname)?.[1]?.toLowerCase(); return ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : null; }
function dimension(value: string | undefined): number | null { const number = Number(value); return Number.isSafeInteger(number) && number > 0 ? number : null; }
function splitTags(value: string | null): readonly string[] { return value === null ? Object.freeze([]) : unique(value.split(/[,，]/u)); }
function unique(values: readonly string[]): readonly string[] { return Object.freeze([...new Set(values.map((value) => value.replace(/\s+/gu, ' ').trim()).filter(Boolean))]); }
function decodeEntities(value: string): string { return value.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&#x27;', "'"); }
function clean(value: string | undefined): string | null { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function parseStatus(value: string | null): ContentSummary['status'] { if (value === null) return 'unknown'; if (/(?:完結|完本|已完結)/u.test(value)) return 'completed'; if (/(?:連載|更新中)/u.test(value)) return 'ongoing'; if (/(?:停更|暫停)/u.test(value)) return 'hiatus'; return 'unknown'; }
function isChallenge(body: string): boolean { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body); }
