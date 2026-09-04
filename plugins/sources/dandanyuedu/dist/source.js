/**
 * Minimal QQ Reading JSON API and pin.qq.com category implementation.
 *
 * Runtime owns HTTP and cover proxy transport. The required anonymous Q-GUID is generated per
 * activation and is not an account, Cookie or signature.
 */
import { Buffer } from 'node:buffer';
import { randomUUID } from 'node:crypto';
import * as cheerio from 'cheerio/slim';
import { BoundedTextCache } from './cache.js';
const searchEndpoint = 'https://newopensearch.reader.qq.com/wechat';
const detailEndpoint = 'https://bookshelf.html5.qq.com/qbread/api/novel/intro-info';
const catalogEndpoint = 'https://bookshelf.html5.qq.com/qbread/api/book/all-chapter';
const contentEndpoint = 'https://novel.html5.qq.com/be-api/content/ads-read';
const bookshelfReferer = 'https://bookshelf.html5.qq.com/';
const pinOrigin = 'https://pin.qq.com';
const coverOrigin = 'https://wfqqreader-1252317822.image.myqcloud.com';
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
const maximumCatalogBytes = 2 * 1024 * 1024;
export const categories = Object.freeze([
    ['ancient-romance', '古言', '30013'],
    ['modern-romance', '现言', '30020'],
    ['fantasy-romance', '幻情', '30001'],
    ['cultivation', '仙侠', '30008'],
    ['youth', '青春', '30031'],
    ['game', '游戏', '30050'],
    ['science-fiction', '科幻', '30042'],
    ['mystery', '悬疑', '30036'],
    ['light-novel', '轻小说', '30055'],
    ['short-story', '短篇', '30083'],
    ['reality', '现实', '30120'],
]);
export class DandanYueduSource {
    context;
    #cache;
    #anonymousGuid = randomUUID().replaceAll('-', '');
    constructor(context) {
        this.context = context;
        this.#cache = new BoundedTextCache(context.cacheDir);
    }
    async search(query, start, limit) {
        const normalized = clean(query);
        if (normalized === null || limit < 1) {
            return Object.freeze({ items: Object.freeze([]), nextStart: null });
        }
        const url = new URL(searchEndpoint);
        url.searchParams.set('keyword', normalized);
        url.searchParams.set('start', String(start));
        url.searchParams.set('end', String(start + limit - 1));
        const payload = parseObject(await this.#cache.getOrFetchText(url, listingPolicy, () => this.#fetchText(url, bookshelfReferer)));
        if (readNumber(payload.code) !== 0) {
            throw new Error('Search response is unavailable.');
        }
        const items = Object.freeze(readArray(payload.booklist).flatMap((value) => {
            const item = object(value);
            const title = readText(item?.title);
            const shortId = readDigits(item?.bid);
            if (title === null || shortId === null)
                return [];
            const bookId = normalizeSearchBookId(shortId);
            const tags = splitTags(readText(item?.tag));
            return [
                summary({
                    bookId,
                    title,
                    author: readText(item?.author),
                    coverUrl: this.#proxyCover(buildCoverUrl(shortId), bookshelfReferer),
                    description: readText(item?.intro),
                    status: 'unknown',
                    access: 'unknown',
                    wordCount: readCount(item?.totalWords),
                    chapterCount: null,
                    updatedAt: null,
                    latestChapter: null,
                    categories: tags,
                    tags,
                }),
            ];
        }));
        const nextStart = readCount(payload.nextstart);
        return Object.freeze({
            items,
            nextStart: items.length === 0 || nextStart === null || nextStart <= start
                ? null
                : nextStart,
        });
    }
    async discover(categoryId, page) {
        const category = categories.find(([id]) => id === categoryId);
        if (category === undefined)
            throw new Error('Unknown category.');
        const url = new URL(`/cate/${category[2]}_${page}`, pinOrigin);
        const html = await this.#cache.getOrFetchText(url, listingPolicy, () => this.#fetchText(url, `${pinOrigin}/`));
        const $ = cheerio.load(html);
        const seen = new Set();
        const items = [];
        $('.book-simple,.book-vertical').each((_, element) => {
            const root = $(element);
            let bookId = null;
            const hrefs = root
                .find('a[href*="/detail/"]')
                .toArray()
                .flatMap((link) => $(link).attr('href') ?? []);
            const parentHref = root.closest('a[href*="/detail/"]').attr('href');
            if (parentHref !== undefined)
                hrefs.push(parentHref);
            for (const href of hrefs) {
                if (bookId !== null)
                    break;
                bookId = /^\/detail\/(\d+)\/?$/u.exec(new URL(href, url).pathname)?.[1] ?? null;
            }
            const title = clean(root.find('.book-title').first().text());
            if (bookId === null || title === null || seen.has(bookId))
                return;
            seen.add(bookId);
            const coverStyle = root.find('.cover').first().attr('style');
            const cover = coverFromStyle(coverStyle);
            items.push(summary({
                bookId,
                title,
                author: clean(root.find('.author').first().text()),
                coverUrl: cover === null
                    ? null
                    : this.#proxyCover(cover, url.toString()),
                description: null,
                status: 'unknown',
                access: 'unknown',
                wordCount: null,
                chapterCount: null,
                updatedAt: null,
                latestChapter: null,
                categories: [category[1]],
                tags: Object.freeze([]),
            }));
        });
        return Object.freeze({
            items: Object.freeze(items),
            hasNext: items.length === 20,
        });
    }
    async getDetail(id) {
        const bookId = parseBookId(id);
        const url = detailUrl(bookId);
        const payload = parseObject(await this.#cache.getOrFetchText(url, detailPolicy, () => this.#fetchText(url, bookshelfReferer)));
        if (readNumber(payload.ret) !== 0) {
            throw new Error('Detail response is unavailable.');
        }
        const info = object(object(payload.data)?.bookInfo);
        if (info === undefined || readDigits(info.resourceID) !== bookId) {
            throw new Error('Detail response is invalid.');
        }
        const title = readText(info.resourceName);
        if (title === null)
            throw new Error('Detail title is missing.');
        const tags = splitTags(readText(info.tag));
        const updatedAt = unixSeconds(readCount(info.lastSerialUpdateTime));
        const latestId = readDigits(info.lastSerialid);
        const latestTitle = readText(info.lastSerialname);
        const cover = readCoverUrl(readText(info.picurl));
        const current = summary({
            bookId,
            title,
            author: readText(info.author),
            coverUrl: cover === null
                ? null
                : this.#proxyCover(cover, bookshelfReferer),
            description: readText(info.summary),
            status: typeof info.isfinish === 'boolean'
                ? info.isfinish
                    ? 'completed'
                    : 'ongoing'
                : 'unknown',
            access: info.isCharge === true ? 'mixed' : 'free',
            wordCount: readCount(info.contentsize),
            chapterCount: readCount(info.serialnum),
            updatedAt,
            latestChapter: latestId === null || latestTitle === null
                ? null
                : Object.freeze({
                    id: chapterContentId(bookId, latestId),
                    title: latestTitle,
                    url: null,
                    updatedAt,
                }),
            categories: tags,
            tags,
        });
        return Object.freeze({
            ...current,
            aliases: Object.freeze([]),
            catalogUrl: catalogUrl(bookId).toString(),
        });
    }
    async getChapters(id) {
        const bookId = parseBookId(id);
        const url = catalogUrl(bookId);
        const payload = parseObject(await this.#cache.getOrFetchText(url, detailPolicy, () => this.#fetchText(url, bookshelfReferer)));
        if (readNumber(payload.ret) !== 0 || readDigits(payload.bookId) !== bookId) {
            throw new Error('Catalog response is invalid.');
        }
        const rows = readArray(payload.rows);
        if (rows.length === 0)
            throw new Error('Catalog is empty.');
        if (rows.length > 5000)
            throw new Error('Catalog exceeds the supported item limit.');
        const seen = new Set();
        const items = Object.freeze(rows.flatMap((value, order) => {
            const row = object(value);
            const serialId = readDigits(row?.serialID);
            const title = readText(row?.serialName);
            if (serialId === null ||
                title === null ||
                seen.has(serialId)) {
                return [];
            }
            seen.add(serialId);
            return [
                Object.freeze({
                    id: chapterContentId(bookId, serialId),
                    title,
                    order,
                    url: null,
                    volumeTitle: null,
                    wordCount: null,
                    updatedAt: null,
                    isLocked: typeof row?.isFree === 'boolean' ? !row.isFree : null,
                    attributes: Object.freeze([]),
                }),
            ];
        }));
        if (Buffer.byteLength(JSON.stringify({ items }), 'utf8') > maximumCatalogBytes) {
            throw new Error('Catalog exceeds the supported byte limit.');
        }
        return Object.freeze({ items });
    }
    async getContent(id, chapterId) {
        const bookId = parseBookId(id);
        const parsedChapter = parseChapterContentId(chapterId);
        if (parsedChapter.bookId !== bookId) {
            throw new Error('Chapter does not belong to the requested book.');
        }
        const response = await this.context.http.fetch(contentEndpoint, {
            method: 'POST',
            headers: {
                accept: 'application/json, text/plain, */*',
                'content-type': 'application/json',
                referer: bookshelfReferer,
                'q-guid': this.#anonymousGuid,
            },
            body: JSON.stringify({
                Scene: 'chapter',
                ContentAnchorBatch: [
                    {
                        BookID: bookId,
                        ChapterSeqNo: [Number(parsedChapter.serialId)],
                    },
                ],
            }),
        });
        if (!response.ok)
            throw new Error('Chapter response is unavailable.');
        const payload = object((await response.json()));
        if (payload === undefined || readNumber(payload.ret) !== 0) {
            throw new Error('Chapter response is invalid.');
        }
        const first = object(readArray(object(payload.data)?.Content)[0]);
        const rawContent = first?.Content;
        const value = Array.isArray(rawContent) ? rawContent[0] : rawContent;
        const text = typeof value === 'string' ? value.replace(/\r\n?/gu, '\n').trim() : '';
        if (text === '')
            throw new Error('Chapter text is unavailable.');
        return Object.freeze({
            chapterId,
            contentKind: 'novel',
            title: null,
            updatedAt: null,
            text,
            pages: Object.freeze([]),
        });
    }
    async #fetchText(url, referer) {
        const allowed = new Set([
            new URL(searchEndpoint).origin,
            new URL(detailEndpoint).origin,
            pinOrigin,
        ]);
        if (!allowed.has(url.origin))
            throw new Error('Source URL is invalid.');
        const response = await this.context.http.fetch(url, {
            headers: { accept: 'application/json, text/plain, */*', referer },
        });
        if (!response.ok)
            throw new Error('Source response is unavailable.');
        return response.text();
    }
    #proxyCover(url, referer) {
        const cover = readCoverUrl(url.toString());
        const page = readCoverReferer(referer);
        if (cover === null || page === null)
            throw new Error('Cover request is invalid.');
        return this.context.resource.proxy({
            kind: 'qq-cover',
            url: cover.toString(),
            headers: { Accept: 'image/*', Referer: page.toString() },
        });
    }
}
function summary(input) {
    return Object.freeze({
        id: contentId(input.bookId),
        title: input.title,
        contentKind: 'novel',
        author: input.author,
        url: new URL(`/detail/${input.bookId}`, pinOrigin).toString(),
        coverUrl: input.coverUrl,
        description: input.description,
        language: 'zh-CN',
        status: input.status,
        access: input.access,
        wordCount: input.wordCount,
        chapterCount: input.chapterCount,
        publishedAt: null,
        updatedAt: input.updatedAt,
        latestChapter: input.latestChapter,
        categories: Object.freeze(input.categories),
        tags: Object.freeze(input.tags),
        attributes: Object.freeze([]),
    });
}
function contentId(bookId) {
    return `qqbook:${bookId}`;
}
function parseBookId(value) {
    const bookId = /^qqbook:(\d{9,12})$/u.exec(value)?.[1];
    if (bookId === undefined)
        throw new Error('Content ID is invalid.');
    return bookId;
}
function chapterContentId(bookId, serialId) {
    return `chapter:${bookId}:${serialId}`;
}
function parseChapterContentId(value) {
    const match = /^chapter:(\d{9,12}):(\d+)$/u.exec(value);
    if (match?.[1] === undefined || match[2] === undefined) {
        throw new Error('Chapter ID is invalid.');
    }
    return Object.freeze({ bookId: match[1], serialId: match[2] });
}
function normalizeSearchBookId(shortId) {
    const numeric = Number(shortId);
    if (!Number.isSafeInteger(numeric) || numeric < 0) {
        throw new Error('Search book ID is invalid.');
    }
    return String(numeric < 1_000_000_000 ? numeric + 1_100_000_000 : numeric);
}
function buildCoverUrl(shortId) {
    const lastThree = Number(shortId.slice(-3));
    const segment = lastThree < 10
        ? shortId.slice(-1)
        : lastThree < 100
            ? shortId.slice(-2)
            : shortId.slice(-3);
    return new URL(`/cover/${segment}/${shortId}/b_${shortId}.jpg`, coverOrigin);
}
function detailUrl(bookId) {
    const url = new URL(detailEndpoint);
    url.searchParams.set('bookid', bookId);
    return url;
}
function catalogUrl(bookId) {
    const url = new URL(catalogEndpoint);
    url.searchParams.set('bookId', bookId);
    return url;
}
function coverFromStyle(style) {
    const raw = /url\(["']?(?<url>https?:\/\/[^)"']+)/iu.exec(style ?? '')?.groups?.url;
    return raw === undefined ? null : readCoverUrl(raw);
}
function readCoverUrl(value) {
    if (value === null)
        return null;
    try {
        const url = new URL(value.replace(/^http:\/\//iu, 'https://'));
        return url.protocol === 'https:' && url.origin === coverOrigin ? url : null;
    }
    catch {
        return null;
    }
}
function readCoverReferer(value) {
    try {
        const url = new URL(value);
        return url.protocol === 'https:' &&
            (url.origin === pinOrigin || url.origin === new URL(bookshelfReferer).origin)
            ? url
            : null;
    }
    catch {
        return null;
    }
}
function parseObject(value) {
    try {
        const parsed = JSON.parse(value);
        const result = object(parsed);
        if (result === undefined)
            throw new Error('Source JSON is not an object.');
        return result;
    }
    catch {
        throw new Error('Source JSON is invalid.');
    }
}
function object(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value)
        ? value
        : undefined;
}
function readArray(value) {
    return Array.isArray(value) ? value : [];
}
function readText(value) {
    return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}
function readDigits(value) {
    if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) {
        return String(value);
    }
    return typeof value === 'string' && /^\d+$/u.test(value) ? value : null;
}
function readNumber(value) {
    return typeof value === 'number' && Number.isFinite(value) ? value : null;
}
function readCount(value) {
    const numeric = typeof value === 'string' ? Number(value) : value;
    return typeof numeric === 'number' &&
        Number.isSafeInteger(numeric) &&
        numeric >= 0
        ? numeric
        : null;
}
function splitTags(value) {
    if (value === null)
        return Object.freeze([]);
    return Object.freeze([...new Set(value.split(/[|,，/]/u).map((item) => item.trim()).filter(Boolean))].slice(0, 32));
}
function unixSeconds(value) {
    if (value === null || value < 1 || value > 253_402_300_799)
        return null;
    const date = new Date(value * 1000);
    return Number.isNaN(date.getTime()) ? null : date.toISOString();
}
function clean(value) {
    const normalized = value?.replace(/[\u00a0\u3000]/gu, ' ').replace(/\s+/gu, ' ').trim() ?? '';
    return normalized === '' ? null : normalized;
}
