/**
 * HTTP and parsing implementation for the Douyin Xiaoshuo mobile source.
 *
 * Runtime owns network and image proxying. This module only uses public context capabilities,
 * keeps content identities opaque, enriches coverless listings through cached detail reads,
 * caches display projections and never records response data.
 */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';
import { BoundedTextCache } from './cache.js';
const origin = 'https://m.douyinxs.com';
const imageHosts = new Set(['m.douyinxs.com', 'img.douyinxs.com']);
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
const catalogPolicy = Object.freeze({
    namespace: 'catalog',
    staleAfterMs: 60 * 60 * 1000,
    allowStaleOnError: false,
});
export const categories = Object.freeze([
    ['all', '全部分类', '0'],
    ['fantasy', '玄奇', '1'],
    ['martial', '高武', '2'],
    ['cultivation', '修仙', '3'],
    ['urban', '都市', '4'],
    ['military', '军事', '5'],
    ['history', '历史', '6'],
    ['sports', '游体', '7'],
    ['scifi', '科幻', '8'],
    ['horror', '恐怖', '9'],
    ['dimension', '次元', '10'],
    ['female', '女生', '11'],
]);
export class DouyinXiaoshuoSource {
    context;
    #cache;
    constructor(context) {
        this.context = context;
        this.#cache = new BoundedTextCache(context.cacheDir);
    }
    async search(query) {
        const normalized = clean(query);
        if (normalized === null)
            return Object.freeze([]);
        const url = new URL('/search/', origin);
        const html = await this.#fetchHtml(url, {
            method: 'POST',
            headers: {
                accept: 'text/html',
                'content-type': 'application/x-www-form-urlencoded',
                referer: `${origin}/`,
                'x-requested-with': 'XMLHttpRequest',
            },
            body: `searchkey=${escapeFormDelimiter(normalized)}`,
        });
        return this.#parseListing(html, url, null).items;
    }
    async discover(categoryId, page) {
        const category = categories.find(([id]) => id === categoryId);
        if (category === undefined)
            throw new Error('Unknown category.');
        const categoryNumber = category[2];
        const path = categoryNumber === '0'
            ? page === 1
                ? '/fenlei/'
                : `/fenlei/${page}/`
            : `/fenlei/${categoryNumber}/${page}/`;
        const url = new URL(path, origin);
        const html = await this.#cache.getOrFetchText(url, listingPolicy, () => this.#fetchHtml(url));
        return this.#hydrateMissingCovers(this.#parseListing(html, url, categoryNumber === '0' ? null : category[1]));
    }
    async getDetail(id) {
        const url = decodeOpaqueId(id, 'book');
        const html = await this.#cache.getOrFetchText(url, detailPolicy, () => this.#fetchHtml(url));
        const $ = cheerio.load(html);
        const title = metadata($, 'og:title') ??
            clean($('.channelHeader .title').first().text());
        if (title === null)
            throw new Error('Detail title is missing.');
        const author = metadata($, 'og:novel:author') ??
            stripLabel($('.synopsisArea_detail .author').first().text(), '作者');
        const category = metadata($, 'og:novel:category') ??
            stripLabel($('.synopsisArea_detail .sort').first().text(), '类别');
        const statusText = metadata($, 'og:novel:status') ??
            stripLabel($('.synopsisArea_detail p').eq(1).text(), '状态');
        const status = statusFrom(statusText);
        const description = clean($('.synopsisArea .review').first().text());
        const latest = metadata($, 'og:novel:latest_chapter_name');
        const coverRaw = metadata($, 'og:image') ??
            clean($('.synopsisArea_detail img').first().attr('src'));
        const updateTime = metadata($, 'og:novel:update_time');
        const coverUrl = coverRaw === null ? null : this.#proxyImage(new URL(coverRaw, url), url);
        const attributes = updateTime === null
            ? Object.freeze([])
            : Object.freeze([
                Object.freeze({
                    key: 'source_update_time',
                    label: '更新时间',
                    value: updateTime,
                }),
            ]);
        return Object.freeze({
            ...summary(url, title, author, coverUrl, description, latest, category === null ? [] : [category], status),
            aliases: Object.freeze([]),
            catalogUrl: url.toString(),
            attributes,
        });
    }
    async getChapters(id) {
        const bookUrl = decodeOpaqueId(id, 'book');
        const firstHtml = await this.#cache.getOrFetchText(bookUrl, catalogPolicy, () => this.#fetchHtml(bookUrl));
        const catalogUrls = catalogPageUrls(firstHtml, bookUrl).slice(0, 200);
        const htmlPages = [firstHtml];
        const remaining = catalogUrls.filter((url) => url.toString() !== bookUrl.toString());
        for (let offset = 0; offset < remaining.length; offset += 8) {
            const batch = remaining.slice(offset, offset + 8);
            htmlPages.push(...(await Promise.all(batch.map((url) => this.#cache.getOrFetchText(url, catalogPolicy, () => this.#fetchHtml(url))))));
        }
        const seen = new Set();
        const items = [];
        for (const html of htmlPages) {
            const $ = cheerio.load(html);
            $('.directoryArea a[href]').each((_, element) => {
                const href = $(element).attr('href');
                const title = clean($(element).text());
                if (href === undefined || title === null)
                    return;
                const chapterUrl = normalizeChapterUrl(new URL(href, bookUrl));
                if (!isChapterUrl(chapterUrl) ||
                    seen.has(chapterUrl.toString())) {
                    return;
                }
                seen.add(chapterUrl.toString());
                items.push({
                    id: `chapter:${opaqueToken(chapterUrl)}`,
                    title,
                    order: items.length,
                    url: chapterUrl.toString(),
                    volumeTitle: null,
                    wordCount: null,
                    updatedAt: null,
                    isLocked: false,
                    attributes: Object.freeze([]),
                });
            });
        }
        if (items.length === 0)
            throw new Error('Catalog is empty.');
        return Object.freeze({ items: Object.freeze(items) });
    }
    async getContent(id, chapterId) {
        const bookUrl = decodeOpaqueId(id, 'book');
        const firstUrl = normalizeChapterUrl(decodeOpaqueId(chapterId, 'chapter'));
        const bookId = /^\/bqg\/(\d+)\/$/u.exec(bookUrl.pathname)?.[1];
        const chapterBookId = /^\/bqg\/(\d+)\//u.exec(firstUrl.pathname)?.[1];
        if (bookId === undefined || chapterBookId !== bookId) {
            throw new Error('Chapter does not belong to the requested book.');
        }
        const firstHtml = await this.#fetchHtml(firstUrl);
        const pageCount = chapterPageCount(firstHtml);
        const htmlPages = [firstHtml];
        if (pageCount > 1) {
            const urls = Array.from({ length: pageCount - 1 }, (_, index) => chapterPageUrl(firstUrl, index + 2));
            htmlPages.push(...(await Promise.all(urls.map((url) => this.#fetchHtml(url)))));
        }
        const text = htmlPages
            .map(parseChapterText)
            .filter((value) => value !== '')
            .join('\n\n');
        if (text === '')
            throw new Error('Chapter text is empty.');
        return Object.freeze({
            chapterId,
            contentKind: 'novel',
            title: null,
            updatedAt: null,
            text,
            pages: Object.freeze([]),
        });
    }
    #parseListing(html, baseUrl, fallbackCategory) {
        const $ = cheerio.load(html);
        const seen = new Set();
        const items = [];
        $('.bookbox,.recommend .hot_sale').each((_, element) => {
            const root = $(element);
            let link = root.find('h4 a').first();
            if (link.length === 0)
                link = root.find('.bookname a').first();
            if (link.length === 0) {
                link = root
                    .find('a[href*="/bqg/"]')
                    .filter((_, candidate) => clean($(candidate).text()) !== null)
                    .first();
            }
            if (link.length === 0) {
                link = root.find('a[href*="/bqg/"]').first();
            }
            const href = link.attr('href');
            const title = clean(root.find('.title').first().text()) ??
                clean(link.text()) ??
                clean(root.find('h4').first().text());
            if (href === undefined || title === null)
                return;
            const bookUrl = normalizeBookUrl(new URL(href, baseUrl));
            if (!isBookUrl(bookUrl) || seen.has(bookUrl.toString()))
                return;
            seen.add(bookUrl.toString());
            const authorElements = root.find('.author');
            const author = stripLabel(authorElements.first().text(), '作者');
            const parsedCategory = stripLabel(authorElements.eq(1).text(), '类型');
            const latest = clean(root.find('.update a').first().text());
            const description = clean(root.find('.review').first().text());
            const coverRaw = root.find('.bookimg img').first().attr('src') ??
                root.find('img').first().attr('src');
            const coverUrl = coverRaw === undefined
                ? null
                : this.#proxyImage(new URL(coverRaw, baseUrl), baseUrl);
            const category = parsedCategory ?? fallbackCategory;
            items.push(summary(bookUrl, title, author, coverUrl, description, latest, category === null ? [] : [category], 'unknown'));
        });
        const hasNext = $('a')
            .toArray()
            .some((element) => clean($(element).text()) === '下一页');
        return Object.freeze({ items: Object.freeze(items), hasNext });
    }
    async #hydrateMissingCovers(listing) {
        const items = [];
        for (let offset = 0; offset < listing.items.length; offset += 4) {
            const batch = listing.items.slice(offset, offset + 4);
            items.push(...(await Promise.all(batch.map(async (item) => {
                if (item.coverUrl !== null)
                    return item;
                try {
                    const detail = await this.getDetail(item.id);
                    return detail.coverUrl === null
                        ? item
                        : Object.freeze({ ...item, coverUrl: detail.coverUrl });
                }
                catch {
                    return item;
                }
            }))));
        }
        return Object.freeze({
            items: Object.freeze(items),
            hasNext: listing.hasNext,
        });
    }
    async #fetchHtml(url, init) {
        if (url.origin !== origin)
            throw new Error('Source URL is invalid.');
        const response = await this.context.http.fetch(url, init ?? { headers: { accept: 'text/html', referer: `${origin}/` } });
        if (!response.ok)
            throw new Error('Source request failed.');
        const body = await response.text();
        if (body === '' || isChallenge(body)) {
            throw new Error('Source response is unavailable.');
        }
        return body;
    }
    #proxyImage(url, referer) {
        if (url.protocol !== 'https:' || !imageHosts.has(url.hostname))
            return null;
        return this.context.resource.proxy({
            kind: 'image',
            url: url.toString(),
            headers: { Accept: 'image/*', Referer: new URL('/', referer).toString() },
        });
    }
}
function summary(url, title, author, coverUrl, description, latest, categoryValues, status) {
    return Object.freeze({
        id: `book:${opaqueToken(url)}`,
        title,
        contentKind: 'novel',
        author,
        url: url.toString(),
        coverUrl,
        description,
        language: 'zh-CN',
        status,
        access: 'free',
        wordCount: null,
        chapterCount: null,
        publishedAt: null,
        updatedAt: null,
        latestChapter: latest === null
            ? null
            : Object.freeze({
                id: null,
                title: latest,
                url: null,
                updatedAt: null,
            }),
        categories: Object.freeze(categoryValues),
        tags: Object.freeze([]),
        attributes: Object.freeze([]),
    });
}
function normalizeBookUrl(url) {
    const match = /^\/bqg\/(\d+)(?:_\d+)?\/?$/u.exec(url.pathname);
    return match?.[1] === undefined
        ? url
        : new URL(`/bqg/${match[1]}/`, origin);
}
function normalizeChapterUrl(url) {
    const match = /^\/bqg\/(\d+)\/(\d+)(?:_\d+)?\.html$/u.exec(url.pathname);
    return match?.[1] === undefined || match[2] === undefined
        ? url
        : new URL(`/bqg/${match[1]}/${match[2]}.html`, origin);
}
function catalogPageUrls(html, bookUrl) {
    const bookId = /^\/bqg\/(\d+)\/$/u.exec(bookUrl.pathname)?.[1];
    if (bookId === undefined)
        throw new Error('Book URL is invalid.');
    const $ = cheerio.load(html);
    const unique = new Map([[1, bookUrl]]);
    $('option[value]').each((_, element) => {
        const value = $(element).attr('value');
        if (value === undefined)
            return;
        const candidate = new URL(value, bookUrl);
        const match = new RegExp(`^/bqg/${bookId}(?:_(\\d+))?/$`, 'u').exec(candidate.pathname);
        const page = Number(match?.[1] ?? (match === null ? Number.NaN : 1));
        if (candidate.origin === origin &&
            Number.isSafeInteger(page) &&
            page >= 1) {
            unique.set(page, candidate);
        }
    });
    return Object.freeze([...unique.entries()]
        .sort(([left], [right]) => left - right)
        .map(([, url]) => url));
}
function chapterPageCount(html) {
    const parsed = Number(/\((\d+)\s*\/\s*(\d+)\)/u.exec(html)?.[2] ?? '1');
    return Number.isSafeInteger(parsed) && parsed > 1
        ? Math.min(parsed, 15)
        : 1;
}
function chapterPageUrl(firstUrl, page) {
    return new URL(firstUrl.pathname.replace(/\.html$/u, `_${page}.html`), origin);
}
function parseChapterText(html) {
    const $ = cheerio.load(html);
    const lines = [];
    $('#chaptercontent p').each((_, element) => {
        const line = clean($(element).text());
        if (line !== null &&
            !/(?:加入书签|章节报错|本章未完|点击下一页)/u.test(line)) {
            lines.push(line);
        }
    });
    return lines.join('\n\n');
}
function metadata($, property) {
    return clean($(`meta[property="${property}"]`).first().attr('content'));
}
function stripLabel(value, label) {
    const normalized = clean(value);
    if (normalized === null)
        return null;
    return clean(normalized
        .replace(new RegExp(`^${label}[：:]\\s*`, 'u'), '')
        .replace(/\s*\([^)]*\)\s*$/u, ''));
}
function statusFrom(value) {
    if (value?.includes('完结') === true)
        return 'completed';
    if (value?.includes('连载') === true)
        return 'ongoing';
    return 'unknown';
}
function opaqueToken(url) {
    return Buffer.from(`${url.pathname}${url.search}`, 'utf8').toString('base64url');
}
function decodeOpaqueId(value, prefix) {
    const token = new RegExp(`^${prefix}:([A-Za-z0-9_-]+)$`, 'u').exec(value)?.[1];
    if (token === undefined)
        throw new Error('Opaque ID is invalid.');
    const url = new URL(Buffer.from(token, 'base64url').toString('utf8'), origin);
    if (prefix === 'book' ? !isBookUrl(url) : !isChapterUrl(url)) {
        throw new Error('Opaque ID is invalid.');
    }
    return url;
}
function isBookUrl(url) {
    return url.origin === origin && /^\/bqg\/\d+\/$/u.test(url.pathname);
}
function isChapterUrl(url) {
    return (url.origin === origin &&
        /^\/bqg\/\d+\/\d+(?:_\d+)?\.html$/u.test(url.pathname));
}
function clean(value) {
    const normalized = value?.replace(/[\u00a0\u3000]/gu, ' ').replace(/\s+/gu, ' ').trim() ?? '';
    return normalized === '' ? null : normalized;
}
function escapeFormDelimiter(value) {
    return value.replace(/[%&+=\r\n]/gu, (character) => encodeURIComponent(character));
}
function isChallenge(body) {
    return /(?:cf-challenge|cf-turnstile|Just a moment|Checking your browser|challenge-platform)/iu.test(body);
}
