/**
 * 星芽短剧原生数据源。
 *
 * 职责：实现匿名设备登录并直接读取星芽分类、检索、详情和分集视频。
 * 生命周期：activate 清空进程内 token；token 仅在当前插件会话复用，不写系统存储。
 * IO：登录和业务请求走 ctx.http；封面与视频仅经 ctx.resource.proxy 输出。
 * 稳定标识：作品使用 theater_parent ID，章节使用 theater ID 或集数。
 */
import { createCipheriv, createHash } from 'node:crypto';
const root = 'https://app.whjzjx.cn/', loginUrl = 'https://u.shytkjgs.com/user/v3/account/login', agent = 'okhttp/4.10.0', baseHeaders = { 'User-Agent': agent, platform: '1', version_name: '3.9.2' };
let context, tokenPromise, channelsPromise;
export async function activate(next) { context = next; tokenPromise = undefined; channelsPromise = undefined; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); if (request.cursor !== null)
    throw new Error('Cursor is invalid.'); const response = await postJson('v3/search', { text: query }), data = object(response.data), theater = object(data.theater), values = records(theater.search_data), items = summaries(values).slice(0, clamp(request.pageSize)); return frozen({ items, nextCursor: null, totalCount: items.length }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    const channels = await loadChannels();
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'xingya-channels', title: '星芽短剧', subtitle: '云端短剧分类', icon: 'video', children: [{ type: 'categoryCollection', id: 'xingya-channel-list', layout: 'chips', categories: channels.map(channel => ({ id: channel.id, title: channel.title, target: `channel:${channel.id}`, count: null, url: null, icon: 'video' })) }] }] } });
} const channels = await loadChannels(), channel = channels.find(value => request.target === `channel:${value.id}`); if (!channel)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), response = await getJson(`cloud/v2/theater/home_page?theater_class_id=${encodeURIComponent(channel.id)}&class2_ids=0&type=1&page_num=${page}&page_size=24`), values = records(object(response.data).list), contents = summaries(values).slice(0, size), collectionId = `xingya:${channel.id}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${channel.id}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel.title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), data = await detail(id), item = summary(data, id); return frozen({ ...item, aliases: [], catalogUrl: `${root}v2/theater_parent/detail?theater_parent_id=${encodeURIComponent(id)}`, chapterCount: records(data.theaters).length }); }
export async function getChapters(request) { const id = contentId(request.id), episodes = records((await detail(id)).theaters), items = episodes.map((value, index) => chapter(id, value, index)); return frozen({ items, groups: items.length ? [frozen({ id: `group:${id}:main`, title: '默认线路', order: 0, episodes: items })] : [] }); }
export async function getContent(request) { const id = contentId(request.id), native = chapterNative(request.chapterId, id), episodes = records((await detail(id)).theaters), episode = episodes.find((value, index) => episodeId(value, index) === native), upstream = text(episode?.son_video_url); if (!safeUrl(upstream))
    throw new Error('Video address is unavailable.'); const mediaHeaders = { 'User-Agent': 'Mozilla/5.0' }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: episode ? `第${text(first(episode.num, episode.episode_num)) || native}集` : null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'video', url: upstream, headers: mediaHeaders }), resourceType: 'video', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function loadChannels() { if (!channelsPromise)
    channelsPromise = (async () => { const response = await getJson('cloud/v2/theater/classes'), values = records(object(response.data).list), result = values.filter(value => !text(value.show_type).includes('Bookstore')).map(value => ({ id: text(value.id), title: text(value.class_name) })).filter(value => value.id && value.title); return result.length ? result : [{ id: '1', title: '推荐' }]; })(); return channelsPromise; }
async function detail(id) { const response = await getJson(`v2/theater_parent/detail?theater_parent_id=${encodeURIComponent(id)}`), data = object(response.data); if (text(data.id) === '' && text(data.title) === '')
    throw new Error('Video detail is unavailable.'); return data; }
async function getJson(path) { const response = await requireContext().http.fetch(new URL(path, root).toString(), { headers: await authorizedHeaders() }); return parseResponse(response); }
async function postJson(path, body) { const response = await requireContext().http.fetch(new URL(path, root).toString(), { method: 'POST', headers: { ...await authorizedHeaders(), 'Content-Type': 'application/json' }, body: JSON.stringify(body) }); return parseResponse(response); }
async function parseResponse(response) { if (!response.ok)
    throw new Error('Source request failed.'); let value; try {
    value = JSON.parse(await response.text());
}
catch {
    throw new Error('Source response is invalid.');
} if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
async function authorizedHeaders() { return { ...baseHeaders, Authorization: await getToken() }; }
async function getToken() { if (!tokenPromise)
    tokenPromise = (async () => { const now = Date.now(), device = createHash('md5').update(String(now)).digest('hex'), plain = JSON.stringify({ first_install_time: now, last_update_time: now, install_first_open: true, package_name: 'com.jz.xydj', device, timestamp: now }), cipher = createCipheriv('aes-128-ecb', Buffer.from('B@ecf920Od8A4df7'), null), body = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]).toString('base64'), response = await requireContext().http.fetch(loginUrl, { method: 'POST', headers: { ...baseHeaders, 'Content-Type': 'application/json; charset=utf-8' }, body }); if (!response.ok)
        throw new Error('Source login failed.'); const value = object(JSON.parse(await response.text())), token = text(object(value.data).token); if (!token)
        throw new Error('Source login did not return a token.'); return token; })(); try {
    return await tokenPromise;
}
catch (error) {
    tokenPromise = undefined;
    throw error;
} }
function summaries(values) { const result = new Map(); for (const raw of values) {
    const value = isObject(raw.theater) ? raw.theater : raw, id = sourceId(value.id);
    if (id && text(value.title))
        result.set(id, summary(value, id));
} return [...result.values()]; }
function summary(value, id) { const finished = value.finish === true || Number(value.finish) === 1, total = nonNegative(value.total); return frozen({ id: `theater:${id}`, title: text(value.title) || id, contentKind: 'video', coverOrientation: 'portrait', author: null, url: `${root}v2/theater_parent/detail?theater_parent_id=${encodeURIComponent(id)}`, coverUrl: proxyImage(text(value.cover_url)), description: nullable(first(value.introduction, value.description)), language: 'zh-CN', status: finished ? 'completed' : 'ongoing', access: 'unknown', wordCount: null, chapterCount: total, publishedAt: null, updatedAt: null, latestChapter: total === null ? null : { id: `theater:${id}:latest`, title: `共${total}集`, url: null, updatedAt: null }, categories: stringList(value.desc_tags), tags: [], attributes: [] }); }
function chapter(id, value, index) { const native = episodeId(value, index), number = text(first(value.num, value.episode_num)) || String(index + 1); return frozen({ id: `theater:${id}:${native}`, title: `第${number}集`, order: index, url: null, volumeTitle: '默认线路', wordCount: null, updatedAt: null, isLocked: false, attributes: [] }); }
function episodeId(value, index) { const id = text(first(value.id, value.theater_id, value.num, value.episode_num)); return /^[\w-]+$/u.test(id) ? id : String(index + 1); }
function sourceId(value) { const id = text(value); return /^[\w-]+$/u.test(id) ? id : null; }
function contentId(id) { const value = /^theater:([\w-]+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function chapterNative(id, content) { const value = new RegExp(`^theater:${content}:([\\w-]+)$`, 'u').exec(id)?.[1]; if (!value)
    throw new Error('Chapter ID is invalid.'); return value; }
function proxyImage(url) { return safeUrl(url) ? requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: root } }) : null; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function nonNegative(value) { const number = Number(value); return Number.isSafeInteger(number) && number >= 0 ? number : null; }
function stringList(value) { return Array.isArray(value) ? value.map(text).filter(Boolean) : []; }
function object(value) { return isObject(value) ? value : {}; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function nullable(value) { return text(value) || null; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
