/**
 * Baozimh manga parser and HTTP/resource boundary.
 * Requests start from the current public entry; redirects and parsed resources retain their complete URLs without an origin or protocol gate.
 * Detail and catalog share one bounded book-page projection; image bytes are fetched and streamed only by Runtime.
 * HTML, manga pages, credentials, signed media URLs, and user input are handled by this source.
 */
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import * as cheerio from 'cheerio/slim';
import { ProjectionCache } from './projection-cache.js';
import { pathFor } from './discovery-filters.js';
const entryUrl = 'https://www.baozimh.com';
export const categories = Object.freeze([
    ['china', '國漫', '/classify?type=all&region=cn&state=all&filter=*'],
    ['japan', '日本', '/classify?type=all&region=jp&state=all&filter=*'],
    ['korea', '韓國', '/classify?type=all&region=kr&state=all&filter=*'],
    ['romance', '戀愛', '/classify?type=lianai&region=all&state=all&filter=*'],
    ['action', '熱血', '/classify?type=rexie&region=all&state=all&filter=*'],
    ['fantasy', '玄幻', '/classify?type=xuanhuan&region=all&state=all&filter=*'],
    ['adventure', '冒險', '/classify?type=mouxian&region=all&state=all&filter=*'],
    ['comedy', '搞笑', '/classify?type=gaoxiao&region=all&state=all&filter=*'],
]);
export const projectionCachePolicy = Object.freeze({
    lists: Object.freeze({ capacity: 32, freshTtlMs: 5 * 60_000, staleTtlMs: 30 * 60_000 }),
    books: Object.freeze({ capacity: 64, freshTtlMs: 10 * 60_000, staleTtlMs: 60 * 60_000 }),
});
export class BaozimhSource {
    context;
    #listCache;
    #bookCache;
    #discoveryCache;
    constructor(context, options = {}) {
        this.context = context;
        this.#listCache = new ProjectionCache(projectionCachePolicy.lists, options.now);
        this.#bookCache = new ProjectionCache(projectionCachePolicy.books, options.now);
        this.#discoveryCache = new ProjectionCache(projectionCachePolicy.lists, options.now);
    }
    async search(query) {
        const url = new URL('/search', entryUrl);
        url.searchParams.set('q', query);
        return this.#listCache.get(cacheKey('search', query), async () => { const response = await this.#html(url); return this.parseCards(response.body, response.url); });
    }
    async discover(categoryId) {
        const category = categories.find(([id]) => id === categoryId);
        if (category === undefined)
            throw new Error('Unknown category.');
        const url = new URL(category[2], entryUrl);
        return this.browse(Object.fromEntries(url.searchParams));
    }
    async browse(filters) {
        return (await this.browsePage(filters, null)).items;
    }
    async browsePage(filters, nextPath) {
        const path = nextPath === null ? pathFor(filters) : ampPath(nextPath, filters);
        return this.#discoveryCache.get(path, async () => {
            const response = await this.#html(new URL(path, entryUrl));
            if (nextPath === null) {
                const $ = cheerio.load(response.body), src = $('amp-list[load-more-bookmark="next"]').attr('src');
                // A WebView may already render page two inside amp-list. Keep it for the explicit continuation only.
                $('amp-list').remove();
                return { items: this.parseCards($.html(), response.url), next: src ? ampPath(src, filters) : null };
            }
            let value;
            try {
                value = JSON.parse(response.body);
            }
            catch {
                value = JSON.parse(cheerio.load(response.body)('pre').first().text());
            }
            if (!value || typeof value !== 'object' || !('items' in value) || !Array.isArray(value.items))
                throw new Error('Discovery page is invalid.');
            const seen = new Set(), items = [];
            for (const raw of value.items) {
                if (!raw || typeof raw !== 'object')
                    continue;
                const id = typeof raw.comic_id === 'string' ? raw.comic_id : '', title = typeof raw.name === 'string' ? clean(raw.name) : null;
                if (!/^[A-Za-z0-9_-]+$/u.test(id) || !title || seen.has(id))
                    continue;
                seen.add(id);
                const url = new URL('/comic/' + id, response.url), image = typeof raw.topic_img === 'string' ? new URL('/cover/' + raw.topic_img + '?w=285&h=375&q=100', 'https://static-tw.baozimh.com') : null;
                items.push(summary({ id: encodeBookId(url), url, title, author: typeof raw.author === 'string' ? clean(raw.author) : null, coverUrl: image ? this.#proxyImage(image, response.url) : null, description: null, status: 'unknown', latest: null, categories: Array.isArray(raw.type_names) ? unique(raw.type_names.filter((v) => typeof v === 'string')) : [] }));
            }
            const next = 'next' in value && typeof value.next === 'string' && value.next !== '' ? ampPath(value.next, filters) : null;
            if (next === path)
                throw new Error('Discovery pagination did not advance.');
            return { items: Object.freeze(items), next };
        });
    }
    parseCards(html, pageUrl) {
        const $ = cheerio.load(html);
        const seen = new Set();
        const items = [];
        $('div.comics-card').each((_, element) => {
            const card = $(element);
            const poster = card.find('a.comics-card__poster[href]').first();
            const href = poster.attr('href');
            const title = clean(poster.attr('title')) ?? clean(card.find('h3').first().text());
            if (href === undefined || title === null)
                return;
            const url = new URL(href, pageUrl);
            if (!isBookUrl(url) || seen.has(url.toString()))
                return;
            seen.add(url.toString());
            const image = poster.find('amp-img[src]').first().attr('src');
            const tags = unique(card.find('.tab').toArray().map((node) => $(node).text()));
            items.push(summary({ id: encodeBookId(url), url, title, author: clean(card.find('small.tags').first().text()),
                coverUrl: image === undefined ? null : this.#proxyImage(new URL(decodeEntities(image), pageUrl), pageUrl),
                description: null, status: 'unknown', latest: null, categories: tags }));
        });
        return Object.freeze(items);
    }
    async getDetail(id) {
        return (await this.#getBookProjection(id)).detail;
    }
    async getChapters(id) {
        return (await this.#getBookProjection(id)).chapters;
    }
    async getContent(id, chapterId) {
        decodeBookId(id);
        const chapterUrl = decodeChapterId(chapterId, id);
        const response = await this.#html(chapterUrl);
        const $ = cheerio.load(response.body);
        const seen = new Set();
        const pages = [];
        $('amp-img.comic-contain__item[src]').each((_, element) => {
            const image = $(element);
            const raw = image.attr('src');
            if (raw === undefined)
                return;
            const url = new URL(decodeEntities(raw), response.url);
            if (/default_cover/iu.test(url.pathname) || seen.has(url.toString()))
                return;
            seen.add(url.toString());
            const index = pages.length;
            pages.push(Object.freeze({ id: `page:${index + 1}`, index, url: this.#proxyImage(url, response.url), mimeType: imageMime(url),
                width: dimension(image.attr('width')), height: dimension(image.attr('height')) }));
        });
        if (pages.length === 0)
            throw new Error('Chapter images are missing.');
        return Object.freeze({ chapterId, contentKind: 'manga', title: clean($('.header .text .title').first().text()) ?? clean($('title').text()),
            updatedAt: null, text: null, pages: Object.freeze(pages) });
    }
    async #getBookProjection(id) {
        const requestedUrl = decodeBookId(id);
        return this.#bookCache.get(`book:${requestedUrl.toString()}`, async () => {
            const response = await this.#html(requestedUrl);
            const finalUrl = response.url;
            const $ = cheerio.load(response.body);
            const title = meta($, 'og:novel:book_name') ?? clean($('title').text())?.replace(/^\P{L}+/u, '').replace(/\s+-\s+包子漫畫.*$/u, '') ?? null;
            if (title === null)
                throw new Error('Detail title is missing.');
            const categories = splitTags(meta($, 'og:novel:category'));
            const coverRaw = meta($, 'og:image');
            const latestTitle = meta($, 'og:novel:latest_chapter_name');
            const latestRaw = meta($, 'og:novel:latest_chapter_url');
            const latestUrl = latestRaw === null ? null : new URL(latestRaw, finalUrl);
            const detail = Object.freeze({
                ...summary({ id, url: finalUrl, title, author: meta($, 'og:novel:author'), coverUrl: coverRaw === null ? null : this.#proxyImage(new URL(coverRaw, finalUrl), finalUrl),
                    description: meta($, 'og:description') ?? clean($('.comics-detail__desc').first().text()), status: parseStatus(meta($, 'og:novel:status')),
                    latest: latestTitle === null ? null : { title: latestTitle, url: latestUrl }, categories }),
                aliases: Object.freeze([]), catalogUrl: finalUrl.toString(),
            });
            const chapters = [];
            const seen = new Set();
            $('#chapter-items a.comics-chapters__item[href]').each((_, element) => {
                const link = $(element);
                const href = link.attr('href');
                const chapterTitle = clean(link.find('span').first().text()) ?? clean(link.text());
                if (href === undefined || chapterTitle === null)
                    return;
                const direct = directChapterUrl(new URL(decodeEntities(href), finalUrl));
                if (direct === null || seen.has(direct.toString()))
                    return;
                seen.add(direct.toString());
                chapters.push(Object.freeze({ id: encodeChapterId(id, direct), title: chapterTitle, order: chapters.length, url: direct.toString(), volumeTitle: null,
                    wordCount: null, updatedAt: null, isLocked: false, attributes: Object.freeze([]) }));
            });
            if (chapters.length === 0)
                throw new Error('Catalog is empty.');
            if (chapters.length > 5000)
                throw new Error('Catalog exceeds the Runtime chapter limit.');
            return Object.freeze({ detail, chapters: Object.freeze({ items: Object.freeze(chapters) }) });
        });
    }
    async #html(url) {
        const response = await this.context.http.fetch(url, { redirect: 'follow', headers: { accept: 'text/html,application/xhtml+xml', 'accept-language': 'zh-TW,zh;q=0.9', referer: new URL('/', url).toString() } });
        const body = await response.text();
        if (response.ok && !isChallenge(body))
            return Object.freeze({ body, url: new URL(response.url || url.toString()) });
        if (isChallengeResponse(response.status, body))
            return this.#htmlFromWebView(url, getChallengeUrl(body, url));
        return this.#accessBlocked();
    }
    async #htmlFromWebView(url, verificationUrl) {
        const page = await this.context.webview.open({ visible: false, timeoutMs: 30_000 });
        if (verificationUrl !== null) {
            await page.navigate(verificationUrl.toString(), { timeoutMs: 45_000 });
            const challengePage = await page.getHtml({ timeoutMs: 20_000 });
            const currentUrl = new URL(await page.getUrl({ timeoutMs: 5_000 }));
            if (currentUrl.pathname.includes('/__gatekeeper_challenge/')) {
                const challenge = parseChallenge(challengePage, currentUrl);
                if (challenge === null || !(await solveChallenge(page, challenge)))
                    return this.#accessBlocked();
            }
        }
        await page.navigate(url.toString(), { timeoutMs: 45_000 });
        const body = await page.getHtml({ timeoutMs: 20_000 });
        if (isChallenge(body))
            return this.#accessBlocked();
        const finalUrl = await page.getUrl({ timeoutMs: 5_000 });
        return Object.freeze({ body, url: new URL(finalUrl || url.toString()) });
    }
    #accessBlocked() {
        if (this.context.errors !== undefined) {
            return this.context.errors.raise({ code: 'source_access_blocked', message: '包子漫画需要在浏览器会话中完成站点验证。', annotation: '请在应用中打开该数据源后重试。' });
        }
        throw new Error('Source page is unavailable.');
    }
    #proxyImage(url, referer) { return this.context.resource.proxy({ kind: 'image', url: imageOrigin(url).toString(), headers: { Accept: 'image/avif,image/webp,image/*,*/*;q=0.8', Referer: referer.toString() } }); }
}
function summary(input) {
    return Object.freeze({ id: input.id, title: input.title, contentKind: 'manga', author: input.author, url: input.url.toString(), coverUrl: input.coverUrl,
        description: input.description, language: 'zh-TW', status: input.status, access: 'free', wordCount: null, chapterCount: null, publishedAt: null,
        updatedAt: null, latestChapter: input.latest === null ? null : Object.freeze({ id: input.latest.url === null ? null : encodeChapterId(input.id, input.latest.url),
            title: input.latest.title, url: input.latest.url?.toString() ?? null, updatedAt: null }), categories: Object.freeze(input.categories), tags: Object.freeze(input.categories), attributes: Object.freeze([]) });
}
function meta($, name) { return clean($(`meta[name="${name}"],meta[property="${name}"]`).first().attr('content')); }
function ampPath(value, filters) {
    const url = new URL(value, entryUrl), page = Number(url.searchParams.get('page'));
    if (url.pathname !== '/api/bzmhq/amp_comic_list' || !Number.isSafeInteger(page) || page < 2 || page > 10000 || Object.entries(filters).some(([key, value]) => url.searchParams.get(key) !== value))
        throw new Error('Discovery next page is invalid.');
    return url.pathname + url.search;
}
function encodeBookId(url) { return `comic:${token(url.toString())}`; }
function decodeBookId(id) { const value = /^comic:([A-Za-z0-9_-]+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); const url = new URL(Buffer.from(value, 'base64url').toString('utf8'), entryUrl); if (!isBookUrl(url))
    throw new Error('Content ID is invalid.'); return url; }
function encodeChapterId(bookId, url) { return `chapter:${token(bookId)}:${token(url.toString())}`; }
function decodeChapterId(id, bookId) { const match = /^chapter:([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$/u.exec(id); if (match?.[1] === undefined || match[2] === undefined || Buffer.from(match[1], 'base64url').toString('utf8') !== bookId)
    throw new Error('Chapter ID is invalid.'); const url = new URL(Buffer.from(match[2], 'base64url').toString('utf8'), entryUrl); if (!isChapterUrl(url))
    throw new Error('Chapter ID is invalid.'); return url; }
function token(value) { return Buffer.from(value, 'utf8').toString('base64url'); }
function cacheKey(scope, value) { return `${scope}:${createHash('sha256').update(value).digest('base64url')}`; }
function isBookUrl(url) { return /^\/comic\/[A-Za-z0-9_-]+\/?$/u.test(url.pathname); }
function isChapterUrl(url) { return /^\/comic\/chapter\/[A-Za-z0-9_-]+\/\d+_\d+\.html$/u.test(url.pathname); }
function directChapterUrl(url) { if (url.pathname !== '/user/page_direct')
    return isChapterUrl(url) ? url : null; const comicId = url.searchParams.get('comic_id'); const section = url.searchParams.get('section_slot'); const chapter = url.searchParams.get('chapter_slot'); if (comicId === null || !/^[A-Za-z0-9_-]+$/u.test(comicId) || !/^\d+$/u.test(section ?? '') || !/^\d+$/u.test(chapter ?? ''))
    return null; return new URL(`/comic/chapter/${comicId}/${section}_${chapter}.html`, url.origin); }
function imageMime(url) { const ext = /\.([A-Za-z0-9]+)$/u.exec(url.pathname)?.[1]?.toLowerCase(); return ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : null; }
function imageOrigin(url) { return url.hostname === 'static-tw.baozimh.com' ? new URL(`${url.pathname}${url.search}`, 'https://s1.bzcdn.net') : url; }
function dimension(value) { const number = Number(value); return Number.isSafeInteger(number) && number > 0 ? number : null; }
function splitTags(value) { return value === null ? Object.freeze([]) : unique(value.split(/[,，]/u)); }
function unique(values) { return Object.freeze([...new Set(values.map((value) => value.replace(/\s+/gu, ' ').trim()).filter(Boolean))]); }
function decodeEntities(value) { return value.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&#x27;', "'"); }
function clean(value) { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function parseStatus(value) { if (value === null)
    return 'unknown'; if (/(?:完結|完本|已完結)/u.test(value))
    return 'completed'; if (/(?:連載|更新中)/u.test(value))
    return 'ongoing'; if (/(?:停更|暫停)/u.test(value))
    return 'hiatus'; return 'unknown'; }
function isChallenge(body) { return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform|challenge_required|challenge_url)/iu.test(body); }
function isChallengeResponse(status, body) { return status === 403 && /(?:challenge_required|challenge_url)/iu.test(body); }
function getChallengeUrl(body, base) {
    try {
        const value = JSON.parse(body);
        if (typeof value !== 'object' || value === null || !('challenge_url' in value) || typeof value.challenge_url !== 'string')
            return null;
        const url = new URL(value.challenge_url, base);
        return url.origin === base.origin ? url : null;
    }
    catch {
        return null;
    }
}
function parseChallenge(body, base) {
    const challengeId = /challengeId:"([^"]+)"/u.exec(body)?.[1];
    const ticket = /ticket:"([^"]+)"/u.exec(body)?.[1];
    const verifyRaw = /verifyUrl:"([^"]+)"/u.exec(body)?.[1];
    const difficultyBits = Number(/difficultyBits:(\d+)/u.exec(body)?.[1]);
    if (challengeId === undefined || ticket === undefined || verifyRaw === undefined || !Number.isSafeInteger(difficultyBits) || difficultyBits < 1 || difficultyBits > 24)
        return null;
    const verifyUrl = new URL(verifyRaw, base);
    return verifyUrl.origin === base.origin ? Object.freeze({ challengeId, ticket, verifyUrl, difficultyBits }) : null;
}
async function solveChallenge(page, challenge) {
    const nonce = findProofOfWork(challenge.challengeId, challenge.difficultyBits);
    const result = await page.executeJavaScript(`return (async()=>{const response=await fetch(${JSON.stringify(challenge.verifyUrl.toString())},{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json'},body:JSON.stringify({challenge_id:${JSON.stringify(challenge.challengeId)},ticket:${JSON.stringify(challenge.ticket)},nonce:${JSON.stringify(nonce)}})});return {status:response.status,body:await response.text()};})()`, { timeoutMs: 30_000 });
    return result.status === 200 && /"status"\s*:\s*"passed"/u.test(result.body);
}
function findProofOfWork(challengeId, difficultyBits) {
    for (let nonce = 0; nonce <= 10_000_000; nonce += 1) {
        if (leadingZeroBits(createHash('sha256').update(`gatekeeper-pow-v1:${challengeId}:${nonce}`).digest()) >= difficultyBits)
            return String(nonce);
    }
    throw new Error('Gatekeeper verification computation exceeded the safe limit.');
}
function leadingZeroBits(bytes) {
    let count = 0;
    for (const byte of bytes)
        for (let bit = 7; bit >= 0; bit -= 1) {
            if (((byte >> bit) & 1) === 0)
                count += 1;
            else
                return count;
        }
    return count;
}
