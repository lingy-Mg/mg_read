/**
 * 黄豆短剧视频数据源。
 *
 * 生命周期与 IO：activate 只保存公开 MgRead 上下文并重置内存游客会话；每次内容调用通过
 * Runtime HTTP 发送 gzip + AES-256-CBC 二进制 API 请求。多线路、token 和设备会话只在
 * 插件内存中持有，不写缓存、不进日志。封面和 HLS/视频只登记 Runtime resource proxy。
 *
 * 稳定身份：drama/episode/target/cursor 都由来源 ID 编码，标题、URL、数组位置和页码不作主键。
 * 注意：旧宿主为规避二进制损坏使用 WebView；MgRead Node 24 可原生收发字节，因此无需页面或人工交互。
 */
import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes } from 'node:crypto';
import { gunzipSync, gzipSync } from 'node:zlib';
const apiHosts = Object.freeze([
    'https://xqjzvcvt.top',
    'https://psfxhhox.top',
    'https://sxqirtho.top',
    'https://qicuknlj.top',
    'https://hvthtcpa.top',
]);
const apiKey = '7961beb44246e3012ce228d6b5ced05a';
const apiVersion = '2.0.0';
const apiUserAgent = 'Dart/3.5 (dart:io)';
const playerUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const maximumPage = 200;
let context;
let activeHost;
let authToken;
let authPromise;
let deviceId = '';
let sessionId = '';
export async function activate(next) {
    context = next;
    activeHost = undefined;
    authToken = undefined;
    authPromise = undefined;
    deviceId = randomBytes(16).toString('hex');
    sessionId = randomBytes(16).toString('hex');
    next.log.info('source_activated');
}
export async function search(request) {
    const query = request.query.trim();
    if (query === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const limit = clampPageSize(request.pageSize);
    const scope = `search:${digest(query)}`;
    const page = cursorPage(request.cursor, scope);
    const items = (await fetchDramaList(page, { keywords: query, order: 'hot', pageSize: limit })).slice(0, limit);
    return frozen({ items, nextCursor: continuationCursor(items.length, limit, page, scope), totalCount: null });
}
export async function searchSuggestions(request) {
    if (request.cursor !== null)
        throw new Error('Search suggestion cursor is unsupported.');
    clampPageSize(request.pageSize);
    return frozen({ items: [], nextCursor: null });
}
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        return rootDiscovery(request.pageSize);
    }
    const target = decodeTarget(request.target);
    const limit = clampPageSize(request.pageSize);
    const page = cursorPage(request.cursor, `discover:${request.target}`);
    const items = (await discoverItems(target, page, limit)).map(discoveryItem);
    const collectionId = collectionFor(request.target);
    const continuation = items.length >= limit && page < maximumPage
        ? frozen({ target: request.target, cursor: encodeCursor(`discover:${request.target}`, page + 1) })
        : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId, items, continuation });
    }
    return frozen({
        kind: 'document',
        document: {
            components: [{
                    type: 'section', id: `${collectionId}:section`, title: targetTitle(target), subtitle: null, icon: target.kind === 'rank' ? 'ranking' : 'video',
                    children: [{ type: 'contentCollection', id: collectionId, layout: target.kind === 'rank' ? 'ranking' : 'coverGrid', items, continuation }],
                }],
        },
    });
}
export async function getDetail(request) {
    const id = decodeDramaId(request.id);
    const detail = await fetchDramaDetail(id);
    const summary = dramaSummary(detail);
    if (summary === null || decodeDramaId(summary.id) !== id)
        throw new Error('Drama detail is invalid.');
    return frozen({ ...summary, aliases: [], catalogUrl: null });
}
export async function getChapters(request) {
    const id = decodeDramaId(request.id);
    const detail = await fetchDramaDetail(id);
    const episodes = records(detail.episodes);
    const items = episodes.map((episode, index) => episodeSummary(id, episode, index));
    if (items.length === 0)
        throw new Error('Drama catalog is empty.');
    return frozen({ items });
}
export async function getContent(request) {
    const id = decodeDramaId(request.id);
    const chapter = decodeEpisodeId(request.chapterId);
    if (chapter.dramaId !== id)
        throw new Error('Episode ID does not belong to the drama.');
    const detail = await fetchDramaDetail(id);
    const episode = records(detail.episodes).find((item, index) => episodeSequence(item, index) === chapter.sequence);
    if (episode === undefined)
        throw new Error('Episode ID is invalid.');
    let play = null;
    try {
        play = await fetchDramaPlay(id, chapter.sequence);
    }
    catch (error) {
        if (!(error instanceof ApiFailure))
            throw error;
    }
    const selected = playableFrom(play, detail, episode);
    if (selected === null)
        throw new Error('Playback address is unavailable.');
    const headers = frozen({ Accept: '*/*', Referer: `${activeHost ?? apiHosts[0]}/`, 'User-Agent': playerUserAgent });
    const resourceType = selected.kind;
    const proxyUrl = requireContext().resource.proxy({ kind: resourceType, url: selected.url, headers });
    return frozen({
        chapterId: request.chapterId,
        contentKind: 'video',
        title: nullableText(episode.name) ?? `第${chapter.sequence}集`,
        updatedAt: null,
        text: null,
        pages: [],
        media: {
            url: proxyUrl,
            resourceType,
            resourcePolicy: 'sessionOnly',
            expiresAt: null,
            mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4',
            headers,
        },
    });
}
async function rootDiscovery(pageSize) {
    const limit = Math.min(clampPageSize(pageSize), 10);
    await ensureAuth();
    const [hot, navs, configuration] = await Promise.all([
        fetchDramaList(1, { order: 'hot', pageSize: limit }),
        fetchNavList(),
        fetchSearchConfiguration(),
    ]);
    const components = [];
    const hotTarget = encodeTarget({ kind: 'hot' });
    const hotItems = hot.map(discoveryItem);
    if (hotItems.length > 0) {
        components.push({
            type: 'section', id: 'huangdou-hot-section', title: '热门短剧', subtitle: null, icon: 'hot',
            children: [{
                    type: 'contentCollection', id: collectionFor(hotTarget), layout: 'coverGrid', items: hotItems,
                    continuation: hotItems.length >= limit ? { target: hotTarget, cursor: encodeCursor(`discover:${hotTarget}`, 2) } : null,
                }],
        });
    }
    const categories = discoveryCategories(navs, records(configuration.categories));
    if (categories.length > 0) {
        components.push({
            type: 'section', id: 'huangdou-categories-section', title: '短剧频道', subtitle: null, icon: 'video',
            children: [{ type: 'categoryCollection', id: 'huangdou-categories', layout: 'chips', categories }],
        });
    }
    if (components.length === 0)
        throw new Error('Discovery data is empty.');
    return frozen({ kind: 'document', document: { components } });
}
function discoveryCategories(navs, configured) {
    const result = [];
    const seen = new Set();
    const add = (title, target, icon) => {
        const key = title.trim();
        if (key === '' || seen.has(key) || result.length >= 32)
            return;
        seen.add(key);
        result.push({ id: `category:${digest(target).slice(0, 20)}`, title: key, target, count: null, url: null, icon });
    };
    add('热门', encodeTarget({ kind: 'hot' }), 'hot');
    add('排行榜', encodeTarget({ kind: 'rank' }), 'ranking');
    for (const nav of navs) {
        const title = text(nav.name);
        const code = text(nav.code ?? nav.id);
        if (title === '' || code === '')
            continue;
        const matching = configured.find((item) => text(item.name) === title && !emptyCategory(item));
        add(title, encodeTarget({ kind: 'nav', code, fallbackCategoryId: matching === undefined ? null : text(matching.id ?? matching.cat_id) || null }), 'video');
    }
    for (const category of configured) {
        if (emptyCategory(category))
            continue;
        const title = text(category.name);
        const id = text(category.id ?? category.cat_id);
        if (title !== '' && id !== '')
            add(title, encodeTarget({ kind: 'category', id }), 'video');
    }
    return result;
}
async function discoverItems(target, page, pageSize) {
    if (target.kind === 'hot')
        return fetchDramaList(page, { order: 'hot', pageSize });
    if (target.kind === 'rank') {
        const data = await apiData('/drama/rank', { page: String(page), page_size: String(pageSize) });
        return records(data.list).map(dramaSummary).filter(notNull);
    }
    if (target.kind === 'category')
        return fetchDramaList(page, { categoryId: target.id, order: 'hot', pageSize });
    const filters = await fetchNavFilters(target.code);
    if (filters !== null) {
        return fetchDramaList(page, {
            canvas: text(filters.canvas),
            categoryId: text(filters.cat_id),
            order: text(filters.order) || 'hot',
            pageSize,
            source: text(filters.source),
            tagId: text(filters.tag_id),
            updateStatus: text(filters.update_status),
        });
    }
    if (target.fallbackCategoryId !== null)
        return fetchDramaList(page, { categoryId: target.fallbackCategoryId, order: 'hot', pageSize });
    return fetchDramaList(page, { order: 'hot', pageSize });
}
async function fetchNavList() {
    const data = await apiData('/drama/navList', {});
    return records(data.list);
}
async function fetchSearchConfiguration() {
    return apiData('/drama/searchConf', {});
}
async function fetchNavFilters(code) {
    try {
        const data = await apiData('/drama/navFilter', { code });
        const first = records(data.list)[0];
        if (first !== undefined && isObject(first.filter))
            return first.filter;
    }
    catch (error) {
        if (!(error instanceof ApiFailure))
            throw error;
    }
    try {
        const data = await apiData('/drama/navBlock', { code, tab: '', page: '1' });
        const first = records(data.list)[0];
        if (first !== undefined && isObject(first.filter))
            return first.filter;
    }
    catch (error) {
        if (!(error instanceof ApiFailure))
            throw error;
    }
    return null;
}
async function fetchDramaList(page, options) {
    const request = { page: String(page), page_size: String(options.pageSize ?? 8) };
    setText(request, 'cat_id', options.categoryId);
    setText(request, 'tag_id', options.tagId);
    setText(request, 'keywords', options.keywords);
    setText(request, 'order', options.order);
    setText(request, 'source', options.source);
    setText(request, 'canvas', options.canvas);
    setText(request, 'update_status', options.updateStatus);
    const data = await apiData('/drama/list', request);
    return records(data.list).map(dramaSummary).filter(notNull);
}
async function fetchDramaDetail(id) {
    return apiData('/drama/detail', { id });
}
async function fetchDramaPlay(id, sequence) {
    return apiData('/drama/play', { id, seq: sequence });
}
async function apiData(path, data) {
    const response = await postApi(path, data, true);
    return isObject(response.data) ? response.data : {};
}
async function postApi(path, data, authenticated) {
    const token = authenticated ? await ensureAuth() : '';
    try {
        return await postAcrossHosts(path, data, token);
    }
    catch (error) {
        if (!authenticated || !(error instanceof ApiFailure) || !error.authExpired)
            throw error;
        authToken = undefined;
        const nextToken = await ensureAuth();
        return postAcrossHosts(path, data, nextToken);
    }
}
async function ensureAuth() {
    if (authToken !== undefined)
        return authToken;
    if (authPromise !== undefined)
        return authPromise;
    const pending = (async () => {
        const response = await postAcrossHosts('/login/device', {
            line_code: 'china_1', channel_code: 'china_1', share_code: '', clipboard_text: '',
            device_info: { browserName: 'Chrome', language: 'zh-CN', userAgent: playerUserAgent, platform: 'Win32' },
        }, '');
        const data = isObject(response.data) ? response.data : {};
        const token = text(data.token);
        if (token === '')
            throw new Error('Source login did not return a token.');
        authToken = token;
        requireContext().log.info('source_guest_session_ready');
        return token;
    })();
    authPromise = pending;
    try {
        return await pending;
    }
    finally {
        if (authPromise === pending)
            authPromise = undefined;
    }
}
async function postAcrossHosts(path, data, token) {
    const hosts = activeHost === undefined ? apiHosts : [activeHost, ...apiHosts.filter((host) => host !== activeHost)];
    let lastError;
    for (const [index, host] of hosts.entries()) {
        try {
            const response = await postOnHost(host, path, data, token);
            activeHost = host;
            return response;
        }
        catch (error) {
            if (error instanceof ApiFailure)
                throw error;
            lastError = error;
            requireContext().log.warn(`source_host_failed_${index + 1}_${errorCode(error)}`);
        }
    }
    throw lastError instanceof Error ? lastError : new Error('All source hosts failed.');
}
async function postOnHost(host, path, data, token) {
    const requestId = randomBytes(16).toString('hex');
    const url = `${host}/api${path}`;
    const key = requestKey(requestId);
    const iv = randomBytes(16);
    const cipher = createCipheriv('aes-256-cbc', key, iv);
    const compressed = gzipSync(Buffer.from(JSON.stringify({ token, deviceId, data }), 'utf8'));
    const payload = Buffer.concat([iv, cipher.update(compressed), cipher.final()]);
    const timestamp = Math.floor(Date.now() / 1000);
    const signInput = `Dart|${sessionId}|${requestId}|${timestamp}|${url.replace(/^https?:\/\//u, '')}`;
    const sign = `${createHash('md5').update(signInput).digest('hex')}-${timestamp}`;
    const response = await requireContext().http.fetch(url, {
        method: 'POST',
        headers: {
            version: apiVersion, deviceType: 'web', time: String(timestamp), sign, requestId, sessionId,
            deviceBrand: '', deviceModel: '', systemName: '', systemVersion: '',
            'User-Agent': apiUserAgent, 'Content-Type': 'application/octet-stream', Accept: '*/*',
        },
        body: payload,
    });
    if (!response.ok)
        throw new Error(`Source HTTP status ${response.status}.`);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length === 0)
        throw new Error('Source response is empty.');
    if (looksLikeJson(bytes)) {
        const value = JSON.parse(bytes.toString('utf8'));
        if (!isObject(value))
            throw new Error('Source response is invalid.');
        throw apiFailure(value);
    }
    if (bytes.length <= 16)
        throw new Error('Source response is truncated.');
    const decipher = createDecipheriv('aes-256-cbc', key, bytes.subarray(0, 16));
    const decrypted = Buffer.concat([decipher.update(bytes.subarray(16)), decipher.final()]);
    const value = JSON.parse(gunzipSync(decrypted).toString('utf8'));
    if (!isObject(value))
        throw new Error('Source response is invalid.');
    if (text(value.status).toLowerCase() === 'n')
        throw apiFailure(value);
    return value;
}
class ApiFailure extends Error {
    authExpired;
    constructor(authExpired) {
        super('Source API rejected the request.');
        this.authExpired = authExpired;
        this.name = 'ApiFailure';
    }
}
function apiFailure(value) {
    const code = text(value.errorCode ?? value.error);
    return new ApiFailure(code === '2002');
}
function requestKey(requestId) {
    return createHmac('sha256', apiKey).update(Buffer.from(requestId, 'hex')).digest();
}
function dramaSummary(item) {
    const rawId = text(item.id ?? item.drama_id).replace(/^rp_/u, '');
    const title = text(item.name);
    if (rawId === '' || title === '')
        return null;
    const latest = nullableText(item.update_label);
    const category = nullableText(item.category ?? item.cat_name);
    const pay = payment(item);
    return frozen({
        id: encodeDramaId(rawId),
        title,
        contentKind: 'video',
        author: nullableText(item.publisher ?? item.source),
        url: null,
        coverUrl: proxyCover(item.img_y ?? item.img ?? item.img_x ?? item.cover),
        description: nullableText(item.description),
        language: 'zh-CN',
        status: contentStatus(item.update_status),
        access: pay.kind === 'free' ? 'free' : 'mixed',
        wordCount: null,
        chapterCount: positiveInteger(item.episode_count),
        publishedAt: null,
        updatedAt: nullableText(item.update_time ?? item.update_at),
        latestChapter: latest === null ? null : { id: null, title: latest, url: null, updatedAt: null },
        categories: category === null ? [] : [category],
        tags: [],
        attributes: pay.label === null ? [] : [{ key: 'access', label: '观看权限', value: pay.price === null ? pay.label : `${pay.label} ${pay.price}` }],
    });
}
function episodeSummary(dramaId, episode, index) {
    const sequence = episodeSequence(episode, index);
    const pay = payment(episode);
    return frozen({
        id: encodeEpisodeId(dramaId, sequence),
        title: nullableText(episode.name) ?? `第${sequence}集`,
        order: index,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: nullableText(episode.update_time ?? episode.updated_at),
        isLocked: episodeLocked(episode, pay.kind),
        attributes: pay.label === null ? [] : [{ key: 'access', label: '观看权限', value: pay.price === null ? pay.label : `${pay.label} ${pay.price}` }],
    });
}
function playableFrom(play, detail, episode) {
    const direct = play === null ? '' : text(play.m3u8);
    if (safeMediaUrl(direct))
        return { url: direct, kind: 'hls' };
    if (play !== null) {
        for (const line of records(play.lines)) {
            const url = text(line.url);
            if (safeMediaUrl(url))
                return { url, kind: mediaKind(url) };
        }
        const preview = text(play.preview_m3u8);
        if (safeMediaUrl(preview))
            return { url: preview, kind: 'hls' };
    }
    const preview = text(episode.preview_m3u8 ?? detail.preview_m3u8);
    return safeMediaUrl(preview) ? { url: preview, kind: mediaKind(preview) } : null;
}
function payment(item) {
    const type = text(item.pay_type ?? item.payType ?? item.type).toLowerCase();
    const amount = numericText(item.episode_price ?? item.points_price ?? item.money ?? item.price);
    if (type === 'vip' || truthy(item.vip) || truthy(item.is_vip))
        return { kind: 'vip', label: 'VIP', price: amount };
    if (type === 'coin' || type === 'money' || type === 'points' || (amount !== null && Number(amount) > 0)) {
        return { kind: 'coin', label: '金币', price: amount };
    }
    return { kind: 'free', label: null, price: null };
}
function episodeLocked(item, kind) {
    if (kind === 'free')
        return false;
    const bought = knownBoolean(item.is_buy ?? item.bought);
    return bought === null ? true : !bought;
}
function proxyCover(value) {
    const raw = text(value);
    if (!safeHttpUrl(raw))
        return null;
    return requireContext().resource.proxy({
        kind: 'image', url: raw,
        headers: { Accept: 'image/*', Referer: `${activeHost ?? apiHosts[0]}/`, 'User-Agent': playerUserAgent },
    });
}
function encodeDramaId(id) {
    return `drama:${Buffer.from(id, 'utf8').toString('base64url')}`;
}
function decodeDramaId(id) {
    const encoded = /^drama:([A-Za-z0-9_-]+)$/u.exec(id)?.[1];
    if (encoded === undefined)
        throw new Error('Drama ID is invalid.');
    const decoded = Buffer.from(encoded, 'base64url').toString('utf8');
    if (decoded === '' || decoded.length > 256 || /[\u0000-\u001f]/u.test(decoded))
        throw new Error('Drama ID is invalid.');
    return decoded;
}
function encodeEpisodeId(dramaId, sequence) {
    return `episode:${Buffer.from(JSON.stringify({ dramaId, sequence }), 'utf8').toString('base64url')}`;
}
function decodeEpisodeId(id) {
    const encoded = /^episode:([A-Za-z0-9_-]+)$/u.exec(id)?.[1];
    if (encoded === undefined)
        throw new Error('Episode ID is invalid.');
    try {
        const value = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
        if (!isObject(value) || text(value.dramaId) === '' || !/^\d+$/u.test(text(value.sequence)))
            throw new Error();
        return frozen({ dramaId: text(value.dramaId), sequence: text(value.sequence) });
    }
    catch {
        throw new Error('Episode ID is invalid.');
    }
}
function encodeTarget(target) {
    return `target:${Buffer.from(JSON.stringify(target), 'utf8').toString('base64url')}`;
}
function decodeTarget(value) {
    const encoded = /^target:([A-Za-z0-9_-]+)$/u.exec(value)?.[1];
    if (encoded === undefined)
        throw new Error('Discovery target is invalid.');
    try {
        const target = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
        if (!isObject(target))
            throw new Error();
        if (target.kind === 'hot' || target.kind === 'rank')
            return { kind: target.kind };
        if (target.kind === 'category' && text(target.id) !== '')
            return { kind: 'category', id: text(target.id) };
        if (target.kind === 'nav' && text(target.code) !== '' && (target.fallbackCategoryId === null || typeof target.fallbackCategoryId === 'string')) {
            return { kind: 'nav', code: text(target.code), fallbackCategoryId: nullableText(target.fallbackCategoryId) };
        }
    }
    catch { }
    throw new Error('Discovery target is invalid.');
}
function encodeCursor(scope, page) {
    return `page:${page}:${digest(scope).slice(0, 20)}`;
}
function cursorPage(cursor, scope) {
    if (cursor === null)
        return 1;
    const match = /^page:(\d+):([a-f0-9]{20})$/u.exec(cursor);
    const page = Number(match?.[1]);
    if (!Number.isSafeInteger(page) || page < 2 || page > maximumPage || match?.[2] !== digest(scope).slice(0, 20)) {
        throw new Error('Cursor is invalid.');
    }
    return page;
}
function continuationCursor(length, limit, page, scope) {
    return length >= limit && page < maximumPage ? encodeCursor(scope, page + 1) : null;
}
function collectionFor(target) {
    return `collection:${digest(target).slice(0, 20)}`;
}
function targetTitle(target) {
    if (target.kind === 'hot')
        return '热门短剧';
    if (target.kind === 'rank')
        return '短剧排行榜';
    return '频道短剧';
}
function discoveryItem(content) {
    return frozen({ content, rank: null, metric: null, recommendation: null });
}
function episodeSequence(episode, index) {
    const sequence = text(episode.seq);
    return /^\d+$/u.test(sequence) && Number(sequence) > 0 ? sequence : String(index + 1);
}
function contentStatus(value) {
    if (value === 1 || value === '1')
        return 'completed';
    if (value === 0 || value === '0')
        return 'ongoing';
    return 'unknown';
}
function emptyCategory(value) {
    return text(value.id ?? value.cat_id) === '900009' || text(value.name) === '国产传媒';
}
function looksLikeJson(bytes) {
    let index = 0;
    while (index < bytes.length && (bytes[index] === 9 || bytes[index] === 10 || bytes[index] === 13 || bytes[index] === 32))
        index += 1;
    return bytes[index] === 123 || bytes[index] === 91;
}
function safeMediaUrl(value) {
    return safeHttpUrl(value);
}
function safeHttpUrl(value) {
    try {
        const url = new URL(value);
        return (url.protocol === 'https:' || url.protocol === 'http:') && url.username === '' && url.password === '';
    }
    catch {
        return false;
    }
}
function mediaKind(value) {
    return /\.m3u8(?:$|[?#])/iu.test(value) ? 'hls' : 'video';
}
function positiveInteger(value) {
    const number = Number(value);
    return Number.isSafeInteger(number) && number >= 0 ? number : null;
}
function numericText(value) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? String(value).trim() : null;
}
function knownBoolean(value) {
    if (value === true || value === 1 || value === '1' || value === 'y' || value === 'Y')
        return true;
    if (value === false || value === 0 || value === '0' || value === 'n' || value === 'N')
        return false;
    return null;
}
function truthy(value) {
    return knownBoolean(value) === true;
}
function digest(value) {
    return createHash('sha256').update(value).digest('hex');
}
function setText(target, key, value) {
    if (value !== undefined && value !== '')
        target[key] = value;
}
function clampPageSize(value) {
    if (!Number.isFinite(value))
        throw new Error('Page size is invalid.');
    return Math.max(1, Math.min(50, Math.floor(value)));
}
function errorCode(error) {
    if (error instanceof SyntaxError)
        return 'invalid_json';
    if (error instanceof TypeError)
        return 'transport';
    if (error instanceof Error && /decrypt|bad decrypt|wrong final block/iu.test(error.message))
        return 'decrypt';
    return 'invalid_response';
}
function nullableText(value) {
    const result = text(value);
    return result === '' ? null : result;
}
function text(value) {
    return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : '';
}
function records(value) {
    return Array.isArray(value) ? value.filter(isObject) : [];
}
function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function notNull(value) {
    return value !== null;
}
function frozen(value) {
    return Object.freeze(value);
}
function requireContext() {
    if (context === undefined)
        throw new Error('Source is not activated.');
    return context;
}
