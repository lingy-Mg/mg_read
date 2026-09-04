/**
 * 66manhua.cc public HTML parser. It reads only site pages, preserves the
 * homepage's real discovery sections, returns opaque IDs, and proxies verified
 * image hosts.
 */
import { Buffer } from 'node:buffer';
import * as cheerio from 'cheerio/slim';
const origin = 'https://66manhua.cc';
const imageOrigins = new Set([origin, 'https://mh.aikanhanman.top']);
export class ManhuaSource {
    context;
    constructor(context) {
        this.context = context;
    }
    async search(query) {
        const url = new URL('/index.php/search', origin);
        url.searchParams.set('key', query);
        return this.parseList(await this.#html(url), url);
    }
    async discover() {
        const url = new URL('/', origin);
        const $ = cheerio.load(await this.#html(url));
        const recentRoot = $('.recent-wr .in-sec-update').first();
        const featuredRoot = $('.in-fine').first();
        const risingRoot = sectionByTitle($, '上升最快');
        const completedRoot = sectionByTitle($, '完结大作');
        const rankings = [];
        $('.in-rank-box').each((_, element) => {
            const root = $(element);
            const title = clean(root.find('.head span').first().text());
            const identity = rankingIdentity(title);
            if (identity === null)
                return;
            rankings.push(Object.freeze({ id: identity.id, title: identity.title, items: this.#rankedItems($, root.find('.rank-item'), url, identity.metric) }));
        });
        return Object.freeze({
            featured: this.#cards($, featuredRoot.find('.in-fine__big, .in-comic--type-a'), url),
            recent: this.#cards($, recentRoot.find('.in-comic--type-b'), url),
            popular: this.#rankedItems($, $('.recent-wr .in-rank-box--aside .rank-item'), url, null),
            rising: this.#rankedItems($, risingRoot.find('.in-comic--type-b'), url, null),
            completed: this.#cards($, completedRoot.find('.in-comic--type-b'), url),
            rankings: Object.freeze(rankings),
        });
    }
    parseList(html, base) {
        const $ = cheerio.load(html);
        return this.#cards($, $('.common-comic-item, .in-comic--type-a, .in-comic--type-b'), base);
    }
    async detail(id) {
        const url = decodeComic(id);
        const html = await this.#html(url);
        const $ = cheerio.load(html);
        const title = clean($('.de-info__box .comic-title, h1.comic-title, .comic-detail h1').first().text()) ?? clean($('meta[property="og:title"]').attr('content'));
        if (title === null)
            throw new Error('Detail title is missing.');
        const rawCover = $('.de-info__cover img, .comic-cover img, .de-info__box img').first().attr('data-original') ?? $('.de-info__cover img, .comic-cover img, .de-info__box img').first().attr('src') ?? $('meta[property="og:image"]').attr('content');
        const author = clean($('.de-info__box .comic-author .name a, .comic-detail .comic-author').first().text());
        const description = clean($('.de-info__box .comic-intro .intro-total').first().text()) ?? clean($('.de-info__box .comic-intro .intro, .de-info__desc, .comic-detail__desc, .de-info__intro').first().text()) ?? clean($('meta[name="description"]').attr('content'));
        const categories = Object.freeze($('.de-info__box .comic-status a[href*="/index.php/category/tags/"]').map((_, element) => clean($(element).text())).get().filter((value) => value !== null));
        const chapterCount = $('.j-chapter-link[href*="/index.php/chapter/"]').length || null;
        return Object.freeze({ ...summary(url, title, this.#cover(rawCover, url), description, author), chapterCount, categories, aliases: Object.freeze([]), catalogUrl: url.toString() });
    }
    async chapters(id) {
        const comic = decodeComic(id);
        const $ = cheerio.load(await this.#html(comic));
        const items = [];
        const seen = new Set();
        $('.j-chapter-link[href*="/index.php/chapter/"]').each((_, element) => {
            const link = $(element);
            const href = link.attr('href');
            const title = clean(link.text());
            if (href === undefined || title === null)
                return;
            const url = new URL(href, comic);
            if (!isChapter(url) || seen.has(url.pathname))
                return;
            seen.add(url.pathname);
            const locked = hasAccessMarker(link.closest('.chapter__item'));
            items.push(Object.freeze({ id: encodeChapter(url), title, order: items.length, url: url.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: locked, attributes: Object.freeze([]) }));
        });
        if (items.length === 0)
            throw new Error('Catalog is empty.');
        return Object.freeze({ items: Object.freeze(items) });
    }
    async content(id, chapterId) {
        decodeComic(id);
        const chapter = decodeChapter(chapterId);
        const html = await this.#html(chapter);
        const $ = cheerio.load(html);
        const reader = $('.rd-article-wr').first();
        if (reader.length === 0 || hasAccessMarker(reader))
            throw new Error('Chapter requires public access.');
        const seen = new Set();
        const pages = [];
        reader.find('.rd-article__pic .lazy-read[data-original], .rd-article__pic img[data-original]').each((index, element) => {
            const raw = $(element).attr('data-original');
            if (raw === undefined)
                return;
            const url = new URL(raw, chapter);
            if (!isImage(url) || seen.has(url.toString()))
                return;
            seen.add(url.toString());
            pages.push(Object.freeze({ id: `image:${index + 1}`, index: pages.length, url: this.#proxyImage(url, chapter), mimeType: imageMime(url), width: null, height: null }));
        });
        if (pages.length === 0)
            throw new Error('Chapter images are unavailable or protected.');
        return Object.freeze({ chapterId, contentKind: 'manga', title: null, updatedAt: null, text: null, pages: Object.freeze(pages) });
    }
    async #html(url) {
        if (!isSite(url))
            throw new Error('Source URL is invalid.');
        const response = await this.context.http.fetch(url, { headers: { accept: 'text/html,application/xhtml+xml', referer: `${origin}/` } });
        if (!response.ok)
            throw new Error('Public page is unavailable.');
        return response.text();
    }
    #cards($, roots, base) {
        const values = [];
        const seen = new Set();
        roots.each((_, element) => {
            const value = this.#card($, $(element), base);
            if (value === null || seen.has(value.url))
                return;
            seen.add(value.url);
            values.push(value);
        });
        return Object.freeze(values);
    }
    #rankedItems($, roots, base, metricLabel) {
        const values = [];
        const seen = new Set();
        roots.each((index, element) => {
            const root = $(element);
            const content = this.#card($, root, base);
            if (content === null || seen.has(content.url))
                return;
            seen.add(content.url);
            const parsedRank = Number.parseInt(clean(root.find('.num').first().text()) ?? '', 10);
            const metricText = clean(root.find('.count').first().text());
            const metricValue = metricText?.replace(/^.*?[：:]/u, '').trim() ?? null;
            values.push(Object.freeze({
                content,
                rank: Number.isSafeInteger(parsedRank) && parsedRank > 0 ? parsedRank : index + 1,
                metric: metricLabel === null || metricValue === null ? null : Object.freeze({ label: metricLabel, value: metricValue }),
            }));
        });
        return Object.freeze(values);
    }
    #card($, root, base) {
        const link = root.find('a[href*="/index.php/comic/"]').first();
        const href = link.attr('href');
        const title = clean(root.find('.comic__title a, .comic-name a').first().text()) ?? clean(link.attr('title')) ?? clean(root.find('img').first().attr('alt'));
        if (href === undefined || title === null)
            return null;
        const url = new URL(href, base);
        if (!isComic(url))
            return null;
        const image = root.find('img').first();
        const rawCover = image.attr('data-original') ?? image.attr('data-src') ?? image.attr('src');
        const info = root.find('.in-fine__info .text');
        const authorLine = clean(info.first().text());
        const author = authorLine?.replace(/^作者[：:]\s*/u, '').trim() || null;
        const description = clean(root.find('.comic__feature, .feature').first().text()) ?? (info.length > 1 ? clean(info.last().text()) : null);
        const latestChapterTitle = clean(root.find('.cover__tag').first().text());
        return summary(url, title, this.#cover(rawCover, base), description, author, latestChapterTitle);
    }
    #cover(raw, referer) {
        if (raw === undefined || /\/bg_loadimg_[^/]+\.(?:png|webp)$/iu.test(raw))
            return null;
        try {
            const url = new URL(raw, referer);
            return isImage(url) ? this.#proxyImage(url, referer) : null;
        }
        catch {
            return null;
        }
    }
    #proxyImage(url, referer) { if (!isImage(url) || !isSite(referer))
        throw new Error('Image URL is invalid.'); return this.context.resource.proxy({ kind: 'image', url: url.toString(), headers: { Accept: 'image/*', Referer: referer.toString() } }); }
}
function summary(url, title, coverUrl, description, author = null, latestChapterTitle = null) { return Object.freeze({ id: encodeComic(url), title, contentKind: 'manga', author, url: url.toString(), coverUrl, description, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: latestChapterTitle === null ? null : Object.freeze({ id: null, title: latestChapterTitle, url: null, updatedAt: null }), categories: Object.freeze([]), tags: Object.freeze([]), attributes: Object.freeze([]) }); }
function sectionByTitle($, title) { return $('.in-sec-wr').filter((_, element) => clean($(element).find('.in-sec__head span').first().text()) === title).first(); }
function rankingIdentity(title) {
    if (title === '收藏榜')
        return Object.freeze({ id: 'favorites', title, metric: '收藏' });
    if (title === '打赏榜')
        return Object.freeze({ id: 'rewards', title, metric: '打赏' });
    if (title === '月票榜')
        return Object.freeze({ id: 'monthly-tickets', title, metric: '月票' });
    return null;
}
function token(url) { return Buffer.from(url.pathname, 'utf8').toString('base64url'); }
function encodeComic(url) { return `comic:${token(url)}`; }
function encodeChapter(url) { return `chapter:${token(url)}`; }
function decode(id, prefix) { const match = new RegExp(`^${prefix}:([A-Za-z0-9_-]+)$`, 'u').exec(id); if (match?.[1] === undefined)
    throw new Error('Opaque ID is invalid.'); const url = new URL(Buffer.from(match[1], 'base64url').toString('utf8'), origin); if (prefix === 'comic' ? !isComic(url) : !isChapter(url))
    throw new Error('Opaque ID is invalid.'); return url; }
function decodeComic(id) { return decode(id, 'comic'); }
function decodeChapter(id) { return decode(id, 'chapter'); }
function isSite(url) { return url.origin === origin && url.protocol === 'https:'; }
function isComic(url) { return isSite(url) && /^\/index\.php\/comic\/[^/?#]+\/?$/u.test(url.pathname); }
function isChapter(url) { return isSite(url) && /^\/index\.php\/chapter\/\d+\/?$/u.test(url.pathname); }
function isImage(url) { return url.protocol === 'https:' && imageOrigins.has(url.origin) && /\.(?:jpe?g|png|webp|gif)(?:$|\?)/iu.test(url.pathname + url.search); }
function imageMime(url) { const ext = /\.([a-z]+)(?:$|\?)/iu.exec(url.pathname + url.search)?.[1]?.toLowerCase(); return ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : null; }
function clean(value) { const result = value?.replace(/\s+/gu, ' ').trim() ?? ''; return result === '' ? null : result; }
function hasAccessMarker(root) { return root.is('[class*="vip" i], [class*="pay" i], [class*="lock" i]') || root.find('[class*="vip" i], [class*="pay" i], [class*="lock" i]').length > 0; }
