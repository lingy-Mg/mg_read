const origin = 'https://www.kuwo.cn', headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }), channels = Object.freeze([['hot', '热歌榜', '16'], ['new', '新歌榜', '17'], ['rising', '飙升榜', '93']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), size = clamp(request.pageSize), json = await fetchJson(`http://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(query)}&pn=${page - 1}&rn=${size}&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1`), items = records(json.abslist).map(songSummary).filter(notNull), totalCount = nonNegative(first(json.TOTAL, json.total)); return frozen({ items, nextCursor: totalCount !== null ? page * size < totalCount ? `search:${page + 1}` : null : items.length >= size ? `search:${page + 1}` : null, totalCount }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'kuwo-charts', title: '酷我音乐', subtitle: '官方榜单', icon: 'audio', children: [{ type: 'categoryCollection', id: 'kuwo-chart-list', layout: 'chips', categories: channels.map(([id, title]) => ({ id, title, target: `chart:${id}`, count: null, url: null, icon: 'ranking' })) }] }] } });
} const channel = channels.find(([id]) => request.target === `chart:${id}`); if (channel === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, `chart:${channel[0]}`), size = clamp(request.pageSize), json = await fetchJson(`http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=${page - 1}&rn=${size}&type=bang&data=content&id=${channel[2]}&show_copyright_off=0&pcmp4=1&isbang=1`), values = records(json.musiclist).map(songSummary).filter(notNull), collectionId = `audio:${channel[0]}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `chart:${channel[0]}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel[1], subtitle: null, icon: 'audio', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), json = await fetchJson(`http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=${encodeURIComponent(id)}`), song = object(first(object(json.data).songinfo, json.songinfo, json.data)), item = songSummary({ ...song, id }); if (item === null)
    throw new Error('Song detail is unavailable.'); return frozen({ ...item, aliases: [], catalogUrl: `${origin}/play_detail/${id}` }); }
export async function getChapters(request) { const id = contentId(request.id), detail = await getDetail(request), chapter = frozen({ id: `audio:${id}:main`, title: `${detail.title}${detail.author ? ` - ${detail.author}` : ''}`, order: 0, url: null, volumeTitle: '单曲', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); return frozen({ items: [chapter], groups: [frozen({ id: `group:audio:${id}`, title: '单曲', order: 0, episodes: [chapter] })] }); }
export async function getContent(request) { const id = contentId(request.id); if (request.chapterId !== `audio:${id}:main`)
    throw new Error('Chapter ID is invalid.'); const upstream = `https://musicapi.haitangw.net/music1/kw.php?type=mp3&id=${encodeURIComponent(id)}&level=exhigh`, mediaHeaders = { Referer: 'https://musicapi.haitangw.net/', 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'audio', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers: mediaHeaders }), resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: 'audio/mpeg', headers: mediaHeaders } }); }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const raw = await response.text(); let value; try {
    value = JSON.parse(raw);
}
catch {
    throw new Error('Source response is invalid.');
} if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function songSummary(song) { const id = musicId(first(song.id, song.MUSICRID, song.musicrid)); if (id === null)
    return null; const title = text(first(song.name, song.SONGNAME, song.NAME)) || id, author = nullable(first(song.artist, song.ARTIST, song.FARTIST)), album = text(first(song.album, song.ALBUM)), duration = durationText(first(song.duration, song.DURATION)), cover = coverUrl(text(first(song.pic, song.web_albumpic_short, song.albumpic))); return frozen({ id: `audio:${id}`, title, contentKind: 'audio', coverOrientation: 'square', author, url: `${origin}/play_detail/${id}`, coverUrl: proxyImage(cover), description: [album, duration].filter(Boolean).join(' · ') || null, language: null, status: 'completed', access: text(first(song.PAY, song.pay)) === '0' ? 'free' : 'unknown', wordCount: null, chapterCount: 1, publishedAt: null, updatedAt: null, latestChapter: { id: `audio:${id}:main`, title: duration || '播放', url: null, updatedAt: null }, categories: ['音乐'], tags: [], attributes: [] }); }
function musicId(value) { const id = text(value).replace(/^MUSIC_/u, ''); return /^\d+$/u.test(id) ? id : null; }
function contentId(id) { const value = /^audio:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function durationText(value) { const seconds = Math.floor(number(value)); if (seconds <= 0)
    return ''; return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`; }
function coverUrl(value) { if (value === '' || safeUrl(value))
    return value; return `https://img2.kuwo.cn/star/albumcover/${value.replace(/^\/+/, '')}`; }
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
function text(value) { return typeof value === 'string' ? value.replace(/&nbsp;/gu, ' ').replace(/<[^>]+>/gu, '').trim() : typeof value === 'number' ? String(value) : ''; }
function number(value) { const result = Number(value); return Number.isFinite(result) ? result : 0; }
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function notNull(value) { return value !== null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
