const api = 'https://api.live.bilibili.com', web = 'https://live.bilibili.com', headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', Referer: `${web}/`, Origin: web, 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/132.0.0.0 Safari/537.36' });
let context, areasCache;
export async function activate(next) { context = next; areasCache = undefined; next.log.info('source_activated'); }
export async function search(_request) { return frozen({ items: [], nextCursor: null, totalCount: 0 }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    const areas = await loadAreas();
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'bili-live-areas', title: '哔哩直播', subtitle: '动态分区', icon: 'video', children: [{ type: 'categoryCollection', id: 'bili-live-area-list', layout: 'chips', categories: areas.map(area => ({ id: `${area.parent}-${area.id}`, title: area.title, target: `area:${area.parent}:${area.id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const area = (await loadAreas()).find(value => request.target === `area:${value.parent}:${value.id}`); if (area === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), json = await fetchJson(`${api}/room/v1/area/getRoomList?platform=web&parent_area_id=${area.parent}&area_id=${area.id}&sort_type=online&page=${page}&page_size=${size}`), values = records(json.data).map(roomSummary).filter(notNull), collectionId = `live:${area.parent}:${area.id}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: area.title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const roomId = contentId(request.id), json = await fetchJson(`${api}/xlive/web-room/v1/index/getInfoByRoom?room_id=${roomId}`), data = object(json.data), room = object(first(data.room_info, data.roomInfo, data)), anchor = object(first(data.anchor_info, data.anchorInfo)), item = summary(roomId, text(first(room.title, room.room_name)) || `直播间 ${roomId}`, text(first(anchor.base_info && object(anchor.base_info).uname, room.uname, room.anchor_name)), text(first(room.cover, room.user_cover, room.keyframe)), text(first(room.area_name, room.parent_area_name)), number(first(room.online, room.online_num))); return frozen({ ...item, description: `房间号：${roomId}\n${text(room.description)}\n不要相信视频中的任何广告。`.trim(), aliases: [], catalogUrl: `${web}/${roomId}` }); }
export async function getChapters(request) { const roomId = contentId(request.id), chapter = frozen({ id: `live:${roomId}:main`, title: '直播', order: 0, url: null, volumeTitle: '直播', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:live:${roomId}`, title: '直播', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const roomId = contentId(request.id); if (request.chapterId !== `live:${roomId}:main`)
    throw new Error('Chapter ID is invalid.'); let json = await fetchJson(`${api}/xlive/web-room/v2/index/getRoomPlayInfo?room_id=${roomId}&protocol=0,1&format=0,1,2&codec=0,1&qn=10000&platform=web&ptype=8`), upstream = playUrl(json); if (!safeUrl(upstream)) {
    json = await fetchJson(`${api}/room/v1/Room/playUrl?cid=${roomId}&platform=web&qn=10000`);
    upstream = text(records(object(json.data).durl)[0]?.url);
} if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { Referer: `${web}/${roomId}`, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/x-flv', headers: mediaHeaders } }); }
async function loadAreas() { if (areasCache !== undefined)
    return areasCache; const json = await fetchJson(`${api}/xlive/web-interface/v1/index/getWebAreaList?source_id=2`), parents = records(object(json.data).data), values = []; for (const parent of parents) {
    const parentId = text(parent.id), parentName = text(parent.name);
    for (const item of records(parent.list)) {
        const id = text(item.id), title = text(item.name);
        if (parentId !== '' && id !== '' && title !== '')
            values.push({ id, parent: parentId, title: `${parentName} · ${title}` });
    }
} if (values.length === 0)
    throw new Error('Live areas are unavailable.'); areasCache = Object.freeze(values); return areasCache; }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.json(); if (!isObject(value) || number(value.code) !== 0)
    throw new Error('Source response is invalid.'); return value; }
function roomSummary(value) { const id = roomId(first(value.roomid, value.room_id, value.roomId)); if (id === null)
    return null; return summary(id, text(value.title) || `直播间 ${id}`, text(first(value.uname, value.anchor_name)), text(first(value.user_cover, value.cover, value.system_cover, value.keyframe)), text(first(value.area_v2_name, value.area_name, value.parent_name)), number(value.online)); }
function summary(id, title, author, cover, area, online) { return frozen({ id: `live:${id}`, title, contentKind: 'video', coverOrientation: 'landscape', author: author || null, url: `${web}/${id}`, coverUrl: proxyImage(cover), description: `房间号：${id}${area ? `\n分区：${area}` : ''}`, language: 'zh-CN', status: 'ongoing', access: 'free', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `live:${id}:main`, title: online > 0 ? `人气 ${online}` : '直播', url: null, updatedAt: null }, categories: area ? [area] : ['直播'], tags: [], attributes: [] }); }
function playUrl(root) { const playurl = object(object(object(root.data).playurl_info).playurl); for (const stream of records(playurl.stream))
    for (const format of records(stream.format))
        for (const codec of records(format.codec)) {
            const baseUrl = text(codec.base_url);
            for (const info of records(codec.url_info)) {
                const candidate = `${text(info.host)}${baseUrl}${text(info.extra)}`;
                if (safeUrl(candidate))
                    return candidate;
            }
        } return ''; }
function roomId(value) { const id = text(value); return /^\d+$/u.test(id) ? id : null; }
function contentId(id) { const value = /^live:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function proxyImage(value) { if (!safeUrl(value))
    return null; return requireContext().resource.proxy({ kind: 'image', url: value.replace(/^http:/u, 'https:'), headers: { Referer: `${web}/` } }); }
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
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function number(value) { const result = Number(value); return Number.isFinite(result) ? result : 0; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
