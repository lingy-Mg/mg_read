const origin = 'https://y.qq.com', headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', Referer: `${origin}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }), channels = Object.freeze([['hot', '热歌榜', 26], ['new', '新歌榜', 27], ['rising', '飙升榜', 62]]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), size = clamp(request.pageSize), json = await fetchJson(`https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=${page}&n=${size}&w=${encodeURIComponent(query)}`), song = object(object(json.data).song), items = records(song.list).map(songSummary).filter(notNull), totalCount = nonNegative(song.totalnum); return frozen({ items, nextCursor: totalCount !== null ? page * size < totalCount ? `search:${page + 1}` : null : items.length >= size ? `search:${page + 1}` : null, totalCount }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'qq-charts', title: 'QQ音乐', subtitle: '官方榜单', icon: 'audio', children: [{ type: 'categoryCollection', id: 'qq-chart-list', layout: 'chips', categories: channels.map(([id, title]) => ({ id, title, target: `chart:${id}`, count: null, url: null, icon: 'ranking' })) }] }] } });
} const channel = channels.find(([id]) => request.target === `chart:${id}`); if (channel === undefined)
    throw new Error('Discovery target is invalid.'); if (request.cursor !== null)
    throw new Error('Chart cursor is unsupported.'); const body = { toplist: { module: 'musicToplist.ToplistInfoServer', method: 'GetDetail', param: { topid: channel[2], num: Math.max(20, clamp(request.pageSize)), period: '' } }, comm: { uin: 0, format: 'json', ct: 20, cv: 1859 } }, response = await requireContext().http.fetch('https://u.y.qq.com/cgi-bin/musicu.fcg', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify(body) }); if (!response.ok)
    throw new Error('Source request failed.'); const json = await response.json(); if (!isObject(json))
    throw new Error('Source response is invalid.'); const values = records(object(object(json.toplist).data).songInfoList).map(songSummary).filter(notNull).slice(0, clamp(request.pageSize)), collectionId = `audio:${channel[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: 'audio', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const mid = contentId(request.id), json = await fetchJson(`https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid=${encodeURIComponent(mid)}&format=json`), song = records(json.data)[0]; if (song === undefined)
    throw new Error('Song detail is unavailable.'); const item = songSummary(song); if (item === null)
    throw new Error('Song detail is invalid.'); return frozen({ ...item, aliases: [], catalogUrl: `${origin}/n/ryqq/songDetail/${mid}` }); }
export async function getChapters(request) { const mid = contentId(request.id), detail = await getDetail(request), chapter = frozen({ id: `audio:${mid}:main`, title: `${detail.title}${detail.author ? ` - ${detail.author}` : ''}`, order: 0, url: null, volumeTitle: '单曲', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:audio:${mid}`, title: '单曲', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const mid = contentId(request.id); if (request.chapterId !== `audio:${mid}:main`)
    throw new Error('Chapter ID is invalid.'); const upstream = `http://175.27.166.236/kgqq1/qq.php?type=mp3&id=${encodeURIComponent(mid)}&level=exhigh`, mediaHeaders = { Referer: 'http://175.27.166.236/', 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers: mediaHeaders }), resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: 'audio/mpeg', headers: mediaHeaders } }); }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.json(); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function songSummary(song) { const mid = songMid(first(song.songmid, song.mid, song.songMid)); if (mid === null)
    return null; const album = object(song.album), albumMid = text(first(song.albummid, song.albumMid, album.mid)), file = object(song.file), author = artists(song), duration = durationText(song.interval), cover = albumMid === '' ? text(song.cover) : `https://y.gtimg.cn/music/photo_new/T002R500x500M000${albumMid}.jpg`; return frozen({ id: `audio:${mid}`, title: text(first(song.songname, song.title, song.name)) || mid, contentKind: 'audio', coverOrientation: 'square', author: author || nullable(song.singerName), url: `${origin}/n/ryqq/songDetail/${mid}`, coverUrl: proxyImage(cover), description: [text(first(song.albumname, album.title, album.name)), duration].filter(Boolean).join(' · ') || null, language: null, status: 'completed', access: number(object(song.pay).payplay) === 1 ? 'paid' : 'unknown', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `audio:${mid}:main`, title: duration || '播放', url: null, updatedAt: null }, categories: ['音乐'], tags: [], attributes: file.size_320mp3 ? [{ key: 'quality', label: '音质', value: '320k' }] : [] }); }
function artists(song) { return records(song.singer).map(value => text(value.name)).filter(Boolean).join('、'); }
function songMid(value) { const id = text(value); return /^[A-Za-z0-9_-]{4,64}$/u.test(id) ? id : null; }
function contentId(id) { const value = /^audio:([A-Za-z0-9_-]{4,64})$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function durationText(value) { const seconds = Math.floor(number(value)); if (seconds <= 0)
    return ''; return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`; }
function proxyImage(value) { if (!safeUrl(value))
    return null; return requireContext().resource.proxy({ kind: 'image', url: value, headers: { Referer: `${origin}/` } }); }
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
function nonNegative(value) { const n = Number(value); return Number.isSafeInteger(n) && n >= 0 ? n : null; }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.replace(/<[^>]+>/gu, '').trim() : typeof value === 'number' ? String(value) : ''; }
function number(value) { const result = Number(value); return Number.isFinite(result) ? result : 0; }
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
