/**
 * ComicBox 污污漫画原生数据源。
 *
 * 职责：通过 Runtime Node HTTP 解析 ComicBox 列表、详情、目录和章节图片。
 * 生命周期：activate 只保存 Runtime 上下文；来源不创建浏览器页面、监听端口或保存会话。
 * IO：HTML 和图片分片均走 ctx.http/resource.proxy；Runtime 数据面负责 BMI 图片解码。
 * 稳定标识：作品与章节使用站内路径的 base64url 编码，不包含域名、查询版本或会话状态。
 */
import { load } from 'cheerio';
const base = 'https://www.comicbox.xyz';
const sourceUserAgent = 'Mozilla/5.0 MgRead';
const headers = { 'User-Agent': sourceUserAgent };
const channels = ['热门', '全部', 'Fate', '东方', '原神', '汉化', '日漫', '韩漫', '单行本', '长篇', '短篇'];
const bmiHosts = new Set(['bmigmi-global-wuwu.ccavbox.com']);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) {
    if (request.cursor !== null)
        throw new Error('Cursor is invalid.');
    const query = request.query.trim();
    if (!query)
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const values = parseCards(await text(`${base}/search?keyword=${encodeURIComponent(query)}`), '.sp-search-card');
    const items = values.map(summary).slice(0, clamp(request.pageSize));
    return frozen({ items, nextCursor: null, totalCount: items.length });
}
export async function searchSuggestions(_request) {
    return frozen({ items: [], nextCursor: null });
}
export async function discover(request) {
    if (request.target === null)
        return frozen({
            kind: 'document',
            document: { components: [{
                        type: 'section', id: 'comicbox-channels', title: '污污漫画', subtitle: 'ComicBox 分类', icon: 'manga',
                        children: [{ type: 'categoryCollection', id: 'comicbox-channel-list', layout: 'chips', categories: channels.map((title, index) => ({
                                    id: String(index), title, target: `channel:${index}`, count: null, url: null, icon: 'manga',
                                })) }],
                    }] },
        });
    const index = Number(request.target.replace(/^channel:/u, ''));
    const title = channels[index];
    if (!Number.isSafeInteger(index) || title === undefined)
        throw new Error('Discovery target is invalid.');
    const page = cursorPage(request.cursor, request.target);
    const size = clamp(request.pageSize);
    const url = title === '热门'
        ? `${base}/index`
        : `${base}/booklist?tag=${encodeURIComponent(title)}&area=-1&end=-1&page=${page}`;
    const values = parseCards(await text(url), title === '热门' ? '.sp-bcarousel-item, .sp-booklist-card' : '.sp-booklist-card');
    const contents = values.map(summary).slice(0, size);
    const collectionId = `comicbox:${index}`;
    const items = contents.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
    const continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${index}:${page + 1}` }) : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId, items, continuation });
    }
    return frozen({ kind: 'document', document: { components: [{
                    type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'manga',
                    children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }],
                }] } });
}
export async function getDetail(request) {
    const path = contentPath(request.id);
    const $ = load(await text(new URL(path, base).toString()));
    const title = clean($('.sp-book-title, h1').first().text()) || stripSiteSuffix(clean($('meta[property="og:title"]').attr('content') ?? ''));
    const cover = firstImage($, '.sp-book-cover') ?? $('meta[property="og:image"]').attr('content') ?? '';
    const description = clean($('.sp-book-summary').first().text()) || clean($('meta[property="og:description"]').attr('content') ?? '');
    const tags = $('.sp-book-tag').toArray().map((node) => clean($(node).text())).filter(Boolean);
    const chapters = chapterNodes($);
    const item = summary({ path, title: title || path, cover, description });
    return frozen({ ...item, categories: tags, tags, chapterCount: chapters.length,
        latestChapter: chapters.length ? { id: chapterId(path, chapters.at(-1)?.path ?? ''), title: chapters.at(-1)?.title ?? '', url: null, updatedAt: null } : null,
        aliases: [], catalogUrl: new URL(path, base).toString() });
}
export async function getChapters(request) {
    const path = contentPath(request.id);
    const $ = load(await text(new URL(path, base).toString()));
    const chapters = chapterNodes($);
    const items = chapters.map((chapter, index) => frozen({ id: chapterId(path, chapter.path), title: chapter.title, order: index,
        url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] }));
    return frozen({ items, groups: [] });
}
export async function getContent(request) {
    const book = contentPath(request.id);
    const path = chapterPath(request.chapterId, book);
    const pageUrl = new URL(path, base).toString();
    const $ = load(await text(pageUrl));
    const seen = new Set();
    const values = [];
    $('.comiclist .comicpage div[data-bmi-manifest][data-src], .comiclist .comicpage img, .comicpage div[data-bmi-manifest][data-src], .comicpage img').toArray().forEach((node) => {
        const image = $(node);
        const raw = image.attr('data-src') ?? image.attr('data-original') ?? image.attr('src') ?? '';
        if (!safeUrl(raw, pageUrl))
            return;
        const url = new URL(raw, pageUrl).toString();
        if (seen.has(url))
            return;
        seen.add(url);
        values.push(url);
    });
    if (!values.length)
        throw new Error('Chapter images are unavailable.');
    const title = clean($('.sp-reader-title').first().text()) || null;
    const pages = values.map((url, index) => frozen({ id: `page:${encode(path)}:${index + 1}`, index, url: imageProxy(url, pageUrl),
        resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: imageMime(url), width: null, height: null }));
    return frozen({ chapterId: request.chapterId, contentKind: 'manga', title, updatedAt: null, text: null, pages: Object.freeze(pages) });
}
async function text(url) {
    const response = await requireContext().http.fetch(url, { headers });
    if (!response.ok)
        throw new Error('Source request failed.');
    return response.text();
}
function parseCards(source, selector) {
    const $ = load(source);
    const result = new Map();
    for (const node of $(selector).toArray()) {
        const card = $(node);
        const href = card.attr('href') ?? card.find('a[href*="/book/"]').first().attr('href') ?? '';
        if (!href.includes('/book/'))
            continue;
        const path = new URL(href, base).pathname;
        const title = clean(card.attr('title') ?? card.find('.sp-search-card-title,.sp-booklist-title,.sp-bcarousel-label').first().text());
        if (!title)
            continue;
        const cover = card.find('[data-src], [data-original], img[src]').first().attr('data-src') ??
            card.find('[data-src], [data-original], img[src]').first().attr('data-original') ??
            card.find('[data-src], [data-original], img[src]').first().attr('src') ?? '';
        const description = clean(card.find('.sp-search-card-desc,.sp-booklist-desc').first().text());
        result.set(path, { path, title, cover, description });
    }
    return [...result.values()];
}
function chapterNodes($) {
    const result = new Map();
    for (const node of $('.sp-chapter-grid a.sp-chapter-item, a.sp-chapter-item').toArray()) {
        const link = $(node);
        const href = link.attr('href') ?? '';
        const title = clean(link.attr('title') ?? link.text());
        if (!href || !title)
            continue;
        result.set(new URL(href, base).pathname, { path: new URL(href, base).pathname, title });
    }
    return [...result.values()];
}
function firstImage($, scope) {
    const image = $(scope).find('[data-src], [data-original], img[src]').first();
    return image.attr('data-src') ?? image.attr('data-original') ?? image.attr('src') ?? null;
}
function summary(value) {
    return frozen({ id: `manga:${encode(value.path)}`, title: value.title, contentKind: 'manga', coverOrientation: 'portrait',
        author: null, url: new URL(value.path, base).toString(), coverUrl: imageProxy(value.cover, `${base}/`), description: value.description || null,
        language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null,
        updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] });
}
function imageProxy(value, referer) {
    if (!value)
        return null;
    let url;
    try {
        url = new URL(value, base);
    }
    catch {
        return null;
    }
    const request = requireContext().resource.proxy;
    const common = { kind: 'image', headers: { Accept: 'image/*', Referer: referer, 'User-Agent': sourceUserAgent } };
    if (!bmiHosts.has(url.hostname))
        return request({ ...common, url: url.toString() });
    const urls = splitImageUrls(url);
    const first = urls[0];
    if (first === undefined)
        return null;
    return request({ ...common, url: first, urls, resourceTransform: 'aes-cbc-split-image-v1' });
}
function splitImageUrls(source) {
    const path = source.pathname.replace(/\/break[^/]+(?=\/)/u, '');
    const match = /\.(jpeg|jpg|png|gif|avif|webp)$/iu.exec(path);
    if (!match)
        return [];
    const prefix = `/break_2${path.slice(0, match.index)}`;
    return [0, 1].map((index) => `https://${source.hostname}${prefix}.b_${index}`);
}
function contentPath(id) {
    const value = /^manga:([A-Za-z0-9_-]+)$/u.exec(id)?.[1];
    const path = value ? decode(value) : '';
    if (!path.startsWith('/book/'))
        throw new Error('Content ID is invalid.');
    return path;
}
function chapterId(book, path) { return `manga:${encode(book)}:chapter:${encode(path)}`; }
function chapterPath(id, book) {
    const value = new RegExp(`^manga:${encode(book)}:chapter:([A-Za-z0-9_-]+)$`, 'u').exec(id)?.[1];
    const path = value ? decode(value) : '';
    if (!path.startsWith('/'))
        throw new Error('Chapter ID is invalid.');
    return path;
}
function imageMime(value) {
    const path = new URL(value).pathname.toLowerCase();
    if (path.endsWith('.png'))
        return 'image/png';
    if (path.endsWith('.webp'))
        return 'image/webp';
    if (path.endsWith('.gif'))
        return 'image/gif';
    if (path.endsWith('.avif'))
        return 'image/avif';
    return 'image/jpeg';
}
function safeUrl(value, relativeTo) {
    try {
        return ['http:', 'https:'].includes(new URL(value, relativeTo).protocol);
    }
    catch {
        return false;
    }
}
function stripSiteSuffix(value) { return value.replace(/\s+-\s+污污漫畫$/u, '').trim(); }
function encode(value) { return Buffer.from(value).toString('base64url'); }
function decode(value) { return Buffer.from(value, 'base64url').toString('utf8'); }
function cursorPage(cursor, target) {
    if (cursor === null)
        return 1;
    const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '');
    if (!Number.isSafeInteger(page) || page < 2)
        throw new Error('Cursor is invalid.');
    return page;
}
function clean(value) { return value.replaceAll(/\s+/gu, ' ').trim(); }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
