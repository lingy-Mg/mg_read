/**
 * Cosplaytele source parser and network boundary.
 * Search/discovery/detail HTML is cached; gallery content and image bodies are never cached.
 */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';
import { PluginCache } from '@mgread/plugin-cache';

import type { ContentDetail, ContentSummary, MgReadPluginContext } from './contracts.js';

const origin = 'https://cosplaytele.com';
const listingPolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 10 * 60 * 1000, serveStaleWhileRevalidate: true });
const detailPolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const categories = Object.freeze([
  ['home', '首页', '/'], ['video', 'Video Cosplay', '/category/video-cosplayy/'],
  ['nude', 'Cosplay Nude', '/category/nude/'], ['ero', 'Cosplay Ero', '/category/cosplay-ero/'],
  ['cosplay', 'Cosplay', '/category/cosplay/'], ['day', '24 Hours', '/24-hours/'],
  ['three-day', '3 Day', '/3-day/'], ['week', '7 Day', '/7-day/'],
  ['best', 'Best Cosplayer', '/best-cosplayer/'],
] as const);

export class Xiezhenji2Source {
  readonly #cache: PluginCache;
  constructor(private readonly context: MgReadPluginContext) { this.#cache = new PluginCache(context.cacheDir); }

  async search(query: string, page: number): Promise<readonly ContentSummary[]> {
    const url = new URL(page === 1 ? '/' : `/page/${page}/`, origin);
    url.searchParams.set('s', query);
    return this.parseList(await this.#cachedHtml(url, listingPolicy), url);
  }

  async discover(categoryId: string, page: number): Promise<readonly ContentSummary[]> {
    const category = categories.find(([id]) => id === categoryId);
    if (category === undefined) throw new Error('Unknown category.');
    const base = new URL(category[2], origin);
    const url = page === 1 ? base : new URL(`${base.pathname.replace(/\/?$/u, '/') }page/${page}/`, origin);
    return this.parseList(await this.#cachedHtml(url, listingPolicy), url);
  }

  async getDetail(id: string): Promise<ContentDetail> {
    const url = decodeId(id);
    const html = await this.#cachedHtml(url, detailPolicy);
    const $ = cheerio.load(html);
    const title = text($('h1.entry-title').first().text()) ?? text($('meta[property="og:title"]').attr('content'));
    if (title === null) throw new Error('Detail title is missing.');
    const cleanTitle = title.replace(/\s*-\s*Cosplaytele\s*$/iu, '').trim();
    const description = text($('.entry-content blockquote').first().text())
      ?? text($('meta[name="description"]').attr('content'))
      ?? text($('meta[property="og:description"]').attr('content'));
    const rawCover = text($('meta[property="og:image"]').attr('content'))
      ?? text($('.entry-content .gallery a[href]').first().attr('href'))
      ?? text($('.entry-content .gallery img').first().attr('src'));
    const cover = rawCover === null ? null : this.#proxyImage(new URL(rawCover, url), url);
    const author = text($('.entry-content blockquote a[href*="/category/"]').first().text());
    const tags = unique($('.entry-category a').toArray().map((element) => $(element).text()));
    const photoCount = parseCount(`${cleanTitle} ${description ?? ''}`);
    return Object.freeze({ ...summary(id, cleanTitle, url, cover, description, author, tags), aliases: Object.freeze([]), catalogUrl: url.toString(), chapterCount: 1, attributes: photoCount === null ? Object.freeze([]) : Object.freeze([{ key: 'photos', label: '图片', value: String(photoCount) }]) });
  }

  getChapters(id: string) {
    const url = decodeId(id);
    return Object.freeze({ items: Object.freeze([{ id: `gallery:${token(url)}`, title: '全部图片', order: 0, url: url.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) }]) });
  }

  async getContent(id: string, chapterId: string) {
    const url = decodeId(id);
    if (chapterId !== `gallery:${token(url)}`) throw new Error('Chapter ID is invalid.');
    const firstHtml = await this.#html(url);
    const pageUrls = collectPageUrls(firstHtml, url).slice(0, 80);
    const pages = uniqueUrls([
      ...parseImages(firstHtml, url),
      ...(await Promise.all(pageUrls.map(async (pageUrl) => parseImages(await this.#html(pageUrl), pageUrl)))).flat(),
    ]).map((image, index) => Object.freeze({ id: `image:${index + 1}`, index, url: this.#proxyImage(image, url), mimeType: imageMime(image), width: null, height: null }));
    if (pages.length === 0) throw new Error('Gallery images are missing.');
    return Object.freeze({ chapterId, contentKind: 'manga' as const, title: '全部图片', updatedAt: null, text: null, pages: Object.freeze(pages) });
  }

  async resource(request: Record<string, unknown>) {
    if (request.kind !== 'image' || typeof request.url !== 'string' || typeof request.referer !== 'string') return emptyResource(400);
    const url = new URL(request.url); const referer = new URL(request.referer);
    if (url.protocol !== 'https:' || referer.origin !== origin || url.hostname !== 'cosplaytele.com') return emptyResource(400);
    const response = await this.context.http.fetch(url, { headers: { accept: 'image/*', referer: referer.toString() } });
    const body = new Uint8Array(await response.arrayBuffer());
    return Object.freeze({ status: response.status, headers: response.headers.get('content-type') === null ? {} : { 'content-type': response.headers.get('content-type')! }, body });
  }

  parseList(html: string, pageUrl: URL): readonly ContentSummary[] {
    const $ = cheerio.load(html); const seen = new Set<string>(); const items: ContentSummary[] = [];
    $('#post-list .post-item, main .post-item, .post-item').each((_, element) => {
      const root = $(element); const link = root.find('h5.post-title a[href], a.plain[href], a[href]').first();
      const href = link.attr('href'); const title = text(link.text()) ?? text(root.find('a[aria-label]').attr('aria-label'));
      if (href === undefined || title === null) return;
      const url = new URL(href, pageUrl);
      if (!isPostUrl(url) || seen.has(url.pathname)) return;
      seen.add(url.pathname);
      const rawCover = root.find('img.wp-post-image, img').first().attr('data-src') ?? root.find('img.wp-post-image, img').first().attr('src');
      const cover = rawCover === undefined ? null : this.#proxyImage(new URL(rawCover, pageUrl), pageUrl);
      items.push(summary(encodeId(url), title, url, cover, text(root.find('.from_the_blog_excerpt').text()), null, unique([root.find('.cat-label').text()])));
    });
    return Object.freeze(items);
  }

  async #cachedHtml(url: URL, policy: typeof listingPolicy | typeof detailPolicy): Promise<string> { return this.#cache.getOrFetchText(url, policy, () => this.#html(url)); }
  async #html(url: URL): Promise<string> {
    const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-CN,zh;q=0.9', referer: `${origin}/` } });
    const body = await response.text();
    if (!response.ok || isCloudflare(body)) {
      const browser = await this.context.browser.sessionV1.request({ version: 1, sessionKey: 'cosplaytele', url: url.toString(), method: 'GET', headers: { accept: 'text/html', referer: `${origin}/` }, body: null, interaction: 'allow', timeoutMs: 120_000, maxResponseBytes: 2 * 1024 * 1024 });
      if (browser.status >= 400 || isCloudflare(browser.body)) throw new Error('Browser verification is incomplete.');
      return browser.body;
    }
    return body;
  }
  #proxyImage(url: URL, referer: URL): string { return this.context.resource.proxy({ kind: 'image', url: url.toString(), referer: referer.toString() }); }
}

function summary(id: string, title: string, url: URL, coverUrl: string | null, description: string | null, author: string | null, tags: readonly string[]): ContentSummary { return Object.freeze({ id, title, contentKind: 'manga', author, url: url.toString(), coverUrl, description, language: null, status: 'unknown', access: 'free', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `gallery:${token(url)}`, title: '全部图片', url: url.toString(), updatedAt: null }, categories: tags, tags, attributes: Object.freeze([]) }); }
function encodeId(url: URL): string { return `post:${token(url)}`; }
function decodeId(id: string): URL { const match = /^post:([A-Za-z0-9_-]+)$/u.exec(id); if (match?.[1] === undefined) throw new Error('Content ID is invalid.'); const path = Buffer.from(match[1], 'base64url').toString('utf8'); const url = new URL(path, origin); if (!isPostUrl(url)) throw new Error('Content ID is invalid.'); return url; }
function token(url: URL): string { return Buffer.from(url.pathname, 'utf8').toString('base64url'); }
function isPostUrl(url: URL): boolean { return url.origin === origin && /^\/[^/?#]+\/?$/u.test(url.pathname) && !/^\/(?:category|tag|author|page|wp-json|wp-content)\//u.test(url.pathname); }
function text(value: string | undefined): string | null { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function unique(values: readonly string[]): readonly string[] { return Object.freeze([...new Set(values.map((value) => value.replace(/\s+/gu, ' ').trim()).filter(Boolean))]); }
function uniqueUrls(values: readonly URL[]): readonly URL[] { const seen = new Set<string>(); return values.filter((url) => { const key = `${url.origin}${url.pathname}`; if (seen.has(key)) return false; seen.add(key); return true; }); }
function parseCount(value: string): number | null { const match = /(\d+)\s+photos?/iu.exec(value); const count = Number(match?.[1]); return Number.isSafeInteger(count) && count >= 0 ? count : null; }
function collectPageUrls(html: string, base: URL): readonly URL[] { const $ = cheerio.load(html); return uniqueUrls($('.entry-content a[href], .page-links a[href], .nav-links a[href]').toArray().flatMap((element) => { const href = $(element).attr('href'); if (href === undefined) return []; const url = new URL(href, base); return url.origin === origin && /\/(?:page\/)?\d+\/?$/u.test(url.pathname) ? [url] : []; })); }
function parseImages(html: string, base: URL): readonly URL[] { const $ = cheerio.load(html); const links = $('.entry-content .gallery a[href]').toArray().flatMap((element) => { const href = $(element).attr('href'); return href === undefined ? [] : [new URL(href, base)]; }); const images = links.length === 0 ? $('.entry-content .gallery img, .entry-content img.attachment-full').toArray().flatMap((element) => { const raw = $(element).attr('data-src') ?? $(element).attr('data-lazy-src') ?? $(element).attr('src'); return raw === undefined ? [] : [new URL(raw, base)]; }) : links; return uniqueUrls(images.filter((url) => url.hostname === 'cosplaytele.com' && /\/wp-content\/uploads\//u.test(url.pathname) && /\.(?:jpe?g|png|webp|gif)$/iu.test(url.pathname) && !url.pathname.includes('cropped-icon-'))); }
function imageMime(url: URL): string | null { const extension = /\.([A-Za-z0-9]+)$/u.exec(url.pathname)?.[1]?.toLowerCase(); return extension === 'jpg' || extension === 'jpeg' ? 'image/jpeg' : extension === 'png' ? 'image/png' : extension === 'webp' ? 'image/webp' : extension === 'gif' ? 'image/gif' : null; }
function isCloudflare(body: string): boolean { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser)/iu.test(body); }
function emptyResource(status: number) { return Object.freeze({ status, headers: Object.freeze({}), body: new Uint8Array() }); }
