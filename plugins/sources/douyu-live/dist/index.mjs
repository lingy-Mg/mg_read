/**
 * 斗鱼直播原生数据源。
 *
 * 职责：直接读取斗鱼二级分类和房间列表，并解析线路服务返回的 AES-ECB 数据。
 * 生命周期：activate 注入 Runtime；仅缓存当前进程内的公开分类。
 * IO：分类、列表和线路请求走 ctx.http；封面与直播媒体经 ctx.resource.proxy。
 * 稳定标识：内容使用斗鱼 room ID，分类使用 cid2。
 */
import { createDecipheriv } from 'node:crypto';
const web = 'https://www.douyu.com/', listApi = 'https://www.douyu.com/gapi/rkc/directory/mixList', filterApi = 'https://www.douyu.com/japi/weblist/apinc/getC2List', detailApi = 'http://dh.baicanuc.cn:3000/getDouyuData', userAgent = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 Chrome/72.0.3626.81 Safari/537.36', headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', Referer: web, 'User-Agent': userAgent }), parents = Object.freeze(['4', '5', '6', '20']);
let context, categoryCache;
export async function activate(next) { context = next; categoryCache = undefined; next.log.info('source_activated'); }
export async function search(_request) { return frozen({ items: [], nextCursor: null, totalCount: 0 }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    const categories = await loadCategories();
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'douyu-categories', title: '斗鱼直播', subtitle: '按动态分类浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'douyu-category-list', layout: 'chips', categories: categories.map(({ id, title }) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const category = (await loadCategories()).find(({ id }) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), json = await fetchJson(`${listApi}/2_${encodeURIComponent(category.id)}/${page}`), values = pickList(json).map(roomSummary).filter(notNull).slice(0, limit), collectionId = `douyu:${category.id}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category.title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const roomId = contentId(request.id), data = await loadDetail(roomId), info = roomInfo(data, roomId), item = summary(roomId, info.title, info.author, info.cover, info.category, info.online); return frozen({ ...item, description: `房间号：${roomId}${info.author ? `\n主播：${info.author}` : ''}\n不要相信视频中的任何广告。`, aliases: [], catalogUrl: `${web}${encodeURIComponent(roomId)}` }); }
export async function getChapters(request) { const roomId = contentId(request.id), chapter = frozen({ id: `live:${encodeKey(roomId)}:main`, title: '直播', order: 0, url: null, volumeTitle: '直播', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:${encodeKey(roomId)}:live`, title: '直播', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const roomId = contentId(request.id); if (request.chapterId !== `live:${encodeKey(roomId)}:main`)
    throw new Error('Chapter ID is invalid.'); const baseData = await loadDetail(roomId), rates = records(first(baseData.multirates, baseData.multiRates, baseData.rateList, baseData.rates)), cdns = records(first(baseData.cdnsWithName, baseData.cdns, baseData.cdnList)), rate = text(first(rates[0]?.rate, rates[0]?.bitRate, rates[0]?.value)), cdn = text(first(cdns[0]?.cdn, cdns[0]?.value, cdns[0]?.code, cdns[0]?.cdnName)), data = await loadDetail(roomId, rate, cdn), upstream = scanUrl(data); if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { Referer: web, 'User-Agent': userAgent }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/x-flv', headers: mediaHeaders } }); }
async function loadCategories() { if (categoryCache !== undefined)
    return categoryCache; const responses = await Promise.all(parents.map(parent => fetchJson(`${filterApi}?customClassId=${parent}&offset=0&limit=200`))), seen = new Set(), values = []; for (const root of responses)
    for (const item of pickList(root)) {
        const id = text(first(item.cid2, item.cate2Id, item.c2Id, item.id, item.value, item.tagId, item.cid)), title = text(first(item.cname2, item.cate2Name, item.c2Name, item.gameName, item.name, item.title, item.shortName));
        if (id !== '' && title !== '' && !seen.has(id) && item.isHidden !== 1 && item.isHidden !== true) {
            seen.add(id);
            values.push({ id, title });
        }
    } if (values.length === 0)
    throw new Error('Source categories are unavailable.'); categoryCache = Object.freeze(values); return categoryCache; }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.json(); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
async function loadDetail(roomId, rate = '', cdn = '') { const url = new URL(detailApi); url.searchParams.set('rid', roomId); if (rate !== '')
    url.searchParams.set('rate', rate); if (cdn !== '')
    url.searchParams.set('cdn', cdn); const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = parsePayload(await response.text()); if (!isObject(value))
    throw new Error('Live detail response is invalid.'); return value; }
function parsePayload(raw) { const trimmed = raw.trim(); if (trimmed === '')
    return {}; let value; try {
    value = JSON.parse(trimmed);
}
catch {
    value = trimmed;
} if (isObject(value) && typeof value.data === 'string')
    value = value.data; if (typeof value !== 'string')
    return value; if (/^https?:\/\//iu.test(value))
    return { url: value }; try {
    const decipher = createDecipheriv('aes-128-ecb', Buffer.from('0123456789abcdef', 'utf8'), null);
    decipher.setAutoPadding(true);
    const plain = Buffer.concat([decipher.update(Buffer.from(value, 'base64')), decipher.final()]).toString('utf8');
    return JSON.parse(plain);
}
catch {
    return {};
} }
function roomInfo(data, roomId) { const info = object(first(data.roomInfo, data.info, data.room)); return { title: text(first(info.roomName, info.rn, info.room_name)) || `斗鱼房间 ${roomId}`, author: text(first(info.nickname, info.nn, info.nickName, info.owner_name)), cover: text(first(info.roomSrc, info.rs16, info.room_thumb, info.pic)), category: text(first(info.cate2Name, info.cate_name, info.game_name)), online: text(first(info.hn, info.ol, info.online)) }; }
function roomSummary(item) { const id = text(first(item.rid, item.room_id, item.roomId, item.roomid, item.id)); if (id === '')
    return null; return summary(id, text(first(item.rn, item.roomName, item.room_name, item.title)) || `斗鱼房间 ${id}`, text(first(item.nn, item.nickname, item.nickName, item.owner_name, item.ownerName)), text(first(item.rs16, item.rs1, item.roomSrc, item.room_src, item.room_pic, item.verticalSrc, item.pic)), text(first(item.c2name_display, item.c2name, item.cate2Name, item.cate_name, item.game_name)), text(first(item.ol, item.hn, item.online, item.onlineNum))); }
function summary(id, title, author, cover, category, online) { const key = encodeKey(id); return frozen({ id: `live:${key}`, title, contentKind: 'video', coverOrientation: 'landscape', author: author || null, url: `${web}${encodeURIComponent(id)}`, coverUrl: proxyImage(cover), description: `房间号：${id}${category ? `\n分类：${category}` : ''}`, language: 'zh-CN', status: 'ongoing', access: 'free', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `live:${key}:main`, title: online ? `热度 ${online}` : '直播', url: null, updatedAt: null }, categories: category ? [category] : ['直播'], tags: [], attributes: [] }); }
function pickList(root) { for (const value of [root.data, object(root.data).rl, object(root.data).list, object(root.data).room_list, object(root.data).cate2Info, object(root.data).cate2List, root.rl, root.list, root.cate2Info, root.cate2List]) {
    const list = records(value);
    if (list.length > 0)
        return list;
} return []; }
function scanUrl(value, depth = 0) { if (depth > 8 || value === null || value === undefined)
    return ''; if (typeof value === 'string')
    return safeUrl(value) ? value : ''; if (Array.isArray(value)) {
    for (const item of value) {
        const found = scanUrl(item, depth + 1);
        if (found !== '')
            return found;
    }
    return '';
} if (isObject(value)) {
    for (const key of ['url', 'play_url', 'playUrl', 'flv', 'm3u8', 'hls', 'live_url', 'stream', 'streamUrl']) {
        const found = scanUrl(value[key], depth + 1);
        if (found !== '')
            return found;
    }
    for (const item of Object.values(value)) {
        const found = scanUrl(item, depth + 1);
        if (found !== '')
            return found;
    }
} return ''; }
function contentId(id) { const encoded = /^live:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); return decodeKey(encoded); }
function proxyImage(value) { if (!safeUrl(value))
    return null; return requireContext().resource.proxy({ kind: 'image', url: value, headers: { Referer: web } }); }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : '', page = Number(raw); if (!Number.isSafeInteger(page) || page < 2 || page > 1000)
    throw new Error('Cursor is invalid.'); return page; }
function encodeKey(value) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeKey(value) { if (!/^[A-Za-z0-9_-]+$/u.test(value))
    throw new Error('Source key is invalid.'); return Buffer.from(value, 'base64url').toString('utf8'); }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
