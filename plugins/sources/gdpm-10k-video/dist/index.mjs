const site = 'https://gdpm.kpyaqxe.com', apiBase = 'https://hdwtoqv.com/api', headers = Object.freeze({ Accept: 'application/json, text/plain, */*', 'Accept-Language': 'zh-CN,zh;q=0.9', Origin: site, Referer: `${site}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0' });
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), limit = clamp(request.pageSize), data = object(await api('/data/searchVideos', { keyword: query, page, pageSize: limit })), values = records(data.video).slice(0, limit), pagination = object(data.pagination); return frozen({ items: values.map(summary), nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: integer(first(pagination.total, data.total)) }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { const categories = await categoryList(); if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'video-categories', title: '视频分类', subtitle: '站点实时导航', icon: 'video', children: [{ type: 'categoryCollection', id: 'video-categories-list', layout: 'chips', categories: categories.map(({ id, title }) => ({ id: encodeKey(id), title, target: `category:${encodeKey(id)}`, count: null, url: null, icon: 'video' })) }] }] } });
} const encoded = /^category:([^:]+)$/u.exec(request.target)?.[1], category = encoded === undefined ? undefined : categories.find(value => value.id === decodeKey(encoded)); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), data = object(await api('/data/categoryVideos', { id: category.id, page, pageSize: limit })), values = records(data.video).slice(0, limit), collectionId = `video:${encodeKey(category.id)}`, items = values.map(value => frozen({ content: summary({ ...value, categoryName: text(data.categoryName) || category.title }), rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category.title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), value = object(await videoInfo(id)), item = summary(value); return frozen({ ...item, description: text(value.vod_name) || item.description, aliases: [], catalogUrl: item.url }); }
export async function getChapters(request) { const id = contentId(request.id), value = object(await videoInfo(id)), title = text(value.vod_duration) || '正片', chapter = frozen({ id: `video:${encodeKey(id)}:main`, title, order: 0, url: null, volumeTitle: '默认线路', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:${encodeKey(id)}:default`, title: '默认线路', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const id = contentId(request.id); if (request.chapterId !== `video:${encodeKey(id)}:main`)
    throw new Error('Chapter ID is invalid.'); const value = object(await videoInfo(id)), upstream = text(first(value.vod_play_url, value.vod_down_url)).replaceAll('\\/', '/'); if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', referer = `${site}/video-play/${encodeURIComponent(text(value.rss_category_id))}/${encodeURIComponent(id)}`, mediaHeaders = { Referer: referer, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: text(value.vod_duration) || '正片', updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function categoryList() { const data = await api('/data/navigation'), values = records(data), result = [], seen = new Set(); for (const parent of values) {
    const children = records(parent.children), candidates = children.some(child => text(child.type) === '1') ? children : [parent];
    for (const item of candidates) {
        if (text(item.type) !== '1')
            continue;
        const id = text(item.id), title = text(item.name);
        if (id === '' || title === '' || seen.has(id))
            continue;
        seen.add(id);
        result.push({ id, title });
    }
} if (result.length === 0)
    throw new Error('Source navigation is empty.'); return result; }
async function videoInfo(id) { return api('/data/videoInfo', { id }); }
async function api(path, params = {}) { const query = new URLSearchParams(); for (const [key, value] of Object.entries(params))
    if (value !== null && value !== undefined)
        query.set(key, String(value)); const url = `${apiBase}${path}${query.size === 0 ? '' : `?${query}`}`, response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const root = await response.json(); if (!isObject(root) || Number(root.code) !== 1)
    throw new Error(isObject(root) ? text(root.msg) || 'Source API failed.' : 'Source response is invalid.'); return root.data; }
function summary(value) { const native = text(first(value.id, value.vod_id)); if (native === '')
    throw new Error('Source item has no ID.'); const id = encodeKey(native), category = nullable(first(value.categoryName, value.category_name)); return frozen({ id: `video:${id}`, title: text(first(value.vod_name, value.name)) || native, contentKind: 'video', coverOrientation: 'landscape', author: null, url: `${site}/video/${encodeURIComponent(native)}`, coverUrl: proxyImage(first(value.vod_pic, value.vod_pic_thumb)), description: null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: null, categories: category === null ? [] : [category], tags: [], attributes: [] }); }
function contentId(id) { const encoded = /^video:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); return decodeKey(encoded); }
function proxyImage(value) { const raw = text(value); if (raw === '')
    return null; let url; try {
    url = new URL(raw, site).toString();
}
catch {
    return null;
} return requireContext().resource.proxy({ kind: 'image', url, headers: { Origin: site, Referer: `${site}/` } }); }
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
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function integer(value) { const result = Number(value); return Number.isSafeInteger(result) && result >= 0 ? result : null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
