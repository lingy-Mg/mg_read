/**
 * xx.knit.bid parser and browser-session boundary.
 *
 * Cloudflare-protected HTML is read through one Runtime-owned WebView page;
 * display HTML is cached; each article pagination page is exposed as one
 * catalog chapter so opening one chapter does not fetch the whole gallery.
 */
import { contentLimits } from './content-limits.js';
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';
import { PluginCache } from '@mgread/plugin-cache';
const origin = 'https://xx.knit.bid';
const browserTimeoutMs = 120_000;
const listingPolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 10 * 60 * 1000, serveStaleWhileRevalidate: true });
const detailPolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const categories = Object.freeze([['home', '首页', '/'], ['sexy', '性感美女', '/type/1/'], ['pure', '清纯美女', '/type/2/'], ['stockings', '丝袜美女', '/type/3/'], ['legs', '美腿美女', '/type/4/'], ['cosplay', 'Cosplay', '/type/6/'], ['ai', 'AI美女', '/type/10/'], ['new', '最新发布', '/sort/new/'], ['hot', '最受欢迎', '/sort/hot/'], ['daily', '今日热门', '/rankings/daily/'], ['weekly', '本周热门', '/rankings/weekly/'], ['monthly', '本月热门', '/rankings/monthly/']]);
export class XiezhenjiSource {
    context;
    #cache;
    #pagePromise;
    #readyPromise;
    #browserTail = Promise.resolve();
    constructor(context) {
        this.context = context;
        this.#cache = new PluginCache(context.cacheDir, { logger: context.log });
    }
    async search(query, page) { const url = new URL(page === 1 ? '/search/' : `/search/page/${page}/`, origin); url.searchParams.set('s', query); return this.parseList(await this.#cached(url, listingPolicy), url); }
    async discover(id, page) { const rule = categories.find(([key]) => key === id); if (rule === undefined)
        throw new Error('Unknown category.'); const base = new URL(rule[2], origin); const url = page === 1 ? base : new URL(`${base.pathname.replace(/\/?$/u, '/')}page/${page}/`, origin); return this.parseList(await this.#cached(url, listingPolicy), url); }
    parseList(html, base) { const $ = cheerio.load(html); const seen = new Set(); const values = []; $('article.excerpt,article.homepage-content-card').each((_, element) => { const root = $(element); const link = root.find('a.imgbox-link[href*="/article/"],a.homepage-content-card__media[href*="/article/"],a[href*="/article/"]').first(); const href = link.attr('href'); const title = clean(link.attr('title')) ?? clean(root.find('h2 a, h3 a, a[href*="/article/"]').first().text()); if (href === undefined || title === null)
        return; const url = new URL(href, base); if (!/^\/article\/\d+\/?$/u.test(url.pathname) || seen.has(url.pathname))
        return; seen.add(url.pathname); const image = root.find('img.imgbox-img,img[data-homepage-content-image]').first(); const raw = image.attr('data-original-src') ?? image.attr('data-src') ?? image.attr('src'); values.push(makeSummary(url, title, raw === undefined ? null : this.#proxy(new URL(raw, base), base), clean(root.find('.note, .excerpt-note, .post-excerpt').text()), unique([root.find('a.imgbox-a,.homepage-content-card__type').text()]))); }); return Object.freeze(values); }
    async detail(id) { const url = decodeId(id); const html = await this.#cached(url, detailPolicy); const $ = cheerio.load(html); const title = clean($('h1.focusbox-title').first().text()) ?? clean($('meta[property="og:title"]').attr('content')); if (title === null)
        throw new Error('Detail title is missing.'); const description = clean($('meta[name="description"]').attr('content')); const rawCover = clean($('meta[property="og:image"]').attr('content')); const tags = unique($('.article-tags a').toArray().map((element) => $(element).text())); const count = parseImageCount(html, description); const total = parseTotalPages(html); return Object.freeze({ ...makeSummary(url, title.replace(/\s*-\s*爱妹子\s*$/u, ''), rawCover === null ? null : this.#proxy(new URL(rawCover, url), url), description, tags, total), aliases: Object.freeze([]), catalogUrl: url.toString(), author: tags[0] ?? null, attributes: count === null ? Object.freeze([]) : Object.freeze([{ key: 'images', label: '图片', value: String(count) }]) }); }
    async chapters(id) { const url = decodeId(id); const total = parseTotalPages(await this.#cached(url, detailPolicy)); return Object.freeze({ items: chapterItems(url, total) }); }
    async content(id, chapterId) { const base = decodeId(id); const page = parseChapterPage(base, chapterId); const url = galleryPageUrl(base, page); const html = await this.#cached(url, detailPolicy); const images = parseImages(html, url); if (images.length === 0)
        throw new Error('Gallery images are missing.'); return Object.freeze({ chapterId, contentKind: 'manga', title: `第${page}页`, updatedAt: null, text: null, pages: Object.freeze(images.map((image, index) => Object.freeze({ id: `image:${page}-${index + 1}`, index, url: this.#proxy(image, url), mimeType: mime(image), width: null, height: null }))) }); }
    async #cached(url, policy) { return this.#cache.getOrFetchText(url, policy, () => this.#html(url)); }
    #html(url) { const operation = this.#browserTail.then(() => this.#browserHtml(url)); this.#browserTail = operation.then(() => undefined, () => undefined); return operation; }
    async #browserHtml(url) { const page = await this.#page(); await this.#ready(page); let response = await page.fetch({ url: url.toString(), method: 'GET', headers: { accept: 'text/html,application/xhtml+xml' }, body: null, responseType: 'text', timeoutMs: browserTimeoutMs }); if (needsVerification(response.status, response.body)) {
        this.#readyPromise = undefined;
        await this.#verify(page);
        this.#readyPromise = Promise.resolve();
        response = await page.fetch({ url: url.toString(), method: 'GET', headers: { accept: 'text/html,application/xhtml+xml' }, body: null, responseType: 'text', timeoutMs: browserTimeoutMs });
    } if (needsVerification(response.status, response.body))
        this.#raiseAccessBlocked(); if (response.status < 200 || response.status >= 400 || typeof response.body !== 'string')
        throw new Error('Source request is unavailable.'); return response.body; }
    async #page() { if (this.#pagePromise !== undefined)
        return this.#pagePromise; const pending = this.context.webview.open({ visible: false, timeoutMs: browserTimeoutMs }); this.#pagePromise = pending; try {
        return await pending;
    }
    catch (error) {
        if (this.#pagePromise === pending)
            this.#pagePromise = undefined;
        throw error;
    } }
    async #ready(page) { if (this.#readyPromise !== undefined)
        return this.#readyPromise; const pending = this.#verify(page); this.#readyPromise = pending; try {
        await pending;
    }
    catch (error) {
        if (this.#readyPromise === pending)
            this.#readyPromise = undefined;
        throw error;
    } }
    async #verify(page) { await page.navigate(`${origin}/`, { timeoutMs: browserTimeoutMs }); let html = await page.getHtml({ timeoutMs: browserTimeoutMs }); if (!isCf(html))
        return; const hiddenDeadline = Date.now() + 30_000; while (Date.now() < hiddenDeadline) {
        await delay(1_000);
        html = await page.getHtml({ timeoutMs: browserTimeoutMs });
        if (!isCf(html))
            return;
    } await page.show({ timeoutMs: browserTimeoutMs }); const deadline = Date.now() + browserTimeoutMs; while (Date.now() < deadline) {
        await delay(1_000);
        html = await page.getHtml({ timeoutMs: browserTimeoutMs });
        if (!isCf(html)) {
            const current = new URL(await page.getUrl({ timeoutMs: browserTimeoutMs }));
            if (current.origin !== origin)
                throw new Error('Browser verification left the source origin.');
            await page.hide({ timeoutMs: browserTimeoutMs });
            return;
        }
    } this.#raiseAccessBlocked(); }
    #raiseAccessBlocked() { this.context.errors.raise({ code: 'source_access_blocked', message: '写真集访问需要完成浏览器验证后重试。', annotation: '请在来源页面完成安全验证，然后点击“刷新”。' }); }
    #proxy(url, referer) { if (url.origin !== origin || referer.origin !== origin)
        throw new Error('Image request is invalid.'); return this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } }); }
}
function makeSummary(url, title, coverUrl, description, tags, chapterCount = 1) { const latestPage = Math.max(1, chapterCount); return Object.freeze({ id: encodeId(url), title, contentKind: 'manga', author: null, url: url.toString(), coverUrl, description, language: null, status: 'unknown', access: 'free', wordCount: null, chapterCount, publishedAt: null, updatedAt: null, latestChapter: { id: chapterId(url, latestPage), title: `第${latestPage}页`, url: galleryPageUrl(url, latestPage).toString(), updatedAt: null }, categories: tags, tags, attributes: Object.freeze([]) }); }
function encodeId(url) { return `article:${token(url)}`; }
function token(url) { return Buffer.from(url.pathname, 'utf8').toString('base64url'); }
function decodeId(id) { const match = /^article:([A-Za-z0-9_-]+)$/u.exec(id); if (match?.[1] === undefined)
    throw new Error('Content ID is invalid.'); const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin); if (url.origin !== origin || !/^\/article\/\d+\/?$/u.test(url.pathname))
    throw new Error('Content ID is invalid.'); return url; }
function chapterId(url, page) { return `gallery:${token(url)}:${page}`; }
function galleryPageUrl(base, page) { return page === 1 ? base : new URL(`${base.pathname.replace(/\/?$/u, '/')}page/${page}/`, origin); }
function chapterItems(url, total) { return Object.freeze(Array.from({ length: total }, (_, index) => { const page = index + 1; return Object.freeze({ id: chapterId(url, page), title: `第${page}页`, order: index, url: galleryPageUrl(url, page).toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) }); })); }
function parseChapterPage(base, value) { const legacy = `gallery:${token(base)}`; if (value === legacy)
    return 1; const prefix = `${legacy}:`; const page = value.startsWith(prefix) ? Number(value.slice(prefix.length)) : NaN; if (!Number.isSafeInteger(page) || page < 1 || page > contentLimits.catalogItems)
    throw new Error('Chapter ID is invalid.'); return page; }
function clean(value) { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function unique(values) { return Object.freeze([...new Set(values.map((value) => value.replace(/\s+/gu, ' ').trim()).filter(Boolean))]); }
function parseTotalPages(html) { const declared = Number(/(?:["']?)(?:total_pages|totalPages)(?:["']?)\s*[:=]\s*["']?(\d+)/u.exec(html)?.[1]); const $ = cheerio.load(html); const linked = [...$('a').toArray().map((element) => clean($(element).text())), ...$('[data-page]').toArray().map((element) => $(element).attr('data-page'))].map((value) => Number(value)).filter((value) => Number.isSafeInteger(value) && value > 0 && value <= 80); const count = Math.max(1, Number.isSafeInteger(declared) ? declared : 1, ...linked); if (count > contentLimits.catalogItems)
    throw new Error(`Catalog has ${count} pages; maximum is ${contentLimits.catalogItems}.`); return count; }
function parseImageCount(html, intro) { const count = Number(/"numberOfItems"\s*:\s*(\d+)/u.exec(html)?.[1] ?? /收录\s*(\d+)\s*P/iu.exec(intro ?? '')?.[1]); return Number.isSafeInteger(count) && count >= 0 ? count : null; }
function parseImages(html, base) { const $ = cheerio.load(html); return uniqueUrls($('#image-gallery .image-container img, article.article-content img').toArray().flatMap((element) => { const raw = $(element).attr('data-src') ?? $(element).attr('data-original-src') ?? $(element).attr('src'); if (raw === undefined)
    return []; const url = new URL(raw, base); return url.origin === origin && /\/static\/images\//u.test(url.pathname) && /\.(?:jpe?g|png|webp|gif)$/iu.test(url.pathname) ? [url] : []; })); }
function uniqueUrls(values) { const seen = new Set(); return values.filter((url) => { const key = `${url.origin}${url.pathname}`; if (seen.has(key))
    return false; seen.add(key); return true; }); }
function mime(url) { const ext = /\.([^.]+)$/u.exec(url.pathname)?.[1]?.toLowerCase(); return ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : null; }
function isCf(body) { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body); }
function needsVerification(status, body) { return status === 403 || status === 503 || (typeof body === 'string' && isCf(body)); }
function delay(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
