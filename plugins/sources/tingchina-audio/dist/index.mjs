/** Ting China audio source: JSON API projection and Runtime-owned media proxy. */
import { createHash } from 'node:crypto';
const base = 'https://app.365ting.com';
const api = `${base}/listen/Apitzg2025/`;
const appHeaders = { Accept: 'application/json,text/html,*/*', 'User-Agent': 'TingShiJie/1.8.8 (m.i275.com)' };
const audioHeaders = { Accept: '*/*', 'User-Agent': 'okhttp/4.9.3' };
const playKey = 'J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K';
const categories = Object.freeze([['popular', '热门', null], ['6', '玄幻', '6'], ['7', '奇幻', '7'], ['8', '武侠', '8'], ['13', '历史', '13'], ['14', '恐怖', '14'], ['31', '评书', '31'], ['50', '儿童', '50']]);
let context;
const chapterLocks = new Map();
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) {
    if (request.cursor !== null)
        throw new Error('Search cursor is unsupported.');
    if (request.query.trim() === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const data = await fetchJson(`${api}search?search=${encodeURIComponent(request.query)}`);
    return frozen({ items: records(data.data).slice(0, clamp(request.pageSize)).map((value) => summary(value)), nextCursor: null, totalCount: null });
}
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        return rootDocument(request.pageSize);
    }
    const category = categories.find(([id]) => request.target === `category:${id}`);
    if (category === undefined)
        throw new Error('Discovery target is invalid.');
    const page = pageFromCursor(request.cursor, request.target);
    const [id, label, upstreamCategory] = category;
    const url = upstreamCategory === null ? `${api}appHome` : `${api}appHomeByCategory?categoryId=${upstreamCategory}&page=${page}&size=${clamp(request.pageSize)}`;
    const data = await fetchJson(url);
    const values = upstreamCategory === null ? popular(data) : records(data.data).length > 0 ? records(data.data) : records(object(data.data).list);
    const collectionId = `audio:${id}`;
    const items = values.slice(0, clamp(request.pageSize)).map((value) => frozen({ content: summary(value), rank: null, metric: null, recommendation: null }));
    const continuation = values.length >= clamp(request.pageSize) && page < 50 ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId, items, continuation });
    }
    return frozen({ kind: 'document', document: { components: [section(collectionId, label, items, continuation)] } });
}
export async function getDetail(request) {
    const id = contentId(request.id);
    const data = await fetchJson(`${api}book?bookId=${encodeURIComponent(id)}`);
    const payload = object(data.data);
    const nested = object(payload.bookData);
    const value = Object.keys(nested).length > 0 ? nested : payload;
    return detail(summary(value, id));
}
export async function getChapters(request) {
    const id = contentId(request.id);
    const first = await chapterPage(id, 1);
    const total = positive(first.count, first.list.length);
    const pages = [first];
    const pageCount = Math.min(25, Math.ceil(total / 200));
    for (let page = 2; page <= pageCount; page += 1)
        pages.push(await chapterPage(id, page));
    const items = pages.flatMap((value) => value.list).slice(0, 5000).map((value, order) => chapter(id, value, order));
    if (chapterLocks.size + items.length > 10_000)
        chapterLocks.clear();
    for (const item of items)
        chapterLocks.set(item.id, item.isLocked === true);
    return frozen({ items, groups: [] });
}
export async function getContent(request) {
    const ctx = requireContext();
    ctx.log.info('audio_playback_resource_requested');
    try {
        const bookId = contentId(request.id);
        const chapterId = chapterIdFrom(request.chapterId, bookId);
        if (chapterLocks.get(request.chapterId) === true)
            throw new Error('unsupported: paid audio chapter requires an account.');
        const timestamp = Date.now().toString();
        const signature = md5(`${md5(`${timestamp}${playKey}`)}${playKey}`);
        const endpoint = `${api}AppGetChapterUrl2023?timeStamp=${encodeURIComponent(timestamp)}&uid=&chapterId=${encodeURIComponent(chapterId)}&addItParapet=${encodeURIComponent(signature)}&bookId=${encodeURIComponent(bookId)}`;
        const payload = await fetchJson(endpoint);
        const upstream = text(payload.src);
        if (!trustedAudio(upstream))
            throw new Error('Playback address is unavailable.');
        const referer = base + '/';
        const headers = { ...audioHeaders, Origin: base, Referer: referer };
        const result = frozen({ chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null, text: null, pages: [], media: {
                url: ctx.resource.proxy({ kind: 'audio', url: upstream, headers }), resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: mime(upstream), headers,
            } });
        ctx.log.info('audio_playback_resource_resolved');
        return result;
    }
    catch (error) {
        ctx.log.warn('audio_playback_resource_failed');
        throw error;
    }
}
async function fetchJson(url) {
    const response = await requireContext().http.fetch(url, { headers: appHeaders });
    if (!response.ok)
        throw new Error('Source request failed.');
    const value = await response.json();
    if (!isObject(value))
        throw new Error('Source response is invalid.');
    return value;
}
async function chapterPage(id, page) {
    const data = await fetchJson(`${api}chapter?size=200&page=${page}&sort=asc&bookId=${encodeURIComponent(id)}`);
    const value = object(data.data);
    return { count: number(value.count), list: records(value.list) };
}
async function rootDocument(pageSize) {
    const data = await fetchJson(`${api}appHome`);
    const items = popular(data).slice(0, Math.min(clamp(pageSize), 10)).map((value) => frozen({ content: summary(value), rank: null, metric: null, recommendation: null }));
    const components = [];
    if (items.length > 0)
        components.push(section('audio-popular', '热门听书', items, null, 'shelf', 'audio', '主播与连载节目精选'));
    components.push({ type: 'section', id: 'audio-categories', title: '听书分类', subtitle: '按题材选择想听的内容', icon: 'explore', children: [{ type: 'categoryCollection', id: 'audio-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'audio' })) }] });
    return frozen({ kind: 'document', document: { components } });
}
function section(id, title, items, continuation, layout = 'coverGrid', icon = 'audio', subtitle = null) { return { type: 'section', id: `${id}:section`, title, subtitle, icon, children: [{ type: 'contentCollection', id, layout, items, continuation }] }; }
function summary(value, idOverride) {
    const id = idOverride ?? (text(value.id) || text(value.bookId));
    if (id === '')
        throw new Error('Source item has no ID.');
    const count = number(value.count);
    return frozen({ id: `audio:${id}`, title: text(value.bookTitle) || text(value.title) || '未命名音频', contentKind: 'audio', author: nullable(value.bookAnchor) ?? nullable(value.anchor), url: `${base}/book/${id}`, coverUrl: nullable(value.bookImage) ?? nullable(value.image), description: nullable(value.bookDesc) ?? nullable(value.desc), language: 'zh-CN', status: status(value.bookUpdateStatus), access: 'mixed', wordCount: null, chapterCount: count || null, publishedAt: null, updatedAt: null, latestChapter: count > 0 ? { id: null, title: `共${count}集`, url: null, updatedAt: null } : null, categories: nullable(value.categoryName) === null ? [] : [nullable(value.categoryName)], tags: [], attributes: [] });
}
function detail(item) { return frozen({ ...item, aliases: [], catalogUrl: item.url }); }
function chapter(bookId, value, order) { const id = text(value.chapterId) || text(value.id) || text(value.url); if (id === '')
    throw new Error('Source chapter has no ID.'); const price = number(value.price) || number(value.chapterPrice); return frozen({ id: `audio:${bookId}:${id}`, title: text(value.title) || `第${order + 1}集`, order, url: null, volumeTitle: null, wordCount: null, updatedAt: null, isLocked: price > 0, attributes: price > 0 ? [{ key: 'price', label: '听币', value: String(price) }] : [] }); }
function popular(data) { const root = object(data.data); return records(object(root.best).list).length > 0 ? records(object(root.best).list) : records(root.list); }
function contentId(id) { const match = /^audio:([^:]+)$/u.exec(id); if (match?.[1] === undefined)
    throw new Error('Content ID is invalid.'); return match[1]; }
function chapterIdFrom(id, bookId) { const match = new RegExp(`^audio:${escape(bookId)}:([^:]+)$`, 'u').exec(id); if (match?.[1] === undefined)
    throw new Error('Chapter ID is invalid.'); return match[1]; }
function pageFromCursor(cursor, target) { if (cursor === null)
    return 1; const value = Number(new RegExp(`^${escape(target)}:(\\d+)$`, 'u').exec(cursor)?.[1]); if (!Number.isSafeInteger(value) || value < 2 || value > 50)
    throw new Error('Discovery cursor is invalid.'); return value; }
function trustedAudio(value) { try {
    const host = new URL(value).hostname.toLowerCase();
    return ['xmcdn.com', 'tingshijie.com', '365ting.com', 'tingchina.com', 'stream.tencentmusic.com'].some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}
catch {
    return false;
} }
function mime(url) { return /\.m4a(?:$|\?)/iu.test(url) ? 'audio/mp4' : /\.aac(?:$|\?)/iu.test(url) ? 'audio/aac' : 'audio/mpeg'; }
function md5(value) { return createHash('md5').update(value).digest('hex'); }
function clamp(value) { return Math.max(1, Math.min(100, Math.floor(value))); }
function status(value) { return String(value) === '1' ? 'completed' : String(value) === '2' ? 'ongoing' : 'unknown'; }
function positive(value, fallback) { return Number.isSafeInteger(value) && value > 0 ? value : fallback; }
function object(value) { return isObject(value) ? value : {}; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function number(value) { const result = Number(value); return Number.isFinite(result) && result >= 0 ? result : 0; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen(value) { return Object.freeze(value); }
function escape(value) { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
