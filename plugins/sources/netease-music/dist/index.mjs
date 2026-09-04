const origin = 'https://music.163.com', headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', Referer: `${origin}/`, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }), channels = Object.freeze([['hot', '热歌榜', '3778678'], ['new', '新歌榜', '3779629'], ['rising', '飙升榜', '19723756'], ['playlists', '热门歌单', '']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), size = clamp(request.pageSize), offset = (page - 1) * size, json = await fetchJson(`${origin}/api/cloudsearch/pc?csrf_token=&s=${encodeURIComponent(query)}&type=1&offset=${offset}&total=true&limit=${size}`), result = object(json.result), items = records(result.songs).map(songSummary).filter(notNull), totalCount = nonNegative(result.songCount); return frozen({ items, nextCursor: totalCount !== null ? page * size < totalCount ? `search:${page + 1}` : null : items.length >= size ? `search:${page + 1}` : null, totalCount }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'netease-channels', title: '网易云音乐', subtitle: '榜单与热门歌单', icon: 'audio', children: [{ type: 'categoryCollection', id: 'netease-channel-list', layout: 'chips', categories: channels.map(([id, title]) => ({ id, title, target: `channel:${id}`, count: null, url: null, icon: id === 'playlists' ? 'library' : 'ranking' })) }] }] } });
} const channel = channels.find(([id]) => request.target === `channel:${id}`); if (channel === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, `channel:${channel[0]}`), size = clamp(request.pageSize), values = channel[0] === 'playlists' ? await loadPlaylists(page, size) : await loadChart(channel[2], size), collectionId = `audio:${channel[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${channel[0]}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: 'audio', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const { kind, id } = contentId(request.id); if (kind === 'song') {
    const song = await loadSong(id), item = songSummary(song);
    if (item === null)
        throw new Error('Song detail is invalid.');
    return frozen({ ...item, aliases: [], catalogUrl: `${origin}/song?id=${id}` });
} const playlist = await loadPlaylist(id), item = playlistSummary(playlist); return frozen({ ...item, aliases: [], catalogUrl: `${origin}/playlist?id=${id}` }); }
export async function getChapters(request) { const { kind, id } = contentId(request.id); if (kind === 'song') {
    const song = await loadSong(id), title = text(song.name) || '播放', episode = chapter(kind, id, id, title, 0);
    return frozen({ items: [episode], groups: [frozen({ id: `group:audio:song:${id}`, title: '单曲', order: 0, episodes: [episode] })] });
} const playlist = await loadPlaylist(id), items = records(playlist.tracks).map((song, index) => { const songId = nativeId(song.id); return songId === null ? null : chapter(kind, id, songId, `${text(song.name) || songId}${artists(song) !== '' ? ` - ${artists(song)}` : ''}`, index); }).filter(notNull); return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:audio:playlist:${id}`, title: '歌曲列表', order: 0, episodes: items })] }); }
export async function getContent(request) { const content = contentId(request.id), songId = chapterSong(request.chapterId, content.kind, content.id), api = `https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=${encodeURIComponent(songId)}&br=320`, json = await fetchJson(api), model = isObject(json.data) ? json.data : json, upstream = text(model.url), size = number(model.size); if (!safeUrl(upstream) || size > 0 && size < 1000000)
    throw new Error('Audio address is unavailable.'); const mediaHeaders = { Referer: `${origin}/`, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers: mediaHeaders }), resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: /\.m4a(?:$|[?#])/iu.test(upstream) ? 'audio/mp4' : 'audio/mpeg', headers: mediaHeaders } }); }
async function loadChart(id, size) { const playlist = await loadPlaylist(id); return records(playlist.tracks).map(songSummary).filter(notNull).slice(0, size); }
async function loadPlaylists(page, size) { const offset = (page - 1) * size, json = await fetchJson(`${origin}/api/playlist/list?cat=${encodeURIComponent('全部')}&order=hot&offset=${offset}&total=true&limit=${size}`); return records(json.playlists).map(playlistSummary); }
async function loadPlaylist(id) { const json = await fetchJson(`${origin}/api/playlist/detail?id=${encodeURIComponent(id)}&n=1000&s=0`), playlist = object(first(json.playlist, json.result)); if (nativeId(playlist.id) === null)
    throw new Error('Playlist is unavailable.'); return playlist; }
async function loadSong(id) { const json = await fetchJson(`${origin}/api/song/detail?ids=${encodeURIComponent(`[${id}]`)}`), song = records(json.songs)[0]; if (song === undefined)
    throw new Error('Song is unavailable.'); return song; }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.json(); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function songSummary(song) { const id = nativeId(song.id); if (id === null)
    return null; const album = object(first(song.al, song.album)), author = artists(song), cover = text(first(album.picUrl, album.blurPicUrl)), duration = durationText(first(song.dt, song.duration)); return frozen({ id: `audio:song:${id}`, title: text(song.name) || id, contentKind: 'audio', coverOrientation: 'square', author: author || null, url: `${origin}/song?id=${id}`, coverUrl: proxyImage(cover), description: [text(album.name), duration].filter(Boolean).join(' · ') || null, language: null, status: 'completed', access: number(song.fee) === 1 ? 'paid' : 'unknown', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `audio:song:${id}:song:${id}`, title: duration || '播放', url: null, updatedAt: null }, categories: ['音乐'], tags: [], attributes: [] }); }
function playlistSummary(value) { const id = nativeId(value.id); if (id === null)
    throw new Error('Playlist ID is invalid.'); const creator = object(value.creator), count = nonNegative(value.trackCount); return frozen({ id: `audio:playlist:${id}`, title: text(value.name) || id, contentKind: 'audio', coverOrientation: 'square', author: nullable(creator.nickname), url: `${origin}/playlist?id=${id}`, coverUrl: proxyImage(text(value.coverImgUrl)), description: nullable(value.description), language: 'zh-CN', status: 'ongoing', access: 'unknown', wordCount: null, chapterCount: count, publishedAt: null, updatedAt: timestamp(value.updateTime), latestChapter: count === null ? null : { id: null, title: `${count} 首`, url: null, updatedAt: null }, categories: ['歌单'], tags: stringList(value.tags), attributes: [] }); }
function chapter(kind, contentId, songId, title, order) { return frozen({ id: `audio:${kind}:${contentId}:song:${songId}`, title, order, url: null, volumeTitle: kind === 'song' ? '单曲' : '歌曲列表', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); }
function contentId(id) { const match = /^audio:(song|playlist):(\d+)$/u.exec(id); if (match?.[1] === undefined || match[2] === undefined)
    throw new Error('Content ID is invalid.'); return { kind: match[1], id: match[2] }; }
function chapterSong(id, kind, contentId) { const song = new RegExp(`^audio:${kind}:${contentId}:song:(\\d+)$`, 'u').exec(id)?.[1]; if (song === undefined)
    throw new Error('Chapter ID is invalid.'); return song; }
function artists(song) { const values = records(first(song.ar, song.artists)); return values.map(value => text(value.name)).filter(Boolean).join('、'); }
function nativeId(value) { const id = text(value); return /^\d+$/u.test(id) ? id : null; }
function durationText(value) { const seconds = Math.floor(number(value) / 1000); if (seconds <= 0)
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
function stringList(value) { return Array.isArray(value) ? value.map(text).filter(Boolean).slice(0, 32) : []; }
function timestamp(value) { const numberValue = number(value); if (numberValue > 0)
    return new Date(numberValue).toISOString(); const raw = text(value); if (raw === '')
    return null; const date = new Date(raw); return Number.isNaN(date.valueOf()) ? null : date.toISOString(); }
function nonNegative(value) { const n = Number(value); return Number.isSafeInteger(n) && n >= 0 ? n : null; }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' || typeof value === 'bigint' ? String(value) : ''; }
function number(value) { const result = Number(value); return Number.isFinite(result) ? result : 0; }
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
