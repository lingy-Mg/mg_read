/**
 * 咖啡体育原生数据源。
 *
 * 职责：直接调用咖啡体育赛程与直播间 JSON 接口，生成赛事和可播放线路。
 * 生命周期：activate 注入 Runtime 上下文；赛事数据按请求即时获取，不保存会话。
 * IO：API 请求走 ctx.http；封面与直播流只通过 ctx.resource.proxy 输出。
 * 稳定标识：赛事使用上游 match/room ID，线路使用上游 ID 或流地址摘要。
 */
import { createHash } from 'node:crypto';
const base = 'https://www.kafeizhibo.cc/api/v1';
const web = 'https://www.kafeizhibo.cc/';
const headers = Object.freeze({ Accept: 'application/json,text/plain,*/*', Origin: 'https://www.kafeizhibo.cc', Referer: web, 'User-Agent': 'Mozilla/5.0' });
const categories = Object.freeze([['all', '全部'], ['hot', '热门'], ['1', '足球'], ['2', '篮球']]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) {
    const query = request.query.trim().toLocaleLowerCase('zh-CN');
    if (query === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const page = cursorPage(request.cursor, 'search');
    const values = (await schedule('all', page, Math.max(30, clamp(request.pageSize)))).filter(item => JSON.stringify(item).toLocaleLowerCase('zh-CN').includes(query)).slice(0, clamp(request.pageSize));
    return frozen({ items: values.map(summary), nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: null });
}
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'sports-categories', title: '体育直播', subtitle: '按项目浏览赛程', icon: 'video', children: [{ type: 'categoryCollection', id: 'sports-categories-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }] }] } });
    }
    const category = categories.find(([id]) => request.target === `category:${id}`);
    if (category === undefined)
        throw new Error('Discovery target is invalid.');
    const page = cursorPage(request.cursor, request.target), limit = clamp(request.pageSize), [id, title] = category;
    const values = (await schedule(id, page, limit)).slice(0, limit), collectionId = `sports:${id}`;
    const items = values.map(value => frozen({ content: summary(value), rank: null, metric: null, recommendation: null }));
    const continuation = values.length >= limit ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId, items, continuation });
    }
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } });
}
export async function getDetail(request) { const id = contentId(request.id), data = await room(id), info = roomInfo(data), item = summary({ ...info, id }); return frozen({ ...item, aliases: [], catalogUrl: item.url }); }
export async function getChapters(request) { const id = contentId(request.id), data = await room(id), info = roomInfo(data); if (!isLive(first(info.status, data.status)))
    return frozen({ items: [], groups: [] }); const signals = collectSignals(data, info); const items = signals.map((signal, index) => chapter(id, signal, index)); const group = frozen({ id: `group:${encodeKey(id)}:live`, title: '直播线路', order: 0, episodes: items }); return frozen({ items, groups: items.length === 0 ? [] : [group] }); }
export async function getContent(request) { const id = contentId(request.id), key = chapterKey(request.chapterId, id), data = await room(id), info = roomInfo(data), signals = collectSignals(data, info); const signal = signals.find((value, index) => signalKey(value, index) === key); if (signal === undefined)
    throw new Error('Chapter ID is invalid.'); const upstream = signalUrl(signal); if (!safeUrl(upstream))
    throw new Error('Playback address is unavailable.'); const resourceType = /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'hls' : 'video'; const mediaHeaders = { Referer: web, 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: text(first(signal.name, signal.title, signal.nickname)) || '直播', updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: resourceType, url: upstream, headers: mediaHeaders }), resourceType, resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function schedule(type, page, size) { const json = await fetchJson(`${base}/schedule?size=${size}&page=${page}&type=${encodeURIComponent(type)}&platform=h5`); return pickList(json); }
async function room(id) { const json = await fetchJson(`${base}/room/${encodeURIComponent(id)}`); return isObject(json.data) ? json.data : json; }
async function fetchJson(url) { const response = await requireContext().http.fetch(url, { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const value = await response.json(); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function summary(item) { const native = text(first(item.id, item.match_id, item.room_id, item.live_id)); if (native === '')
    throw new Error('Source item has no ID.'); const id = encodeKey(native), home = text(first(item.home_team, object(item.homeTeam).name)), away = text(first(item.away_team, object(item.awayTeam).name)), title = text(item.title) || [home, away].filter(Boolean).join(' vs ') || native, league = nullable(first(item.league_name, item.competition_name, item.league)), start = nullable(first(item.start_time, item.match_date, item.match_time_text)), state = statusText(item.status); return frozen({ id: `sports:${id}`, title: start === null ? title : `[${start.slice(0, 16)}] ${title}`, contentKind: 'video', coverOrientation: 'landscape', author: league, url: `${web}room/${encodeURIComponent(native)}`, coverUrl: proxyImage(first(item.home_team_logo, object(item.homeTeam).logo, item.away_team_logo, object(item.awayTeam).logo, item.cover, item.logo)), description: `状态：${state}\n不要相信视频中的任何广告。`, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: isLive(item.status) ? 1 : null, publishedAt: start, updatedAt: null, latestChapter: isLive(item.status) ? { id: null, title: '直播中', url: null, updatedAt: null } : null, categories: league === null ? [] : [league], tags: [], attributes: [] }); }
function roomInfo(data) { return isObject(data.room_info) ? data.room_info : isObject(data.info) ? data.info : {}; }
function collectSignals(data, info) { const values = []; for (const source of [data.signals, data.external_signals_h5, data.external_signals, data.external_signals_pc, data.archors, info.archors, data.archor, info.archor])
    for (const item of asRecords(source))
        if (signalUrl(item) !== '' && !values.some((old) => signalUrl(old) === signalUrl(item)))
            values.push(item); return values; }
function asRecords(value) { if (typeof value === 'string')
    return [{ url: value }]; if (Array.isArray(value))
    return value.flatMap(item => typeof item === 'string' ? [{ url: item }] : isObject(item) ? [item] : []); return isObject(value) ? [value] : []; }
function pickList(root) { for (const value of [root.list, root.data, object(root.data).list, object(object(root.data).data).list, object(root.data).rows]) {
    const list = records(value);
    if (list.length > 0)
        return list;
} return []; }
function chapter(id, signal, index) { const key = signalKey(signal, index); return frozen({ id: `sports:${encodeKey(id)}:${key}`, title: text(first(signal.name, signal.title, signal.nickname)) || `线路${index + 1}`, order: index, url: null, volumeTitle: '直播线路', wordCount: null, updatedAt: null, isLocked: null, attributes: [] }); }
function signalKey(signal, index) { const native = text(first(signal.id, signal.signal_id, signal.stream_id)); return native !== '' ? `id-${encodeKey(native)}` : `url-${createHash('sha256').update(signalUrl(signal) || String(index)).digest('hex').slice(0, 24)}`; }
function signalUrl(signal) { return text(first(signal.stream_url, signal.play_url, signal.url, signal.m3u8)); }
function contentId(id) { const encoded = /^sports:([^:]+)$/u.exec(id)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); return decodeKey(encoded); }
function chapterKey(id, content) { const prefix = `sports:${encodeKey(content)}:`; if (!id.startsWith(prefix) || id.length === prefix.length)
    throw new Error('Chapter ID is invalid.'); return id.slice(prefix.length); }
function statusText(value) { const state = text(value).toLowerCase(); if (['live', 'matching', 'living'].includes(state))
    return '直播中'; if (['finished', 'end'].includes(state))
    return '已结束'; return '未开赛'; }
function isLive(value) { return ['live', 'matching', 'living'].includes(text(value).toLowerCase()); }
function safeUrl(value) { try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
}
catch {
    return false;
} }
function proxyImage(value) { const raw = text(value); if (raw === '')
    return null; let url; try {
    url = new URL(raw, web).toString();
}
catch {
    return null;
} if (!safeUrl(url))
    return null; return requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: web, 'User-Agent': headers['User-Agent'] } }); }
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
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
