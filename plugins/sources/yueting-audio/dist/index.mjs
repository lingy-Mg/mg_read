/**
 * 悦听听书原生数据源。
 *
 * 职责：直接调用悦听分类、检索、专辑与播放接口，并实现上游协议所需的密码算法。
 * 生命周期：activate 仅保存 Runtime 上下文；每次播放生成短期 dfp，不读取系统存储。
 * IO：所有网络请求走 ctx.http；封面与音频地址只经 ctx.resource.proxy 输出。
 * 稳定标识：专辑使用上游 album ID，章节使用上游 chapter index，不包含域名或临时令牌。
 */
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
const catalogRoot = 'https://json.tingyou8.vip/azybk/json_v1/', apiRoot = 'https://tingyou.fm/api/', key = Buffer.from('ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65', 'hex'), appAgent = 'zybk/1.0.6', webAgent = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36', channels = Object.freeze([{ id: 'novel', title: '小说', category: '2', classId: '' }, { id: 'storytelling', title: '评书', category: '1', classId: '' }, { id: 'fantasy', title: '玄幻奇幻', category: '2', classId: '46' }, { id: 'wuxia', title: '武侠小说', category: '2', classId: '11' }, { id: 'romance', title: '言情通俗', category: '2', classId: '19' }, { id: 'thriller', title: '恐怖惊悚', category: '2', classId: '14' }, { id: 'history', title: '历史军事', category: '2', classId: '15' }, { id: 'radio-drama', title: '广播剧', category: '2', classId: '36' }, { id: 'children', title: '童话寓言', category: '2', classId: '20' }, { id: 'shan-tianfang', title: '单田芳', category: '1', classId: '1' }, { id: 'liu-lanfang', title: '刘兰芳', category: '1', classId: '2' }, { id: 'tian-lianyuan', title: '田连元', category: '1', classId: '3' }]);
let context;
export async function activate(next) { context = next; next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), payload = encryptRequest(JSON.stringify({ keyword: query, page })), data = decryptObject(await postPayload('search', payload, { 'User-Agent': appAgent })), values = records(data.results), items = summaries(values).slice(0, clamp(request.pageSize)); return frozen({ items, nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: nonNegative(data.total) }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null)
        throw new Error('Initial discovery request is invalid.');
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'yueting-channels', title: '悦听听书', subtitle: '按类型浏览有声专辑', icon: 'audio', children: [{ type: 'categoryCollection', id: 'yueting-channel-list', layout: 'chips', categories: channels.map(channel => ({ id: channel.id, title: channel.title, target: `channel:${channel.id}`, count: null, url: null, icon: 'audio' })) }] }] } });
} const channel = channels.find(value => request.target === `channel:${value.id}`); if (channel === undefined)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, `channel:${channel.id}`), size = clamp(request.pageSize), path = channel.classId === '' ? `categories/${channel.category}/comprehensive/p${page}` : `types/${channel.classId}/comprehensive/p${page}`, data = decryptObject(await getPayload(path)), values = records(first(data.data, data.results, data)), contents = summaries(values).slice(0, size), collectionId = `yueting:${channel.id}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${channel.id}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel.title, subtitle: null, icon: 'audio', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), data = decryptObject(await getPayload(`album_info/${encodeURIComponent(id)}`)), item = summary(data, id); return frozen({ ...item, aliases: [], catalogUrl: `${catalogRoot}album_chapters/${encodeURIComponent(id)}` }); }
export async function getChapters(request) { const id = contentId(request.id), data = decryptObject(await getPayload(`album_chapters/${encodeURIComponent(id)}`)), items = records(data.chapters).map((value, index) => chapter(id, value, index)).filter(notNull); return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:${id}:main`, title: '节目', order: 0, episodes: items })] }); }
export async function getContent(request) { const albumId = contentId(request.id), chapterIndex = chapterNative(request.chapterId, albumId), dfp = makeDfp(), cookieHeaders = { 'User-Agent': webAgent, Cookie: `dfp=${dfp}` }; await requestText(new URL('me', apiRoot).toString(), { method: 'POST', headers: cookieHeaders, body: '' }); const payload = encryptRequest(JSON.stringify({ album_id: numericId(albumId), chapter_idx: numericId(chapterIndex) })), data = decryptObject(await postPayload('play_token', payload, cookieHeaders)), upstream = text(data.play_url); if (!safeUrl(upstream))
    throw new Error('Audio address is unavailable.'); const mediaHeaders = { Referer: 'https://tingyou.fm/', 'User-Agent': webAgent }; return frozen({ chapterId: request.chapterId, contentKind: 'audio', title: nullable(data.title), updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'audio', url: upstream, headers: mediaHeaders }), resourceType: 'audio', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: /\.m4a(?:$|[?#])/iu.test(upstream) ? 'audio/mp4' : 'audio/mpeg', headers: mediaHeaders } }); }
async function getPayload(path) { const raw = await requestText(new URL(path, catalogRoot).toString(), { headers: { 'User-Agent': appAgent } }), value = parseJson(raw); return payloadOf(value); }
async function postPayload(path, body, headers) { const raw = await requestText(new URL(path, apiRoot).toString(), { method: 'POST', headers, body }), value = parseJson(raw); return payloadOf(value); }
async function requestText(url, init) { const response = await requireContext().http.fetch(url, init); if (!response.ok)
    throw new Error('Source request failed.'); return await response.text(); }
function payloadOf(value) { if (isObject(value)) {
    const payload = text(value.payload);
    if (payload !== '')
        return payload;
} const raw = text(value); if (raw !== '')
    return raw; throw new Error('Encrypted payload is missing.'); }
function encryptRequest(plain) { const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv), encrypted = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]), tag = cipher.getAuthTag(); return Buffer.concat([Buffer.from([1]), iv, encrypted, tag]).toString('hex'); }
function decryptObject(payload) { const bytes = Buffer.from(payload.replaceAll(/\s/gu, ''), 'hex'); if (bytes.length < 41)
    throw new Error('Encrypted payload is invalid.'); const version = bytes[0], nonce = bytes.subarray(1, 25), raw = bytes.subarray(25), body = version === 2 ? Buffer.from(raw).reverse() : raw, ciphertext = body.subarray(0, -16), tag = body.subarray(-16), subkey = hchacha20(key, nonce.subarray(0, 16)), nonce12 = Buffer.concat([Buffer.alloc(4), nonce.subarray(16, 24)]), decipher = createDecipheriv('chacha20-poly1305', subkey, nonce12, { authTagLength: 16 }); decipher.setAuthTag(tag); const plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8'); const value = parseJson(plain); if (!isObject(value))
    throw new Error('Source response is invalid.'); return value; }
function hchacha20(sourceKey, nonce) { const state = new Uint32Array(16), constants = Buffer.from('expand 32-byte k'); for (let index = 0; index < 4; index += 1)
    state[index] = constants.readUInt32LE(index * 4); for (let index = 0; index < 8; index += 1)
    state[index + 4] = sourceKey.readUInt32LE(index * 4); for (let index = 0; index < 4; index += 1)
    state[index + 12] = nonce.readUInt32LE(index * 4); for (let round = 0; round < 10; round += 1) {
    quarter(state, 0, 4, 8, 12);
    quarter(state, 1, 5, 9, 13);
    quarter(state, 2, 6, 10, 14);
    quarter(state, 3, 7, 11, 15);
    quarter(state, 0, 5, 10, 15);
    quarter(state, 1, 6, 11, 12);
    quarter(state, 2, 7, 8, 13);
    quarter(state, 3, 4, 9, 14);
} const output = Buffer.alloc(32), positions = [0, 1, 2, 3, 12, 13, 14, 15]; positions.forEach((position, index) => output.writeUInt32LE(state[position] ?? 0, index * 4)); return output; }
function quarter(state, a, b, c, d) { state[a] = add(state[a], state[b]); state[d] = rotate((state[d] ?? 0) ^ (state[a] ?? 0), 16); state[c] = add(state[c], state[d]); state[b] = rotate((state[b] ?? 0) ^ (state[c] ?? 0), 12); state[a] = add(state[a], state[b]); state[d] = rotate((state[d] ?? 0) ^ (state[a] ?? 0), 8); state[c] = add(state[c], state[d]); state[b] = rotate((state[b] ?? 0) ^ (state[c] ?? 0), 7); }
function add(a, b) { return ((a ?? 0) + (b ?? 0)) >>> 0; }
function rotate(value, bits) { return ((value << bits) | (value >>> (32 - bits))) >>> 0; }
function makeDfp() { const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()).replaceAll('-', ''), dailyKey = createHash('sha256').update(`fa317cd29b|${date}`).digest().subarray(0, 16), plain = `1a60ec86|212b95ee|4ec312a9||${webAgent}|Asia/Shanghai`, cipher = createCipheriv('sm4-ecb', dailyKey, null), encrypted = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]); return `f-${Number(date).toString(36)}:f-${encrypted.toString('base64')}`; }
function summaries(values) { const result = new Map(); for (const value of values) {
    const id = sourceId(first(value.id, value.album_id));
    if (id !== null && text(value.title) !== '')
        result.set(id, summary(value, id));
} return [...result.values()]; }
function summary(value, id) { const encoded = sourceId(id); if (encoded === null)
    throw new Error('Album ID is invalid.'); const cover = text(first(value.cover_url, value.cover)); return frozen({ id: `album:${encoded}`, title: text(value.title) || id, contentKind: 'audio', coverOrientation: 'portrait', author: nullable(first(value.teller, value.author)), url: `${catalogRoot}album_info/${encodeURIComponent(id)}`, coverUrl: proxyImage(cover), description: nullable(first(value.intro, value.description, value.title)), language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: nonNegative(first(value.chapter_count, value.chapterCount)), publishedAt: null, updatedAt: null, latestChapter: nullable(value.latest_chapter_title) === null ? null : { id: `album:${id}:latest`, title: text(value.latest_chapter_title), url: null, updatedAt: null }, categories: stringList(first(value.cat, value.category)), tags: [], attributes: [] }); }
function chapter(albumId, value, index) { const native = sourceId(first(value.index, value.chapter_idx, value.id)); if (native === null)
    return null; return frozen({ id: `album:${albumId}:${native}`, title: text(value.title) || `第 ${index + 1} 集`, order: index, url: null, volumeTitle: '节目', wordCount: null, updatedAt: null, isLocked: false, attributes: [] }); }
function sourceId(value) { const id = text(value); return /^\d+$/u.test(id) ? id : null; }
function numericId(value) { const result = Number(value); return Number.isSafeInteger(result) ? result : value; }
function contentId(id) { const value = /^album:(\d+)$/u.exec(id)?.[1]; if (value === undefined)
    throw new Error('Content ID is invalid.'); return value; }
function chapterNative(id, albumId) { const value = new RegExp(`^album:${albumId}:(\\d+)$`, 'u').exec(id)?.[1]; if (value === undefined)
    throw new Error('Chapter ID is invalid.'); return value; }
function proxyImage(value) { if (!safeUrl(value))
    return null; return requireContext().resource.proxy({ kind: 'image', url: value, headers: { Referer: 'https://tingyou.fm/' } }); }
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
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function nonNegative(value) { const result = Number(value); return Number.isSafeInteger(result) && result >= 0 ? result : null; }
function stringList(value) { if (Array.isArray(value))
    return value.map(text).filter(Boolean).slice(0, 32); const raw = text(value); return raw === '' ? [] : raw.split(/[,，/]/u).map(part => part.trim()).filter(Boolean).slice(0, 32); }
function parseJson(raw) { try {
    return JSON.parse(raw);
}
catch {
    throw new Error('Source response is invalid.');
} }
function first(...values) { return values.find(value => value !== null && value !== undefined && value !== '') ?? ''; }
function records(value) { return Array.isArray(value) ? value.filter(isObject) : []; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' || typeof value === 'bigint' ? String(value) : ''; }
function nullable(value) { const result = text(value); return result === '' ? null : result; }
function notNull(value) { return value !== null; }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
