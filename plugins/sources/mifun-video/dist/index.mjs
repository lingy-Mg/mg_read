const initial = 'https://getcf.mymifun.com', hostList = 'https://miget-1313189639.cos.ap-guangzhou.myqcloud.com/mifun.txt', agent = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126.0 Mobile Safari/537.36', channels = [{ id: '0', title: '全部' }, { id: '1', title: '番剧' }, { id: '2', title: '国创' }, { id: '3', title: '剧场' }, { id: '4', title: '美漫' }, { id: '5', title: '特摄' }];
let context, base = initial, basePromise;
const pageCache = new Map();
export async function activate(next) { context = next; base = initial; basePromise = undefined; pageCache.clear(); next.log.info('source_activated'); }
export async function search(request) { const query = request.query.trim(); if (query === '')
    return frozen({ items: [], nextCursor: null, totalCount: 0 }); const page = cursorPage(request.cursor, 'search'), path = page === 1 ? `/vodsearch/?wd=${encodeURIComponent(query)}` : `/vodsearch${encodeURIComponent(query)}/page/${page}/`, values = parseItems(await html(path)), items = values.map(summary).slice(0, clamp(request.pageSize)); return frozen({ items, nextCursor: values.length >= clamp(request.pageSize) ? `search:${page + 1}` : null, totalCount: null }); }
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function discover(request) { if (request.target === null)
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: 'mifun-channels', title: 'MiFun', subtitle: '动漫分类', icon: 'video', children: [{ type: 'categoryCollection', id: 'mifun-channel-list', layout: 'chips', categories: channels.map(channel => ({ id: channel.id, title: channel.title, target: `channel:${channel.id}`, count: null, url: null, icon: 'video' })) }] }] } }); const channel = channels.find(value => request.target === `channel:${value.id}`); if (!channel)
    throw new Error('Discovery target is invalid.'); const page = cursorPage(request.cursor, request.target), size = clamp(request.pageSize), path = channel.id === '0' ? (page === 1 ? '/' : `/index-${page}.html`) : (page === 1 ? `/vodtype/${channel.id}/` : `/vodtype/${channel.id}-${page}/`), values = parseItems(await html(path)), contents = values.map(summary).slice(0, size), collectionId = `mifun:${channel.id}`, items = contents.map(content => frozen({ content, rank: null, metric: null, recommendation: null })), continuation = values.length >= size ? frozen({ target: request.target, cursor: `channel:${channel.id}:${page + 1}` }) : null; if (request.collectionId !== null) {
    if (request.collectionId !== collectionId)
        throw new Error('Discovery collection is invalid.');
    return frozen({ kind: 'append', collectionId, items, continuation });
} return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: channel.title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } }); }
export async function getDetail(request) { const id = contentId(request.id), source = await html(`/voddetail/${id}/`), parsed = detail(source, id), episodes = parseEpisodes(source); return frozen({ ...summary(parsed), description: parsed.remark, chapterCount: episodes.length, aliases: [], catalogUrl: `${await currentBase()}/voddetail/${id}/` }); }
export async function getChapters(request) { const id = contentId(request.id), episodes = parseEpisodes(await html(`/voddetail/${id}/`)), items = episodes.map((episode, index) => frozen({ id: `video:${id}:${episode.line}:${episode.number}`, title: episode.title, order: index, url: null, volumeTitle: episode.group, wordCount: null, updatedAt: null, isLocked: false, attributes: [] })), groups = [...new Set(episodes.map(value => value.group))].map((title, index) => frozen({ id: `group:${id}:${index}`, title, order: index, episodes: items.filter(item => item.volumeTitle === title) })); return frozen({ items, groups }); }
export async function getContent(request) { const id = contentId(request.id), episode = chapterKey(request.chapterId, id), pageUrl = `${await currentBase()}/vodplay/${id}-${episode.line}-${episode.number}/`, source = await html(pageUrl), raw = source.match(/player_aaaa\s*=\s*(\{[\s\S]*?\})\s*(?:<\/script>|;)/u)?.[1]; if (!raw)
    throw new Error('Player data is unavailable.'); let data; try {
    data = JSON.parse(raw);
}
catch {
    throw new Error('Player data is invalid.');
} const input = isRecord(data) ? text(data.url) : '', upstream = safeUrl(input) ? input : await resolvePlayer(input, pageUrl); if (!safeUrl(upstream))
    throw new Error('Video address is unavailable.'); const mediaHeaders = { 'User-Agent': agent, Referer: pageUrl }; return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'video', url: upstream, headers: mediaHeaders }), resourceType: 'video', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: /\.m3u8(?:$|[?#])/iu.test(upstream) ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers: mediaHeaders } }); }
async function resolvePlayer(input, chapterUrl) { if (!input)
    throw new Error('Player token is unavailable.'); const page = `https://data.m3u8.in/player/?url=${encodeURIComponent(input)}`, source = await requestText(page, { ...headers(chapterUrl), Accept: 'text/html,*/*;q=0.8' }), sign = source.match(/(?:const|var)\s+Sign\s*=\s*["']([^"']+)/u)?.[1] ?? source.match(/["']sign["']\s*:\s*["']([a-fA-F0-9]{32})/u)?.[1]; if (!sign)
    throw new Error('Player signature is unavailable.'); const raw = await requestText(`https://data.m3u8.in/player/api.php?url=${encodeURIComponent(input)}&sign=${encodeURIComponent(sign)}`, { 'User-Agent': agent, Accept: 'application/json,text/plain,*/*', Referer: page }); let value; try {
    value = JSON.parse(raw);
}
catch {
    throw new Error('Player response is invalid.');
} return isRecord(value) ? text(value.url).replaceAll('\\/', '/') : ''; }
async function html(input) { const root = await currentBase(), url = safeUrl(input) ? input : new URL(input, `${root}/`).toString(), cached = pageCache.get(url); if (cached)
    return cached; const value = decode(await requestText(url, headers(`${root}/`))); pageCache.set(url, value); return value; }
async function requestText(url, requestHeaders) { const response = await requireContext().http.fetch(url, { headers: requestHeaders }); if (!response.ok)
    throw new Error('Source request failed.'); return await response.text(); }
function headers(referer) { return { 'User-Agent': agent, Accept: 'application/json,text/plain,*/*;q=0.9,text/html;q=0.8', Referer: referer }; }
async function currentBase() { if (!basePromise)
    basePromise = (async () => { for (const candidate of [base, ...(await candidates())]) {
        try {
            const response = await requireContext().http.fetch(`${candidate.replace(/\/+$/u, '')}/`, { headers: headers(`${candidate}/`) }), source = await response.text();
            if (response.ok && (source.includes('MiFun') || source.includes('voddetail'))) {
                base = candidate.replace(/\/+$/u, '');
                return base;
            }
        }
        catch {
            continue;
        }
    } return base; })(); return basePromise; }
async function candidates() { try {
    const response = await requireContext().http.fetch(hostList, { headers: headers('') });
    if (!response.ok)
        return [];
    return (await response.text()).split(/\r?\n/u).map(value => value.trim().replace(/\/+$/u, '')).filter(safeUrl);
}
catch {
    return [];
} }
function parseItems(source) { const result = new Map(); for (const match of source.matchAll(/<li\b[^>]*class="[^"]*hl-list-item[^"]*"[^>]*>([\s\S]*?)<\/li>/gu)) {
    const block = match[1] ?? '', link = block.match(/<a\b[^>]*href="([^"]*\/voddetail\/(\d+)\/[^"]*)"/u), id = link?.[2];
    if (!id)
        continue;
    const title = clean(pick(block, /<a\b[^>]*title="([^"]+)"/u) || pick(block, /<div\b[^>]*hl-item-title[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/u));
    if (!title)
        continue;
    result.set(id, { id, title, cover: absolute(pick(block, /data-original="([^"]+)"/u) || pick(block, /src="([^"]+)"/u)), author: clean(pick(block, /class="[^"]*hl-item-sub[^"]*"[^>]*>([\s\S]*?)<\/div>/u)), remark: clean(pick(block, /class="[^"]*remarks[^"]*"[^>]*>([\s\S]*?)<\/span>/u)), category: clean(pick(block, /class="[^"]*state[^"]*"[^>]*>([\s\S]*?)<\/span>/u)) });
} return [...result.values()]; }
function detail(source, id) { return { id, title: clean(pick(source, /<h1[^>]*>([\s\S]*?)<\/h1>/u)) || id, cover: absolute(pick(source, /<div\b[^>]*class="[^"]*hl-dc-pic[^"]*"[\s\S]*?data-original="([^"]+)"/u) || pick(source, /property="og:image" content="([^"]+)"/u)), author: clean(pick(source, /导演：<\/em>([\s\S]*?)<\/li>/u) || pick(source, /主演：<\/em>([\s\S]*?)<\/li>/u)), remark: clean(pick(source, /class="[^"]*hl-content-text[^"]*"[^>]*>([\s\S]*?)<\/span>/u) || pick(source, /<meta name="description" content="([^"]*)"/u)), category: clean(pick(source, /类型：<\/em>([\s\S]*?)<\/li>/u)) }; }
function parseEpisodes(source) { const result = new Map(), names = new Map(); for (const match of source.matchAll(/<li\b[^>]*data-href="[^"]*\/vodplay\/\d+-(\d+)-\d+\/[^"]*"[^>]*>[\s\S]*?<span\b[^>]*>([\s\S]*?)<\/span>/gu))
    names.set(match[1] ?? '', clean(match[2] ?? '')); for (const match of source.matchAll(/<a\b[^>]*href="[^"]*\/vodplay\/(\d+)-(\d+)-(\d+)\/[^"]*"[^>]*>([\s\S]*?)<\/a>/gu)) {
    const line = match[2] ?? '', number = match[3] ?? '', title = clean(match[4] ?? '');
    if (title === '立即播放' || title === '播放')
        continue;
    result.set(`${line}:${number}`, { line, number, title: title || `第${number}集`, group: names.get(line) || `线路${line}` });
} return [...result.values()].sort((a, b) => Number(a.line) - Number(b.line) || Number(a.number) - Number(b.number)); }
function summary(value) { return frozen({ id: `video:${value.id}`, title: value.title, contentKind: 'video', coverOrientation: 'portrait', author: value.author || null, url: `${base}/voddetail/${value.id}/`, coverUrl: proxyImage(value.cover), description: value.remark || null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: value.remark ? { id: `video:${value.id}:latest`, title: value.remark, url: null, updatedAt: null } : null, categories: value.category ? [value.category] : [], tags: [], attributes: [] }); }
function contentId(id) { const value = /^video:(\d+)$/u.exec(id)?.[1]; if (!value)
    throw new Error('Content ID is invalid.'); return value; }
function chapterKey(id, content) { const match = new RegExp(`^video:${content}:(\\d+):(\\d+)$`, 'u').exec(id); if (!match)
    throw new Error('Chapter ID is invalid.'); return { line: match[1] ?? '', number: match[2] ?? '' }; }
function proxyImage(url) { return safeUrl(url) ? requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }) : null; }
function absolute(value) { if (value.startsWith('//'))
    return `https:${value}`; if (value.startsWith('/'))
    return `${base}${value}`; return value; }
function safeUrl(value) { try {
    return ['http:', 'https:'].includes(new URL(value).protocol);
}
catch {
    return false;
} }
function pick(value, pattern) { return pattern.exec(value)?.[1] ?? ''; }
function clean(value) { return decode(value.replaceAll(/<[^>]+>/gu, ' ').replaceAll('&nbsp;', ' ').replaceAll(/\s+/gu, ' ').trim()); }
function decode(value) { return value.replaceAll(/\\u([0-9a-fA-F]{4})/gu, (_all, hex) => String.fromCharCode(Number.parseInt(hex, 16))).replaceAll('\\/', '/').replaceAll('\\"', '"').replaceAll('&amp;', '&'); }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value) { return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : ''; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2)
    throw new Error('Cursor is invalid.'); return page; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (!context)
    throw new Error('Source is not activated.'); return context; }
