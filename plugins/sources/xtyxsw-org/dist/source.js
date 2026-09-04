/**
 * Tianyue parser using public PC HTTP only; no browser, Cookie, or user-agent fallback.
 * If direct search is empty, the new-book list and first three catalog categories are inspected, with two requests at most in flight and early cancellation at 20 matches.
 * GET display projections are cached according to the source policy; POST search and page parsing remain source-owned.
 */
import * as cheerio from 'cheerio/slim';
import { ProjectionCache } from './projection-cache.js';
const origin = 'https://www.xtyxsw.org';
export const categories = Object.freeze([
    ['fantasy', '玄幻', 'sort', '1'], ['fantasy-west', '奇幻', 'sort', '2'], ['wuxia', '武侠', 'sort', '3'], ['urban', '都市', 'sort', '4'], ['history', '历史', 'sort', '5'], ['military', '军事', 'sort', '6'], ['mystery', '悬疑', 'sort', '7'], ['game', '游戏', 'sort', '8'], ['science-fiction', '科幻', 'sort', '9'], ['sports', '体育', 'sort', '10'], ['ancient-romance', '古言', 'sort', '11'], ['modern-romance', '现言', 'sort', '12'], ['fantasy-romance', '幻言', 'sort', '13'], ['xianxia', '仙侠', 'sort', '14'], ['youth', '青春', 'sort', '15'], ['transmigration', '穿越', 'sort', '16'], ['women', '女生', 'sort', '17'], ['other', '其他', 'sort', '18'], ['visits', '点击榜', 'ranking', 'allvisit'], ['votes', '推荐榜', 'ranking', 'allvote'], ['favorites', '收藏榜', 'ranking', 'goodnum'], ['new', '新书入库', 'ranking', 'postdate'],
]);
export const projectionCachePolicy = Object.freeze({ lists: Object.freeze({ capacity: 32, freshTtlMs: 5 * 60_000, staleTtlMs: 30 * 60_000 }), details: Object.freeze({ capacity: 64, freshTtlMs: 10 * 60_000, staleTtlMs: 60 * 60_000 }), chapters: Object.freeze({ capacity: 64, freshTtlMs: 10 * 60_000, staleTtlMs: 60 * 60_000 }) });
export const searchFallbackPolicy = Object.freeze({ categoryBudget: 4, concurrency: 2, maxResults: 20 });
export class TianyueSource {
    context;
    #listCache;
    #detailCache;
    #chaptersCache;
    constructor(context, options = {}) {
        this.context = context;
        this.#listCache = new ProjectionCache(projectionCachePolicy.lists, options.now);
        this.#detailCache = new ProjectionCache(projectionCachePolicy.details, options.now);
        this.#chaptersCache = new ProjectionCache(projectionCachePolicy.chapters, options.now);
    }
    async search(query) {
        if (query.trim() === '')
            return Object.freeze([]);
        const url = new URL('/search.html', origin);
        const body = new URLSearchParams({ searchkey: query }).toString();
        const response = await this.#fetch(url, { method: 'POST', headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-CN,zh;q=0.9', 'content-type': 'application/x-www-form-urlencoded; charset=UTF-8', origin, referer: `${origin}/` }, body });
        const direct = this.parseList(response, url, null);
        if (direct.length > 0)
            return direct;
        return this.#fallbackSearch(query);
    }
    async discover(categoryId, page) {
        const category = categories.find(([id]) => id === categoryId);
        if (category === undefined)
            throw new Error('Unknown category.');
        return this.#listCache.get(`discover:${categoryId}:${page}`, () => this.#loadDiscovery(category, page));
    }
    async #loadDiscovery(category, page, signal) {
        const path = category[2] === 'sort' ? (page === 1 ? `/sort/${category[3]}_1/` : `/sort/${category[3]}/${page}.html`) : (page === 1 ? `/${category[3]}/` : `/${category[3]}/${page}.html`);
        const url = new URL(path, origin);
        const init = { headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-CN,zh;q=0.9', referer: `${origin}/` }, ...(signal === undefined ? {} : { signal }) };
        const html = await this.#fetch(url, init);
        const $ = cheerio.load(html);
        const items = this.parseList(html, url, category[1]);
        const hasNext = $('a').toArray().some(element => clean($(element).text()) === '下一页');
        return Object.freeze({ items, hasNext });
    }
    parseList(html, pageUrl, fallbackCategory) {
        if (/找不到您要搜索的内容/u.test(html))
            return Object.freeze([]);
        const $ = cheerio.load(html);
        const seen = new Set();
        const items = [];
        const push = (url, title, author, cover, description, latestTitle, latestUrl, category) => { const bookId = bookNumber(url); if (bookId === null || seen.has(bookId))
            return; seen.add(bookId); items.push(summary({ bookId, title, author, url: readUrl(bookId), coverUrl: cover === null ? null : this.#proxyImage(new URL(cover, pageUrl), pageUrl), description, status: 'unknown', updatedAt: null, latestTitle, latestUrl, categories: category === null ? [] : [category] })); };
        $('#alistbox').each((_, element) => { const root = $(element); const titleLink = root.find('.info .title h2 a[href]').first(); const link = titleLink.length > 0 ? titleLink : root.find('.pic a[href]').first(); const href = link.attr('href'); const title = clean(link.text()) ?? clean(root.find('.pic img').first().attr('alt')); if (href === undefined || title === null)
            return; const latest = root.find('.sys a[href]').first(); const latestHref = latest.attr('href'); push(new URL(href, pageUrl), title, clean(root.find('.info .title span a').first().text()) ?? stripAuthor(clean(root.find('.info .title span').text())), root.find('.pic img').first().attr('src') ?? null, clean(root.find('.intro').text()), clean(latest.text()), latestHref === undefined ? null : new URL(latestHref, pageUrl), fallbackCategory); });
        $('ul.list li').each((_, element) => { const root = $(element); const link = root.find('p.bookname a[href]').first(); const href = link.attr('href'); const title = clean(link.text()); if (href === undefined || title === null)
            return; const latest = root.find('p.data a[href]').filter((_, a) => !$(a).hasClass('layui-btn')).first(); const latestHref = latest.attr('href'); push(new URL(href, pageUrl), title, clean(root.find('p.data a.layui-btn').first().text()), root.find('img').first().attr('src') ?? null, null, clean(latest.text()), latestHref === undefined ? null : new URL(latestHref, pageUrl), fallbackCategory); });
        return Object.freeze(items);
    }
    async getDetail(id) {
        const bookId = decodeBookId(id);
        return this.#detailCache.get(`detail:${bookId}`, async () => {
            const url = new URL(`/book/${bookId}.html`, origin);
            const $ = cheerio.load(await this.#fetch(url));
            const heading = $('.bookname h1').first();
            const author = clean(heading.find('em').text())?.replace(/^作者[：:]?\s*/u, '') ?? null;
            heading.find('em').remove();
            const title = clean(heading.text());
            if (title === null)
                throw new Error('Detail title is missing.');
            const table = clean($('.box_info table').text()) ?? '';
            const category = clean(/小说分类[：:]?\s*([^首]+?)(?:首发状态|小说状态)/u.exec(table)?.[1]);
            const status = parseStatus(/小说状态[：:]?\s*([^收]+?)(?:收藏总数|$)/u.exec(table)?.[1] ?? null);
            const latest = $('.book_newchap p.ti').last();
            const href = latest.find('a[href]').attr('href');
            const updatedAt = clean(latest.find('em').text());
            const cover = $('.box_intro .pic img').first().attr('src');
            return Object.freeze({ ...summary({ bookId, title, author, url: readUrl(bookId), coverUrl: cover === undefined ? null : this.#proxyImage(new URL(cover, url), url), description: clean($('.box_info .intro').text()), status, updatedAt, latestTitle: clean(latest.find('a').text()), latestUrl: href === undefined ? null : new URL(href, url), categories: category === null ? [] : [category] }), aliases: Object.freeze([]), catalogUrl: readUrl(bookId).toString() });
        });
    }
    async getChapters(id) {
        const bookId = decodeBookId(id);
        return this.#chaptersCache.get(`chapters:${bookId}`, async () => {
            const url = readUrl(bookId);
            const $ = cheerio.load(await this.#fetch(url));
            const seen = new Set();
            const chapters = [];
            $('.link_14 dl dd a[href]').each((_, element) => { const href = $(element).attr('href'); const title = clean($(element).text()); if (href === undefined || title === null)
                return; const chapter = new URL(href, url); const chapterNumberValue = chapterNumber(chapter, bookId); if (chapterNumberValue === null || seen.has(chapterNumberValue))
                return; seen.add(chapterNumberValue); chapters.push(Object.freeze({ id: `chapter:${bookId}:${chapterNumberValue}`, title, order: chapters.length, url: chapter.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) })); });
            if (chapters.length === 0)
                throw new Error('Catalog is empty.');
            if (chapters.length > 5000)
                throw new Error('Catalog exceeds the Runtime chapter limit.');
            return Object.freeze({ items: Object.freeze(chapters) });
        });
    }
    async getContent(id, chapterId) {
        const bookId = decodeBookId(id);
        const chapterNumberValue = decodeChapterId(chapterId, bookId);
        let url = new URL(`/read/${bookId}/${chapterNumberValue}.html`, origin);
        const visited = new Set();
        const paragraphs = [];
        let title = null;
        for (let page = 0; page < 120; page += 1) {
            if (visited.has(url.toString()))
                throw new Error('Chapter pagination loop detected.');
            visited.add(url.toString());
            const $ = cheerio.load(await this.#fetch(url));
            title ??= clean($('h2').first().text());
            for (const element of $('#content p').toArray()) {
                const value = clean($(element).text());
                if (value !== null && !isNoise(value))
                    paragraphs.push(value);
            }
            const next = $('#thumb a,.pager a').toArray().find(element => { const label = (clean($(element).text()) ?? '').replace(/\s+/gu, ''); return label.includes('下一页') && !label.includes('下一章'); });
            if (next === undefined)
                return Object.freeze({ chapterId, contentKind: 'novel', title, updatedAt: null, text: paragraphs.join('\n\n'), pages: Object.freeze([]) });
            const href = $(next).attr('href');
            if (href === undefined)
                throw new Error('Chapter continuation is invalid.');
            const candidate = new URL(href, url);
            if (!isChapterContinuation(candidate, bookId, chapterNumberValue) || candidate.toString() === url.toString())
                throw new Error('Chapter continuation is invalid.');
            url = candidate;
        }
        throw new Error('Chapter page count exceeds the source limit.');
    }
    async #fallbackSearch(query) {
        const needle = query.trim().toLocaleLowerCase('zh-CN');
        const matches = [];
        const seen = new Set();
        const newest = categories.find(([id]) => id === 'new');
        const candidates = [...(newest === undefined ? [] : [newest]), ...categories.filter(([id]) => id !== 'new')].slice(0, searchFallbackPolicy.categoryBudget);
        const controller = new AbortController();
        let next = 0;
        let stopped = false;
        const worker = async () => { for (;;) {
            if (stopped)
                return;
            const index = next;
            next += 1;
            const category = candidates[index];
            if (category === undefined)
                return;
            let result;
            try {
                result = await this.#loadDiscovery(category, 1, controller.signal);
            }
            catch (error) {
                if (stopped && isAbortError(error))
                    return;
                throw error;
            }
            if (stopped)
                return;
            for (const item of result.items) {
                const hay = `${item.title} ${item.author ?? ''}`.toLocaleLowerCase('zh-CN');
                if (hay.includes(needle) && !seen.has(item.id)) {
                    seen.add(item.id);
                    matches.push(item);
                    if (matches.length >= searchFallbackPolicy.maxResults) {
                        stopped = true;
                        controller.abort();
                        return;
                    }
                }
            }
        } };
        try {
            await Promise.all(Array.from({ length: searchFallbackPolicy.concurrency }, worker));
        }
        catch (error) {
            stopped = true;
            controller.abort();
            throw error;
        }
        return Object.freeze(matches);
    }
    async #fetch(url, init) { const response = await this.context.http.fetch(url, init ?? { headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-CN,zh;q=0.9', referer: `${origin}/` } }); const body = await response.text(); if (!response.ok || /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body))
        throw new Error('Source page is unavailable.'); return body; }
    #proxyImage(url, referer) { return url.protocol === 'https:' && url.hostname === 'img.xtyxsw.org' && referer.origin === origin ? this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } }) : null; }
}
function summary(input) { const chapter = input.latestUrl === null ? null : chapterNumber(input.latestUrl, input.bookId); return Object.freeze({ id: `book:${input.bookId}`, title: input.title, contentKind: 'novel', author: input.author, url: input.url.toString(), coverUrl: input.coverUrl, description: input.description, language: 'zh-CN', status: input.status, access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: input.updatedAt, latestChapter: input.latestTitle === null ? null : Object.freeze({ id: chapter === null ? null : `chapter:${input.bookId}:${chapter}`, title: input.latestTitle, url: chapter === null ? null : input.latestUrl.toString(), updatedAt: input.updatedAt }), categories: Object.freeze(input.categories), tags: Object.freeze([]), attributes: Object.freeze([]) }); }
function readUrl(bookId) { return new URL(`/read/${bookId}/`, origin); }
function bookNumber(url) { return /^\/(?:book|read)\/(\d+)(?:\.html|\/)?$/u.exec(url.pathname)?.[1] ?? null; }
function chapterNumber(url, bookId) { return new RegExp(`^/read/${bookId}/(\\d+)\\.html$`, 'u').exec(url.pathname)?.[1] ?? null; }
function decodeBookId(id) { const value = /^book:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function decodeChapterId(id, bookId) { const match = /^chapter:(\d+):(\d+)$/u.exec(id); if (match?.[1] !== bookId || match[2] === undefined)
    throw new Error('Chapter ID is invalid.'); return match[2]; }
function isChapterContinuation(url, bookId, chapterId) { return url.origin === origin && new RegExp(`^/read/${bookId}/${chapterId}(?:_\\d+)?\\.html$`, 'u').test(url.pathname); }
function isAbortError(error) { return error instanceof DOMException && error.name === 'AbortError'; }
function clean(value) { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function stripAuthor(value) { return value === null ? null : clean(value.replace(/^作者[：:]?\s*/u, '')); }
function parseStatus(value) { if (value === null)
    return 'unknown'; if (/(?:完结|已完结|完本)/u.test(value))
    return 'completed'; if (/(?:连载|更新)/u.test(value))
    return 'ongoing'; if (/(?:停更|暂停)/u.test(value))
    return 'hiatus'; return 'unknown'; }
function isNoise(value) { return /(?:天悦小说网|手机阅读|无弹窗|小主，这个章节后面还有哦|请点击下一页继续阅读|请大家收藏：|更新速度全网最快|章节报错|加入书签)/u.test(value); }
