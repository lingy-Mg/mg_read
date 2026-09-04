const mirrors = ['http://mdav.pw', 'http://md91.cc', 'http://9191md.me', 'http://36717.info', 'http://36717.pw', 'http://bt4.cc'], headers = { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json,text/plain,*/*' };
let context, active = mirrors[0];
export async function activate(next) { context = next; active = mirrors[0]; next.log.info('source_activated'); }
export async function search(request) { const query = clean(request.query); if (!query)
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), data = await api({ wd: query, pg: page }), size = clamp(request.pageSize), items = records(data.list).map(summary).filter(notNull).slice(0, size); return frozen({ items, nextCursor: page < number(data.pagecount) && items.length ? `search:${page + 1}` : null, totalCount: number(data.total) || null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'md-video-channels', title: 'MD视频', subtitle: '苹果 CMS 最新内容', icon: 'video', children: [{ type: 'categoryCollection', id: 'md-video-channel-list', layout: 'chips', categories: [{ id: 'latest', title: '最新', target: 'channel:latest', count: null, url: null, icon: 'video' }] }] }] } }); if (request.target !== 'channel:latest')
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), data = await api({ pg: page }), size = clamp(request.pageSize), contents = records(data.list).map(summary).filter(notNull).slice(0, size), collectionId = 'md-video:latest', items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = page < number(data.pagecount) && contents.length ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: '最新', subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), data = await detail(id), item = summary(data); if (!item)
    throw new Error('Video detail is unavailable.'); const episodes = parseEpisodes(data); return frozen({ ...item, description: clean(text(data.vod_blurb || data.vod_content)) || null, chapterCount: episodes.length, latestChapter: episodes.length ? { id: episodeId(id, episodes.at(-1)), title: episodes.at(-1)?.title ?? '', url: null, updatedAt: null } : null, aliases: [], catalogUrl: `${active}/api.php/provide/vod/?ac=detail&ids=${id}` }); }
export async function getChapters(request) { const id = contentId(request.id), episodes = parseEpisodes(await detail(id)), items = episodes.map((episode, order) => frozen({ id: episodeId(id, episode), title: episode.title, order, url: null, volumeTitle: episode.group, wordCount: null, updatedAt: null, isLocked: false, attributes: [] })), groups = [...new Set(episodes.map(value => value.group))].map((title, index) => frozen({ id: `group:${id}:${index}`, title, order: index, episodes: items.filter(item => item.volumeTitle === title) })); return frozen({ items, groups }); }
export async function getContent(request) { const id = contentId(request.id), key = chapterKey(request.chapterId, id), episode = parseEpisodes(await detail(id)).find(value => value.line === key.line && value.index === key.index); if (!episode || !safeUrl(episode.url))
    throw new Error('Video address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(episode.url) ? 'hls' : 'video', mediaHeaders = { Referer: `${active}/`, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: episode.title, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: episode.url, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function detail(id) { const data = await api({ ids: id }), value = records(data.list)[0]; if (!value)
    throw new Error('Video detail is unavailable.'); return value; }
async function api(params) { let last; for (const base of [active, ...mirrors.filter(value => value !== active)])
    try {
        const url = new URL(`${base}/api.php/provide/vod/`);
        url.searchParams.set('ac', 'detail');
        for (const [key, value] of Object.entries(params))
            url.searchParams.set(key, String(value));
        const response = await requireContext().http.fetch(url, { headers });
        if (!response.ok)
            throw new Error(`HTTP ${response.status}`);
        const value = await response.json();
        if (!isObject(value) || number(value.code) !== 1)
            throw new Error('Invalid CMS response.');
        active = base;
        return value;
    }
    catch (error) {
        last = error;
    } throw last instanceof Error ? last : new Error('All MD mirrors failed.'); }
function parseEpisodes(value) { const lines = text(value.vod_play_url).split('$$$'), names = text(value.vod_play_from).split('$$$'), episodes = []; for (const [line, raw] of lines.entries())
    for (const [episodeIndex, entry] of raw.split('#').entries()) {
        const separator = entry.indexOf('$'), title = clean(separator >= 0 ? entry.slice(0, separator) : ''), url = (separator >= 0 ? entry.slice(separator + 1) : entry).trim();
        if (!safeUrl(url))
            continue;
        episodes.push({ line, index: episodeIndex, title: title || `第${episodeIndex + 1}集`, url, group: clean(names[line] ?? '') || `线路${line + 1}` });
    } return episodes; }
function summary(value) { const id = text(value.vod_id), title = clean(text(value.vod_name)); if (!/^\d+$/u.test(id) || !title)
    return null; const cover = text(value.vod_pic); return frozen({ id: `video:${id}`, title, contentKind: 'video', coverOrientation: 'landscape', author: clean(text(value.vod_actor || value.vod_director)) || null, url: `${active}/api.php/provide/vod/?ac=detail&ids=${id}`, coverUrl: safeUrl(cover) ? requireContext().resource.proxy({ kind: 'image', url: cover, headers: { Referer: `${active}/` } }) : null, description: clean(text(value.vod_blurb)) || null, language: 'zh-CN', status: 'unknown', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: timestamp(value.vod_time), latestChapter: text(value.vod_remarks) ? { id: `video:${id}:latest`, title: text(value.vod_remarks), url: null, updatedAt: null } : null, categories: text(value.type_name) ? [text(value.type_name)] : [], tags: [], attributes: [] }); }
function episodeId(id, value) { return `video:${id}:${value.line}:${value.index}`; }
function chapterKey(id, content) { const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, 'u').exec(id); if (!match)
    throw new Error('Chapter ID is invalid.'); return { line: Number(match[1]), index: Number(match[2]) }; }
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function timestamp(value) { const raw = text(value); if (!raw)
    return null; const date = new Date(raw.replace(' ', 'T')); return Number.isNaN(date.valueOf()) ? null : date.toISOString(); }
function clean(value) { return value.replaceAll(/<[^>]+>/gu, ' ').replaceAll(/\s+/gu, ' ').trim(); }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function number(value) { return typeof value === 'number' && Number.isFinite(value) ? value : typeof value === 'string' ? Number(value) || 0 : 0; }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function notNull(value) { return value !== null; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(20, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
