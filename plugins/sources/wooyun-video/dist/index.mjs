const base = 'https://wooyun.tv';
const headers = Object.freeze({ Accept: 'application/json, text/plain, */*', 'Accept-Language': 'zh-CN,zh;q=0.9', 'Content-Type': 'application/json', Referer: `${base}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0.0.0' });
const categories = Object.freeze([['recommend', '推荐'], ['movie', '电影'], ['tv_series', '电视剧'], ['korean_drama', '韩剧'], ['short_drama', '短剧'], ['animation', '动画'], ['variety', '综艺']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), limit = clamp(request.pageSize), data = object(await api('/movie/media/search', { menuCodeList: [], pageIndex: page, pageSize: limit, searchKey: query, topCode: '' })), values = records(data.records).slice(0, limit); return frozen({ items: values.map(summary), nextCursor: values.length >= limit ? `search:${page + 1}` : null, totalCount: integer(data.total) }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'video-categories', title: '影视分类', subtitle: '按频道浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'video-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), [code, title] = category; let values = []; if (code === 'recommend') {
    const data = object(await api(`/movie/media/home/custom/classify/${page}/3?limit=${limit}`));
    for (const section of records(data.records))
        values.push(...records(section.mediaResources).concat(records(section.records)));
}
else {
    const data = object(await api('/movie/media/search', { menuCodeList: [], pageIndex: page, pageSize: limit, searchKey: '', topCode: code }));
    values = records(data.records);
} values = uniqueById(values).slice(0, limit); const collectionId = `video:${code}`, items = values.map(value => frozen({ content: summary(value), rank: null, metric: null, recommendation: null })), continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), value = object(await api(`/movie/media/detail?mediaId=${encodeURIComponent(id)}`)), item = summary({ ...value, id }); return frozen({ ...item, aliases: [], catalogUrl: item.url }); }
export async function getChapters(request) { const id = contentId(request.id), groups = await videoGroups(id), projected = groups.map((group, index) => projectGroup(id, group, index)).filter(group => group.episodes.length > 0); return frozen({ items: projected.flatMap(group => group.episodes), groups: projected }); }
export async function getContent(request) { const id = contentId(request.id), parsed = parseChapterId(request.chapterId, id), groups = await videoGroups(id); let selected; for (let groupIndex = 0; groupIndex < groups.length; groupIndex += 1) {
    const group = groups[groupIndex] ?? {}, line = lineKey(group, groupIndex);
    if (line !== parsed.line)
        continue;
    selected = records(group.videoList).find((video, index) => videoKey(video, index) === parsed.video);
    if (selected !== undefined)
        break;
} if (selected === undefined)
    throw new Error('Chapter ID is invalid.'); const upstream = text(selected.playUrl).replaceAll('\\/', '/'); if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { Referer: `${base}/play/${encodeURIComponent(id)}`, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: chapterTitle(selected, 0), updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function api(path, body) { const url = `${base}/api/proxy?url=${encodeURIComponent(path)}`, init = body === undefined ? { headers } : { method: 'POST', headers, body: JSON.stringify(body) }, response = await requireContext().http.fetch(url, init); if (!response.ok)
    throw new Error('Source request failed.'); const root = await response.json(); if (!isObject(root))
    throw new Error('Source response is invalid.'); if (Number(root.code) !== 200 || root.isSuccess === false)
    throw new Error(text(root.resultMsg) || 'Source API failed.'); return root.data; }
async function videoGroups(id) { const value = await api(`/movie/media/video/list?mediaId=${encodeURIComponent(id)}&lineName=&resolutionCode=`); return records(value); }
function summary(value) { const native = text(first(value.id, value.mediaId)); if (native === '')
    throw new Error('Source item has no ID.'); const id = encodeKey(native), mediaType = object(value.mediaType), genres = strings(value.genres), categories = [text(mediaType.name), text(value.region), text(value.releaseYear), ...genres, ...records(value.mediaCategories).map(item => text(item.name))].filter(Boolean); return frozen({ id: `video:${id}`, title: text(first(value.title, value.mediaName)) || native, contentKind: 'video', coverOrientation: 'portrait', author: join(first(value.directors, value.actors)), url: `${base}/play/${encodeURIComponent(native)}`, coverUrl: proxyImage(first(value.posterUrlS3, value.posterUrl, value.coverUrl, value.backdropUrlS3, value.backdropUrl)), description: nullable(first(value.overview, value.description, value.originalTitle)), language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: [...new Set(categories)], tags: [], attributes: [] }); }
function projectGroup(id, group, index) { const line = lineKey(group, index), title = text(first(group.lineName, group.name, group.resolutionName)) || `线路${index + 1}`, episodes = records(group.videoList).map((video, videoIndex) => { const key = videoKey(video, videoIndex); return frozen({ id: `video:${encodeKey(id)}:${encodeKey(line)}:${encodeKey(key)}`, title: chapterTitle(video, videoIndex), order: videoIndex, url: null, volumeTitle: title, wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); }); return frozen({ id: `group:${encodeKey(id)}:${encodeKey(line)}`, title, order: index, episodes }); }
function lineKey(group, index) { return text(first(group.lineId, group.lineName, group.name, group.resolutionName)) || `line-${index + 1}`; }
function videoKey(video, index) { const key = text(first(video.id, video.videoId, video.epNo)); if (key === '')
    throw new Error(`Episode ${index + 1} has no stable ID.`); return key; }
function chapterTitle(video, index) { const ep = integer(video.epNo); return `${ep === null ? `第${index + 1}集` : ep === 0 ? '正片' : `第${ep}集`}${text(video.remark) === '' ? '' : ` ${text(video.remark)}`}`; }
function contentId(id) { const encoded = /^video:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); return decodeKey(encoded); }
function parseChapterId(id, content) { const parts = id.split(':'); if (parts.length !== 4 || parts[0] !== 'video' || parts[1] !== encodeKey(content))
    throw new Error('Chapter ID is invalid.'); return { line: decodeKey(parts[2] ?? ''), video: decodeKey(parts[3] ?? '') }; }
function proxyImage(value) { const url = absolute(value); return url === null ? null : requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function absolute(value) { const raw = text(value); if (raw === '')
    return null; try {
    return new URL(raw, base).toString();
}
catch {
    return null;
} }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function uniqueById(values) { const seen = new Set(); return values.filter(value => { const id = text(first(value.id, value.mediaId)); if (id === '' || seen.has(id))
    return false; seen.add(id); return true; }); }
function join(value) { return Array.isArray(value) ? value.map(text).filter(Boolean).join('、') : text(value); }
function strings(value) { return Array.isArray(value) ? value.map(text).filter(Boolean) : []; }
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
