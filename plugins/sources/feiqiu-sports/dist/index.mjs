/**
 * 飞球体育原生数据源。
 *
 * 职责：独立实现飞球设备令牌及 AES-CBC 协议，读取赛程、直播间和播放地址。
 * 生命周期：activate 注入 Runtime；设备 ID 仅存在于当前插件进程，不读取系统存储。
 * IO：域名、赛程和播放请求走 ctx.http；队标和媒体经 ctx.resource.proxy。
 * 稳定标识：赛事使用 match_id + sport_id，直播章节使用 room_id。
 */
import { createCipheriv, createDecipheriv, randomUUID } from 'node:crypto';
const domainConfig = 'https://pullcfg.butueaa.cn/domain/master/raw/18', defaultApi = 'http://api.j9y5m8k8w7q9h8a.xyz', key = Buffer.from('zNuZTzWqOliEgJAL', 'utf8'), categories = Object.freeze([['1', '足球'], ['2', '篮球'], ['101', '电竞'], ['3', '其他']]);
let context, deviceId = '', baseToken = '', apiBase = defaultApi, playApi = '';
export async function activate(next) { context = next; deviceId = ''; baseToken = ''; apiBase = defaultApi; playApi = ''; next.log.info('source_activated'); }
export async function search(request) { if (request.cursor !== null)
    throw new Error('Search cursor is unsupported.'); const query = request.query.trim().toLocaleLowerCase('zh-CN'); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const groups = await Promise.all(categories.map(([id]) => loadMatches(id))), values = groups.flat().filter(item => JSON.stringify(item).toLocaleLowerCase('zh-CN').includes(query)).slice(0, clamp(request.pageSize)).map(matchSummary); return frozen({ items: values, nextCursor: null, totalCount: values.length }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'feiqiu-categories', title: '飞球体育', subtitle: '按赛事类型浏览', icon: 'video', children: [{ type: 'categoryCollection', id: 'feiqiu-category-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const category = categories.find(([id]) => request.target === `category:${id}`); if (category === undefined)
    throw new Error('Discovery target is invalid.'); if (request.cursor !== null)
    throw new Error('Discovery cursor is unsupported.'); const [sportId, title] = category, values = (await loadMatches(sportId)).slice(0, clamp(request.pageSize)).map(matchSummary), collectionId = `feiqiu:${sportId}`, items = values.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const { id: matchId, sportId } = contentId(request.id), row = (await loadMatches(sportId)).find(item => text(item.match_id) === matchId) ?? { match_id: matchId, sport_id: sportId }, item = matchSummary(row); return frozen({ ...item, description: `${item.description ?? ''}\n不要相信视频中的任何广告。`.trim(), aliases: [], catalogUrl: null }); }
export async function getChapters(request) { const { id: matchId, sportId } = contentId(request.id); await initialize(); const payload = encrypt(JSON.stringify({ sport_id: sportId, match_id: matchId, page: '0', page_size: '18' })), json = await getJson(`${apiBase}/v171/matchs_live?data=${encodeURIComponent(payload)}`), rows = pickRows(json), seen = new Set(), items = []; for (const row of rows) {
    const roomId = text(first(row.chatroom_id, row.room_id, row.id));
    if (roomId === '' || seen.has(roomId))
        continue;
    seen.add(roomId);
    items.push(frozen({ id: `sports:${encodeKey(`${matchId}|${sportId}`)}:${encodeKey(roomId)}`, title: text(first(row.user_nickname, row.nickname, row.name, row.room_title)) || roomId, order: items.length, url: null, volumeTitle: '直播间', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }));
} return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:${encodeKey(`${matchId}|${sportId}`)}:live`, title: '直播间', order: 0, episodes: items })] }); }
export async function getContent(request) { const { id: matchId, sportId } = contentId(request.id), roomId = chapterRoom(request.chapterId, matchId, sportId); await initialize(); const roomPayload = encrypt(JSON.stringify({ room_id: roomId, sport_id: sportId, match_id: matchId })); try {
    await getJson(`${apiBase}/v131/room?data=${encodeURIComponent(roomPayload)}`);
}
catch { } const playPayload = encrypt(JSON.stringify({ room_id: roomId, sport_id: sportId, match_id: matchId, code_id: 'gqzm' })), response = await requireContext().http.fetch(`${playApi}/v230/play/url`, { method: 'POST', headers: { ...requestHeaders(), 'Content-Type': 'application/x-www-form-urlencoded' }, body: `data=${encodeURIComponent(playPayload)}` }); if (!response.ok)
    throw new Error('Playback request failed.'); const raw = await response.text(), json = parseDecoded(raw), upstream = scanUrl(json); if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video', mediaHeaders = { 'User-Agent': 'okhttp/4.2.2' }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function initialize() { if (deviceId !== '' && baseToken !== '')
    return; deviceId = randomUUID(); baseToken = encrypt(JSON.stringify({ 'api-version': '11', 'im-uid': '', 'invit-code': '', version: '2.3.6', 'os-ver': '9', imid: '', 'phone-model': '22081212C', imtoken: '', 'dun-imei': '', imei: deviceId, device: '1' })); try {
    const response = await requireContext().http.fetch(domainConfig, { headers: { 'User-Agent': 'okhttp/4.2.2' } });
    if (response.ok) {
        const decoded = parseDecoded(await response.text());
        if (Array.isArray(decoded) && typeof decoded[0] === 'string' && decoded[0] !== '')
            apiBase = decoded[0];
    }
}
catch { } try {
    const domain = await getJson(`${apiBase}/v191/domain`), rawList = object(domain.data).openim_zb_api_list, direct = Array.isArray(rawList) ? rawList : [], firstDomain = direct[0];
    if (typeof firstDomain === 'string' && firstDomain !== '')
        playApi = firstDomain;
    else {
        const firstLine = records(rawList)[0];
        if (firstLine !== undefined)
            playApi = text(first(firstLine.url, firstLine.domain));
    }
}
catch { } if (playApi === '')
    playApi = apiBase; }
async function loadMatches(sportId) { await initialize(); const payload = encrypt(JSON.stringify({ sport_id: sportId, tab: '0', hot: '0' })), json = await getJson(`${apiBase}/v220/schedule?data=${encodeURIComponent(payload)}`), groups = records(object(json.data).list), values = []; for (const group of groups)
    for (const row of records(group.list))
        values.push({ ...row, sport_id: first(row.sport_id, sportId) }); return values; }
async function getJson(url) { const response = await requireContext().http.fetch(url, { headers: requestHeaders() }); if (!response.ok)
    throw new Error('Source request failed.'); const value = parseDecoded(await response.text()); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function requestHeaders() { return { 'User-Agent': 'okhttp/4.2.2', imei: deviceId, device: '1', platform: 'fqzb', base: baseToken }; }
function parseDecoded(raw) { const trimmed = raw.trim(); if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const value = JSON.parse(trimmed);
    if (isObject(value) && typeof value.data === 'string') {
        try {
            return JSON.parse(decrypt(value.data.replaceAll('\\', '')));
        }
        catch {
            return value;
        }
    }
    return value;
} try {
    return JSON.parse(decrypt(trimmed.replaceAll('\\', '')));
}
catch {
    return {};
} }
function encrypt(value) { const cipher = createCipheriv('aes-128-cbc', key, key); return Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]).toString('base64'); }
function decrypt(value) { const decipher = createDecipheriv('aes-128-cbc', key, key); return Buffer.concat([decipher.update(Buffer.from(value, 'base64')), decipher.final()]).toString('utf8'); }
function matchSummary(row) { const matchId = text(first(row.match_id, row.id)), sportId = text(first(row.sport_id, '1')); if (matchId === '')
    throw new Error('Match has no ID.'); const home = text(first(row.home_name, row.home)), away = text(first(row.away_name, row.away)), nativeTitle = text(row.title) || [home, away].filter(Boolean).join(' vs ') || matchId, start = nullable(first(row.match_date, row.start_time)), league = nullable(first(row.alias_name, row.competition_name, row.league_name)), status = number(row.live_status) === 1 ? '直播中' : number(row.match_status) === 2 ? '比赛中' : number(row.match_status) >= 3 ? '已结束' : '未开赛', keyValue = `${matchId}|${sportId}`, id = encodeKey(keyValue); return frozen({ id: `sports:${id}`, title: start === null ? nativeTitle : `[${start.slice(5, 16)}] ${nativeTitle}`, contentKind: 'video', coverOrientation: 'landscape', author: league, url: null, coverUrl: proxyImage(text(first(row.home_logo, row.home_team_logo, row.cover))), description: start === null ? `状态：${status}` : `开赛时间：${start.slice(0, 19)}\n状态：${status}`, language: 'zh-CN', status: 'unknown', access: 'free', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: { id: null, title: status, url: null, updatedAt: null }, categories: league === null ? [] : [league], tags: [], attributes: [] }); }
function contentId(id) { const encoded = /^sports:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); const [matchId, sportId] = decodeKey(encoded).split('|'); if (!matchId || !sportId)
    throw new Error('Content ID is invalid.'); return { id: matchId, sportId }; }
function chapterRoom(chapterId, matchId, sportId) { const prefix = `sports:${encodeKey(`${matchId}|${sportId}`)}:`; if (!chapterId.startsWith(prefix))
    throw new Error('Chapter ID is invalid.'); return decodeKey(chapterId.slice(prefix.length)); }
function pickRows(json) { for (const value of [json.data, object(json.data).list, object(json.data).rows]) {
    if (Array.isArray(value))
        return value.filter(isObject);
} return []; }
function scanUrl(value, depth = 0) { if (depth > 8 || value === null || value === undefined)
    return ''; if (typeof value === 'string') {
    const match = value.match(/(?:https?):\\?\/\\?\/[^\s"'<>\\]+/iu);
    return match ? match[0].replaceAll('\\/', '/') : '';
} if (Array.isArray(value)) {
    for (const item of value) {
        const result = scanUrl(item, depth + 1);
        if (result !== '')
            return result;
    }
    return '';
} if (isObject(value)) {
    for (const key of ['play_url', 'playUrl', 'playurl', 'url', 'm3u8', 'flv', 'pull_url', 'pullUrl', 'stream_url', 'src']) {
        const result = scanUrl(value[key], depth + 1);
        if (result !== '')
            return result;
    }
    for (const item of Object.values(value)) {
        const result = scanUrl(item, depth + 1);
        if (result !== '')
            return result;
    }
} return ''; }
function proxyImage(value) { if (!safeUrl(value))
    return null; return requireContext().resource.proxy({ kind: 'image', url: value, headers: { 'User-Agent': 'okhttp/4.2.2' } }); }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function encodeKey(value) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeKey(value) { if (!/^[A-Za-z0-9_-]+$/u.test(value))
    throw new Error('Source key is invalid.'); return Buffer.from(value, 'base64url').toString('utf8'); }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function object(value) { return isObject(value) ? value : {}; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function number(value) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; }
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
