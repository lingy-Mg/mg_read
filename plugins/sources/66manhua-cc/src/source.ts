/**
 * 66manhua.cc public HTML parser. It reads only site pages, returns opaque IDs,
 * and proxies the verified image hosts; it never persists HTML or image bodies.
 */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';

export interface Context {
  readonly cacheDir: string;
  readonly http: { fetch(input: string | URL, init?: RequestInit): Promise<Response> };
  readonly resource: { proxy(request: Record<string, unknown>): string };
  readonly log: { debug(value: string): void; info(value: string): void; warn(value: string): void; error(value: string): void };
}

export interface Summary {
  readonly id: string; readonly title: string; readonly contentKind: 'manga'; readonly author: null;
  readonly url: string; readonly coverUrl: string | null; readonly description: string | null; readonly language: 'zh-CN';
  readonly status: 'unknown'; readonly access: 'unknown'; readonly wordCount: null; readonly chapterCount: number | null;
  readonly publishedAt: null; readonly updatedAt: null;
  readonly latestChapter: { readonly id: null; readonly title: string; readonly url: null; readonly updatedAt: null } | null;
  readonly categories: readonly string[]; readonly tags: readonly string[]; readonly attributes: readonly never[];
}

const origin = 'https://66manhua.cc';
const imageOrigins = new Set([origin, 'https://mh.aikanhanman.top']);

export class ManhuaSource {
  constructor(private readonly context: Context) {}

  async search(query: string): Promise<readonly Summary[]> {
    const url = new URL('/index.php/search', origin);
    url.searchParams.set('key', query);
    return this.parseList(await this.#html(url), url);
  }

  async discover(): Promise<readonly Summary[]> { return this.parseList(await this.#html(new URL('/', origin)), new URL('/', origin)); }

  parseList(html: string, base: URL): readonly Summary[] {
    const $ = cheerio.load(html); const values: Summary[] = []; const seen = new Set<string>();
    $('.common-comic-item, .in-comic--type-a, .in-comic--type-b').each((_, element) => {
      const root = $(element); const link = root.find('a[href*="/index.php/comic/"]').first();
      const href = link.attr('href'); const title = clean(root.find('.comic__title a, .comic-name a').first().text()) ?? clean(link.attr('title'));
      if (href === undefined || title === null) return;
      const url = new URL(href, base); if (!isComic(url) || seen.has(url.pathname)) return; seen.add(url.pathname);
      const image = root.find('img').first(); const rawCover = image.attr('data-original') ?? image.attr('data-src') ?? image.attr('src');
      values.push(summary(url, title, rawCover === undefined ? null : this.#proxyImage(new URL(rawCover, base), base), clean(root.find('.comic__feature, .feature').first().text())));
    });
    return Object.freeze(values);
  }

  async detail(id: string) {
    const url = decodeComic(id); const html = await this.#html(url); const $ = cheerio.load(html);
    const title = clean($('.de-info__box h1, h1.comic-title, .comic-detail h1').first().text()) ?? clean($('meta[property="og:title"]').attr('content'));
    if (title === null) throw new Error('Detail title is missing.');
    const rawCover = $('.de-info__cover img, .comic-cover img, .de-info__box img').first().attr('data-original') ?? $('.de-info__cover img, .comic-cover img, .de-info__box img').first().attr('src') ?? $('meta[property="og:image"]').attr('content');
    const description = clean($('.de-info__desc, .comic-detail__desc, .de-info__intro').first().text()) ?? clean($('meta[name="description"]').attr('content'));
    const chapterCount = $('.j-chapter-link[href*="/index.php/chapter/"]').length || null;
    return Object.freeze({ ...summary(url, title, rawCover === undefined ? null : this.#proxyImage(new URL(rawCover, url), url), description), chapterCount, aliases: Object.freeze([]), catalogUrl: url.toString() });
  }

  async chapters(id: string) {
    const comic = decodeComic(id); const $ = cheerio.load(await this.#html(comic)); const items: object[] = []; const seen = new Set<string>();
    $('.j-chapter-link[href*="/index.php/chapter/"]').each((_, element) => {
      const link = $(element); const href = link.attr('href'); const title = clean(link.text());
      if (href === undefined || title === null) return;
      const url = new URL(href, comic); if (!isChapter(url) || seen.has(url.pathname)) return; seen.add(url.pathname);
      const locked = hasAccessMarker(link.closest('.chapter__item'));
      items.push(Object.freeze({ id: encodeChapter(url), title, order: items.length, url: url.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: locked, attributes: Object.freeze([]) }));
    });
    if (items.length === 0) throw new Error('Catalog is empty.');
    return Object.freeze({ items: Object.freeze(items) });
  }

  async content(id: string, chapterId: string) {
    decodeComic(id); const chapter = decodeChapter(chapterId); const html = await this.#html(chapter); const $ = cheerio.load(html);
    const reader = $('.rd-article-wr').first();
    if (reader.length === 0 || hasAccessMarker(reader)) throw new Error('Chapter requires public access.');
    const seen = new Set<string>(); const pages: object[] = [];
    reader.find('.rd-article__pic .lazy-read[data-original], .rd-article__pic img[data-original]').each((index, element) => {
      const raw = $(element).attr('data-original'); if (raw === undefined) return;
      const url = new URL(raw, chapter); if (!isImage(url) || seen.has(url.toString())) return; seen.add(url.toString());
      pages.push(Object.freeze({ id: `image:${index + 1}`, index: pages.length, url: this.#proxyImage(url, chapter), mimeType: imageMime(url), width: null, height: null }));
    });
    if (pages.length === 0) throw new Error('Chapter images are unavailable or protected.');
    return Object.freeze({ chapterId, contentKind: 'manga' as const, title: null, updatedAt: null, text: null, pages: Object.freeze(pages) });
  }

  async resource(request: Record<string, unknown>) {
    if (request.kind !== 'image' || typeof request.url !== 'string' || typeof request.referer !== 'string') return empty(400);
    let url: URL; let referer: URL;
    try { url = new URL(request.url); referer = new URL(request.referer); } catch { return empty(400); }
    if (!isImage(url) || !isSite(referer)) return empty(400);
    const response = await this.context.http.fetch(url, { headers: { accept: 'image/*', referer: referer.toString() } });
    const bytes = Number(response.headers.get('content-length')); if (Number.isFinite(bytes) && bytes > 8 * 1024 * 1024) return empty(413);
    const body = new Uint8Array(await response.arrayBuffer()); if (body.byteLength > 8 * 1024 * 1024) return empty(413);
    const type = response.headers.get('content-type'); return Object.freeze({ status: response.status, headers: type === null ? Object.freeze({}) : Object.freeze({ 'content-type': type }), body });
  }

  async #html(url: URL): Promise<string> {
    if (!isSite(url)) throw new Error('Source URL is invalid.');
    const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', referer: `${origin}/` } });
    if (!response.ok) throw new Error('Public page is unavailable.');
    return response.text();
  }

  #proxyImage(url: URL, referer: URL): string { if (!isImage(url) || !isSite(referer)) throw new Error('Image URL is invalid.'); return this.context.resource.proxy({ kind: 'image', url: url.toString(), referer: referer.toString() }); }
}

function summary(url: URL, title: string, coverUrl: string | null, description: string | null): Summary { return Object.freeze({ id: encodeComic(url), title, contentKind: 'manga', author: null, url: url.toString(), coverUrl, description, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: Object.freeze([]), tags: Object.freeze([]), attributes: Object.freeze([]) }); }
function token(url: URL): string { return Buffer.from(url.pathname, 'utf8').toString('base64url'); }
function encodeComic(url: URL): string { return `comic:${token(url)}`; }
function encodeChapter(url: URL): string { return `chapter:${token(url)}`; }
function decode(id: string, prefix: 'comic' | 'chapter'): URL { const match = new RegExp(`^${prefix}:([A-Za-z0-9_-]+)$`, 'u').exec(id); if (match?.[1] === undefined) throw new Error('Opaque ID is invalid.'); const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin); if (prefix === 'comic' ? !isComic(url) : !isChapter(url)) throw new Error('Opaque ID is invalid.'); return url; }
function decodeComic(id: string): URL { return decode(id, 'comic'); }
function decodeChapter(id: string): URL { return decode(id, 'chapter'); }
function isSite(url: URL): boolean { return url.origin === origin && url.protocol === 'https:'; }
function isComic(url: URL): boolean { return isSite(url) && /^\/index\.php\/comic\/[^/?#]+\/?$/u.test(url.pathname); }
function isChapter(url: URL): boolean { return isSite(url) && /^\/index\.php\/chapter\/\d+\/?$/u.test(url.pathname); }
function isImage(url: URL): boolean { return url.protocol === 'https:' && imageOrigins.has(url.origin) && /\.(?:jpe?g|png|webp|gif)(?:$|\?)/iu.test(url.pathname + url.search); }
function imageMime(url: URL): string | null { const ext = /\.([a-z]+)(?:$|\?)/iu.exec(url.pathname + url.search)?.[1]?.toLowerCase(); return ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : null; }
function clean(value: string | undefined): string | null { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function hasAccessMarker(root: cheerio.Cheerio<any>): boolean { return root.is('[class*="vip" i], [class*="pay" i], [class*="lock" i]') || root.find('[class*="vip" i], [class*="pay" i], [class*="lock" i]').length > 0; }
function empty(status: number) { return Object.freeze({ status, headers: Object.freeze({}), body: new Uint8Array() }); }
