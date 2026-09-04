/**
 * 漫剧小龙原生数据源。
 *
 * 职责：直接请求并解密猫爪火龙漫剧的分类、检索、详情与播放数据。
 * 生命周期：activate 仅保存 Runtime 上下文，不使用旧脚本宿主或持久状态。
 * IO：请求走 ctx.http；封面和视频均通过 ctx.resource.proxy 输出。
 * 稳定标识：作品使用腾讯漫剧 cid，分集使用作品 ID 与详情列表顺序。
 */
import { createDecipheriv } from 'node:crypto';
const root = 'https://api.999888456.xyz/api/huolong/', headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/116.0.0.0 Safari/537.36', Accept: 'application/json, text/plain, */*' }, channels = [{ id: 'manju', title: '漫剧' }, { id: 'rank_hot_play_comics', title: '漫榜' }, { id: 'rank_hot_play_drama', title: '剧榜' }, { id: 'rank_hot_search', title: '热搜榜' }];
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), values = list(await api(`search?wd=${encodeURIComponent(query)}&pg=${page}`)), items = summaries(values).slice(0, clamp(request.pageSize)); return frozen({ items, nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'huolong-channels', title: '漫剧小龙', subtitle: '腾讯漫剧与榜单', icon: 'video', children: [{ type: 'categoryCollection', id: 'huolong-channel-list', layout: 'chips', categories: channels.map(channel => ({ id: channel.id, title: channel.title, target: `channel:${channel.id}`, count: null, url: null, icon: 'video' })) }] }] } }); const channel = channels.find(value => request.target === `channel:${value.id}`); if (channel === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), values = list(await api(`category?tid=${encodeURIComponent(channel.id)}&pg=${page}&itype=-1&setting=-1&attraction=-1&item=-1&sort=-1`)), contents = summaries(values).slice(0, size), collectionId = `huolong:${channel.id}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${channel.id}:${page + 1}` }) : null; if (request.collectionId !== null)
    return request.collectionId === collectionId ? frozen({ kind: 'append', collectionId, items, continuation }) : Promise.reject(new Error('Discovery collection is invalid.')); return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel.title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), value = await detail(id); return frozen({ ...summary(value, id), aliases: [], catalogUrl: `${root}detail?id=${encodeURIComponent(JSON.stringify({ cid: id }))}` }); }
export async function getChapters(request) { const id = contentId(request.id), value = await detail(id), episodes = split(text(first(value.vod_play_url, value.play_url))), items = episodes.map((episode, index) => frozen({ id: `video:${id}:${index}`, title: episode.title, order: index, url: null, volumeTitle: '视频', wordCount: null, updatedAt: null, isLocked: false, attributes: [] })); return frozen({ items, groups: items.length ? [frozen({ id: `group:${id}:main`, title: '视频', order: 0, episodes: items })] : [] }); }
export async function getContent(request) { const id = contentId(request.id), index = chapterIndex(request.chapterId, id), episodes = split(text(first((await detail(id)).vod_play_url))), episode = episodes[index]; if (episode === undefined)
    throw new Error('Video episode is unavailable.'); const upstream = pickUrl(await api(`play?id=${encodeURIComponent(episode.url)}`)); if (!safeUrl(upstream))
    throw new Error('Video address is unavailable.'); const mediaHeaders = { Referer: 'https://v.qq.com/', 'User-Agent': headers['User-Agent'] }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: episode.title, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'video', url: upstream, headers: mediaHeaders }), resourceType: 'video', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function detail(id) { const values = list(await api(`detail?id=${encodeURIComponent(JSON.stringify({ cid: id }))}`)); if (values[0] === undefined)
    throw new Error('Video detail is unavailable.'); return values[0]; }
async function api(path) { const response = await requireContext().http.fetch(new URL(path, root).toString(), { headers }); if (!response.ok)
    throw new Error('Source request failed.'); const raw = (await response.text()).trim(), plain = decrypt(raw); try {
    return JSON.parse(plain);
}
catch {
    throw new Error('Source response is invalid.');
} }
function decrypt(raw) { if (raw.startsWith('{') || raw.startsWith('['))
    return raw; const parts = raw.split('.'); if (parts.length < 3)
    throw new Error('Encrypted response is invalid.'); const keyIv = derive(parts[1] ?? ''), decipher = createDecipheriv('aes-128-cbc', keyIv.subarray(0, 16), keyIv.subarray(16, 32)); return Buffer.concat([decipher.update(Buffer.from(parts[2] ?? '', 'base64')), decipher.final()]).toString('utf8'); }
function derive(token) { const bytes = Buffer.from(token.slice(4), 'hex'), mask = [104, 64, 70, 166, 190, 168, 143, 130, 225, 254, 251, 217, 196, 34, 45, 60, 29, 20, 103, 105], out = Buffer.alloc(bytes.length); for (let i = 0; i < bytes.length; i++) {
    const r = i % mask.length, r0 = bytes[i] ?? 0, r1 = i === 0 ? 109 : (bytes[i - 1] ?? 0), r2 = ((mask[r] ?? 0) ^ ((90 + r * 13) & 255) ^ 85) & 255, r3 = (r0 + 215 - 11 * i) & 255, r4 = ((r3 << 3) | (r3 >>> 5)) & 255, r5 = (~(r2 ^ r1)) & 255, r6 = (r5 & 54) | ((~r5 & 255) & 201), r7 = ((~r4 & 255) & 54) | (r4 & 201);
    out[i] = (r6 ^ r7) & 255;
} if (out.length < 32)
    throw new Error('Encrypted response key is invalid.'); return out; }
function list(value) { if (Array.isArray(value))
    return value.filter(isObject); if (!isObject(value))
    return []; if (Array.isArray(value.list))
    return value.list.filter(isObject); const data = isObject(value.data) ? value.data : null; if (data && Array.isArray(data.list))
    return data.list.filter(isObject); return []; }
function summaries(values) { const result = new Map(); for (const value of values) {
    const id = nativeId(first(value.vod_id, value.id));
    if (id !== null && text(first(value.vod_name, value.title)) !== '')
        result.set(id, summary(value, id));
} return [...result.values()]; }
function summary(value, id) { const title = text(first(value.vod_name, value.title)) || id, remark = nullable(first(value.vod_remarks, value.remark)); return frozen({ id: `video:${id}`, title, contentKind: 'video', coverOrientation: 'portrait', author: null, url: `${root}detail?id=${encodeURIComponent(JSON.stringify({ cid: id }))}`, coverUrl: proxyImage(text(first(value.vod_pic, value.cover))), description: nullable(first(value.vod_content, value.description, remark)), language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: countHint(remark), publishedAt: null, updatedAt: null, latestChapter: null, categories: stringList(value.type_name), tags: stringList(value.tags), attributes: [] }); }
function split(raw) { return raw.split('$$$').flatMap(group => group.split('#')).map((row, index) => { const at = row.indexOf('$'); return { title: at >= 0 ? row.slice(0, at) || `第 ${index + 1} 集` : `第 ${index + 1} 集`, url: at >= 0 ? row.slice(at + 1) : row }; }).filter(value => value.url !== ''); }
function nativeId(value) { const raw = text(value); if (/^[-\w]+$/u.test(raw))
    return raw; try {
    const parsed = JSON.parse(raw);
    if (isObject(parsed)) {
        const id = text(first(parsed.cid, parsed.vid, parsed.id));
        return /^[-\w]+$/u.test(id) ? id : null;
    }
}
catch { } return null; }
function contentId(id) { const value = /^video:([-\w]+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function chapterIndex(id, content) { const value = new RegExp(`^video:${content}:(\\d+)$`, 'u').exec(id)?.[1], index = Number(value); if (value === undefined || !Number.isSafeInteger(index))
    throw new Error('Chapter ID is invalid.'); return index; }
function pickUrl(value) { if (typeof value === 'string')
    return safeUrl(value) ? value : ''; if (Array.isArray(value)) {
    for (const item of value) {
        const found = pickUrl(item);
        if (found)
            return found;
    }
    return '';
} if (!isObject(value))
    return ''; for (const candidate of [value.url, value.play_url, value.playUrl, value.video_url, value.videoUrl, value.data]) {
    const found = pickUrl(candidate);
    if (found)
        return found;
} return ''; }
function proxyImage(url) { return safeUrl(url) ? requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: 'https://api.999888456.xyz/' } }) : null; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function countHint(value) { const match = value?.match(/(\d+)\s*集/u)?.[1], count = Number(match); return Number.isSafeInteger(count) ? count : null; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function stringList(value) { const raw = text(value); return raw === '' ? [] : raw.split(/[·,，/]/u).map(part => part.trim()).filter(Boolean); }
function first(...values) { return values.find(v => v !== null && v !== undefined && v !== '') ?? ''; }
function text(v) { return typeof v === 'string' ? v.trim() : typeof v === 'number' ? String(v) : ''; }
function nullable(v) { const s = text(v); return s || null; }
function isObject(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
function clamp(v) { return Math.max(1, Math.min(50, Math.floor(v))); }
function frozen(v) { return Object.freeze(v); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
