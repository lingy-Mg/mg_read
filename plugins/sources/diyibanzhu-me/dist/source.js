/**
 * First Edition mobile source.
 *
 * Protected HTML uses one Runtime-owned WebView page. Requests run through the
 * page's same-origin fetch. The page stays hidden unless verification requires
 * human interaction, then hides again after success.
 */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';
import { PluginCache } from '@mgread/plugin-cache';
const origin = 'https://m.diyibanzhu.me';
const browserTimeoutMs = 120000;
const listingPolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 10 * 60 * 1000, serveStaleWhileRevalidate: true });
const detailPolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
const catalogPolicy = Object.freeze({ namespace: 'catalog', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const categories = Object.freeze([['total', '总人气榜', '/wap.php?action=shuku&order=1'], ['month', '月人气榜', '/wap.php?action=shuku&order=2'], ['new', '新书榜', '/wap.php?action=shuku&order=3'], ['words', '字数榜', '/wap.php?action=shuku&order=4'], ['updates', '最新更新', '/wap.php?action=shuku'], ['fantasy', '玄幻·奇幻', '/wap.php?action=shuku&order=3&tid=4'], ['martial', '仙侠·武侠', '/wap.php?action=shuku&order=3&tid=3'], ['city', '都市·言情', '/wap.php?action=shuku&order=3&tid=2'], ['history', '穿越·历史', '/wap.php?action=shuku&order=3&tid=1'], ['scifi', '科幻·灵异', '/wap.php?action=shuku&order=3&tid=6'], ['other', '其他小说', '/wap.php?action=shuku&order=3&tid=8']]);
export class DiyibanzhuSource {
    context;
    #cache;
    #pagePromise;
    #readyPromise;
    #browserTail = Promise.resolve();
    constructor(context) {
        this.context = context;
        this.#cache = new PluginCache(context.cacheDir, { logger: context.log });
    }
    async search(query) { const url = new URL('/wap.php?action=search', origin); const html = await this.#browser(url, 'POST', `objectType=2&wd=${encodeURIComponent(query)}`); return this.parseList(html, url); }
    async discover(id, page) { const rule = categories.find(([key]) => key === id); if (rule === undefined)
        throw new Error('Unknown category.'); const firstUrl = new URL(rule[2], origin); this.context.log.info('source_discover_listing_started'); const firstHtml = await this.#cache.getOrFetchText(firstUrl, listingPolicy, () => this.#browser(firstUrl, 'GET', null)); const url = page === 1 ? firstUrl : paginationUrl(firstHtml, firstUrl, page); const html = page === 1 ? firstHtml : await this.#cache.getOrFetchText(url, listingPolicy, () => this.#browser(url, 'GET', null)); this.context.log.info('source_discover_listing_received'); const items = this.parseList(html, url); this.context.log.info('source_discover_listing_parsed'); return items; }
    parseList(html, base) { const $ = cheerio.load(html); const seen = new Set(); const items = []; $('li.column-2').each((_, element) => { const root = $(element); const link = root.find('a.name,.right a').first(); const href = link.attr('href'); const title = clean(link.text()) ?? clean(root.find('.right .name').text()); if (href === undefined || title === null)
        return; const url = new URL(href, base); if (!isBook(url) || seen.has(url.toString()))
        return; seen.add(url.toString()); const info = clean(root.find('.info').text()) ?? ''; const author = clean(root.find('.author').text()) ?? clean(/作者[：:]\s*(.+?)(?=字数[：:]|$)/u.exec(info)?.[1]); const latest = clean(root.find('.update a').text()); const words = parseCount(root.find('.words').text()) ?? parseCount(info); items.push(summary(url, title, author, null, null, words, latest, [])); }); return Object.freeze(items); }
    async detail(id) { const url = decode(id, 'book'); const html = await this.#cache.getOrFetchText(url, detailPolicy, () => this.#browser(url, 'GET', null)); const $ = cheerio.load(html); const title = clean($('.mod.detail .right h1,.detail h1').first().text()); if (title === null)
        throw new Error('Detail title is missing.'); const info = clean($('.mod.detail .right p').text()) ?? ''; const author = clean(/作者[：:]\s*(.+?)(?=类型|字数|人气|$)/u.exec(info)?.[1]) ?? clean($('.mod.detail .author').text()); const kind = clean(/类型[：:]\s*(.+?)(?=字数|人气|$)/u.exec(info)?.[1]); const statusText = clean($('.mod.detail .status').text()); const status = statusText?.includes('完结') === true ? 'completed' : statusText?.includes('连载') === true ? 'ongoing' : 'unknown'; const intro = clean($('.mod.book-intro .bd').text()); const latest = clean($('.mod.block.update.chapter-list .bd li a').first().text()); const coverRaw = $('.mod.detail img,.detail img').first().attr('src'); const cover = coverRaw === undefined ? null : this.#proxy(new URL(coverRaw, url), url); return Object.freeze({ ...summary(url, title, author, cover, intro, null, latest, kind === null ? [] : [kind]), aliases: Object.freeze([]), catalogUrl: url.toString(), status }); }
    async chapters(id) { const first = decode(id, 'book'); const items = []; const seen = new Set(); let url = first; for (let page = 0; page < 100; page += 1) {
        const html = await this.#cache.getOrFetchText(url, catalogPolicy, () => this.#browser(url, 'GET', null));
        const $ = cheerio.load(html);
        const blocks = $('.mod.block.update.chapter-list');
        const block = blocks.length >= 2 ? blocks.eq(1) : blocks.eq(0);
        block.find('.bd li a').each((_, element) => { const href = $(element).attr('href'); const title = clean($(element).text()); if (href === undefined || title === null)
            return; const chapter = new URL(href, url); if (!isChapter(chapter) || seen.has(chapter.toString()))
            return; seen.add(chapter.toString()); items.push({ id: `chapter:${token(chapter)}`, title, order: items.length, url: chapter.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) }); });
        const next = $('a.nextPage,.pagelistbox .nextPage').first().attr('href');
        if (next === undefined)
            break;
        const candidate = new URL(next, url);
        if (candidate.toString() === url.toString() || candidate.origin !== origin)
            break;
        url = candidate;
    } if (items.length === 0)
        throw new Error('Catalog is empty.'); return Object.freeze({ items: Object.freeze(items) }); }
    async content(id, chapterId) { decode(id, 'book'); let url = decode(chapterId, 'chapter'); const lines = []; const seen = new Set(); for (let page = 0; page < 15 && !seen.has(url.toString()); page += 1) {
        seen.add(url.toString());
        const html = await this.#browser(url, 'GET', null);
        const $ = cheerio.load(html);
        const raw = $('#nr1').text();
        for (const value of raw.split(/\r?\n/u)) {
            const line = value.replace(/[\u00a0\u3000]/gu, ' ').trim();
            if (line !== '' && !/(?:本章未完|点击.*继续阅读|加入书签|章节报错|第一版主)/u.test(line))
                lines.push(line);
        }
        let next;
        $('.chapterPages a[href]').each((_, element) => { if (next !== undefined)
            return; const candidate = new URL($(element).attr('href'), url); const number = Number(/_(\d+)\.html$/u.exec(candidate.pathname)?.[1] ?? candidate.searchParams.get('fenye')); const current = Number(/_(\d+)\.html$/u.exec(url.pathname)?.[1] ?? url.searchParams.get('fenye') ?? 1); if (number === current + 1)
            next = candidate; });
        if (next === undefined || next.toString() === url.toString())
            break;
        url = next;
    } const text = lines.join('\n\n'); if (text === '')
        throw new Error('Chapter text is empty.'); return Object.freeze({ chapterId, contentKind: 'novel', title: null, updatedAt: null, text, pages: Object.freeze([]) }); }
    #browser(url, method, body) { const operation = this.#browserTail.then(() => this.#browserNow(url, method, body)); this.#browserTail = operation.then(() => undefined, () => undefined); return operation; }
    async #browserNow(url, method, body) { let stage = 'page_open'; try {
        const page = await this.#page();
        stage = 'ready';
        await this.#ready(page);
        stage = 'initial_fetch';
        let response = await this.#fetchWithDiagnostics(page, url, method, body, 'initial');
        if (needsVerification(response.status, response.body)) {
            this.context.log.warn('source_browser_verification_required');
            this.#readyPromise = undefined;
            stage = 'verification';
            await this.#verify(page, method === 'GET' ? url : new URL(origin));
            this.#readyPromise = Promise.resolve();
            stage = 'retry_fetch';
            response = await this.#fetchWithDiagnostics(page, url, method, body, 'retry');
        }
        stage = 'response_validation';
        if (response.status >= 400)
            throw new Error(`Browser request failed with status ${response.status}.`);
        if (typeof response.body !== 'string')
            throw new Error('Browser returned a non-text response.');
        if (isCf(response.body))
            throw new Error('Browser verification is incomplete.');
        return response.body;
    }
    catch (error) {
        this.context.log.warn(`source_browser_failed_stage_${stage}`);
        throw error;
    } }
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
        return this.#readyPromise; const pending = this.#verify(page, new URL(origin)); this.#readyPromise = pending; try {
        await pending;
    }
    catch (error) {
        if (this.#readyPromise === pending)
            this.#readyPromise = undefined;
        throw error;
    } }
    async #verify(page, url) { this.context.log.info('source_browser_navigate_started'); await page.navigate(url.toString(), { timeoutMs: browserTimeoutMs }); this.context.log.info('source_browser_navigate_completed'); let html = await page.getHtml({ timeoutMs: browserTimeoutMs }); if (isCf(html)) {
        this.context.log.warn('source_browser_challenge_detected');
        await page.show({ timeoutMs: browserTimeoutMs });
        this.context.log.info('source_browser_verification_wait_started');
        await this.#waitForVerification(page);
        this.context.log.info('source_browser_verification_wait_completed');
        const current = new URL(await page.getUrl({ timeoutMs: browserTimeoutMs }));
        if (current.origin !== origin)
            throw new Error('Browser verification left the source origin.');
        html = await page.getHtml({ timeoutMs: browserTimeoutMs });
        if (isCf(html))
            throw new Error('Browser verification is incomplete.');
        await page.hide({ timeoutMs: browserTimeoutMs });
    } }
    async #waitForVerification(page) { const deadline = Date.now() + browserTimeoutMs; while (Date.now() < deadline) {
        await delay(1000);
        if (!isCf(await page.getHtml({ timeoutMs: browserTimeoutMs })))
            return;
    } throw new Error('Browser verification is incomplete.'); }
    async #fetchWithDiagnostics(page, url, method, body, attempt) { this.context.log.info(`source_browser_${attempt}_fetch_started`); const response = await this.#fetch(page, url, method, body); this.context.log.info(`source_browser_${attempt}_fetch_completed_${statusClass(response.status)}`); return response; }
    #fetch(page, url, method, body) { return page.fetch({ url: url.toString(), method, headers: method === 'POST' ? { 'content-type': 'application/x-www-form-urlencoded', accept: 'text/html' } : { accept: 'text/html' }, body, responseType: 'text', timeoutMs: browserTimeoutMs }); }
    #proxy(url, referer) { if (url.origin !== origin || referer.origin !== origin)
        throw new Error('Image URL is invalid.'); return this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } }); }
}
function summary(url, title, author, coverUrl, description, wordCount, latest, categories) { return Object.freeze({ id: `book:${token(url)}`, title, contentKind: 'novel', author, url: url.toString(), coverUrl, description, language: 'zh-CN', status: 'unknown', access: 'free', wordCount, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: latest === null ? null : { id: null, title: latest, url: null, updatedAt: null }, categories: Object.freeze(categories), tags: Object.freeze([]), attributes: Object.freeze([]) }); }
function token(url) { return Buffer.from(`${url.pathname}${url.search}`, 'utf8').toString('base64url'); }
function decode(value, prefix) { const match = new RegExp(`^${prefix}:([A-Za-z0-9_-]+)$`, 'u').exec(value); if (match?.[1] === undefined)
    throw new Error('Opaque ID is invalid.'); const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin); if (url.origin !== origin || (prefix === 'book' ? !isBook(url) : !isChapter(url)))
    throw new Error('Opaque ID is invalid.'); return url; }
function isBook(url) { return url.origin === origin && (/\/list\/\d+(?:_\d+)*\.html$/u.test(url.pathname) || (url.pathname === '/wap.php' && url.searchParams.get('action') === 'list' && /^\d+$/u.test(url.searchParams.get('id') ?? ''))); }
function isChapter(url) { return url.origin === origin && (/\/view\/\d+(?:_\d+)?\.html$/u.test(url.pathname) || (url.pathname === '/wap.php' && url.searchParams.get('action') === 'article' && /^\d+$/u.test(url.searchParams.get('id') ?? ''))); }
function paginationUrl(html, base, page) { const $ = cheerio.load(html); let template; $('a[href]').each((_, element) => { if (template !== undefined)
    return; const href = $(element).attr('href'); if (href === undefined)
    return; const candidate = new URL(href, base); if (candidate.origin === origin && candidate.pathname === '/wap.php' && candidate.searchParams.get('action') === 'shuku' && candidate.searchParams.has('pageno'))
    template = candidate; }); if (template === undefined)
    throw new Error('Listing pagination is missing.'); template.searchParams.set('pageno', String(page)); return template; }
function clean(value) { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function parseCount(value) { const match = /([0-9]+(?:\.[0-9]+)?)(万?)/u.exec(value); if (match?.[1] === undefined)
    return null; const count = Math.round(Number(match[1]) * (match[2] === '万' ? 10000 : 1)); return Number.isSafeInteger(count) ? count : null; }
function isCf(body) { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser)/iu.test(body); }
function needsVerification(status, body) { return status === 403 || status === 503 || (typeof body === 'string' && isCf(body)); }
function statusClass(status) { if (status >= 200 && status < 300)
    return '2xx'; if (status >= 300 && status < 400)
    return '3xx'; if (status >= 400 && status < 500)
    return '4xx'; if (status >= 500 && status < 600)
    return '5xx'; return 'other'; }
function delay(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
