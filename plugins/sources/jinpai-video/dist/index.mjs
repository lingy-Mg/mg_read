const base = 'https://www.vv3nwjk.com';
const categories = Object.freeze([
    ['movie', '电影', '1'], ['series', '连续剧', '2'], ['variety', '综艺', '3'], ['anime', '动漫', '4'],
]);
let context;
let pageQueue = Promise.resolve();
let sessionBootstrap;
let sessionUserAgent = '';
export async function activate(next) {
    context = next;
    pageQueue = Promise.resolve();
    sessionBootstrap = undefined;
    sessionUserAgent = '';
    next.log.info('source_activated');
}
export async function search(request) {
    const query = clean(request.query);
    if (query === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const pageNumber = cursorPage(request.cursor, 'search');
    const listings = readListingsHtml(await fetchSessionHtml(searchUrl(query, pageNumber)));
    const items = listings.slice(0, clamp(request.pageSize)).map(summary);
    return frozen({ items, nextCursor: listings.length >= items.length && pageNumber < 50 ? `search:${pageNumber + 1}` : null, totalCount: null });
}
export async function searchSuggestions(_request) {
    return frozen({ items: [], nextCursor: null });
}
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        return frozen({ kind: 'document', document: { components: [{
                        type: 'section', id: 'jinpai-categories', title: '影视分类', subtitle: '金牌影院', icon: 'video',
                        children: [{ type: 'categoryCollection', id: 'jinpai-category-list', layout: 'chips', categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })) }],
                    }] } });
    }
    const category = categories.find(([id]) => request.target === `category:${id}`);
    if (category === undefined)
        throw new Error('Discovery target is invalid.');
    const pageNumber = cursorPage(request.cursor, request.target);
    const path = `${base}/vod/show/id/${category[2]}${pageNumber === 1 ? '' : `/page/${pageNumber}`}`;
    const listings = readListingsHtml(await fetchSessionHtml(path));
    const contents = listings.slice(0, clamp(request.pageSize)).map(summary);
    const collectionId = `jinpai:${category[0]}`;
    const items = contents.map((content) => frozen({ content, rank: null, metric: null, recommendation: null }));
    const continuation = listings.length >= contents.length && pageNumber < 50 ? frozen({ target: request.target, cursor: `${request.target}:${pageNumber + 1}` }) : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== collectionId)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId, items, continuation });
    }
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${collectionId}:section`, title: category[1], subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation }] }] } });
}
export async function getDetail(request) {
    const id = contentId(request.id);
    const detail = readDetailHtml(await fetchSessionHtml(detailUrl(id)), id);
    const item = summary(detail);
    return frozen({ ...item, author: detail.author || null, description: detail.description || null, updatedAt: detail.updatedAt || null, aliases: [], catalogUrl: detailUrl(id) });
}
export async function getChapters(request) {
    const id = contentId(request.id);
    const episodes = readEpisodesHtml(await fetchSessionHtml(detailUrl(id)), id);
    if (episodes.length === 0)
        throw new Error('No playable episodes found.');
    const rows = episodes.map((episode, order) => frozen({ id: `jinpai:${id}:${episode.line}:${episode.episode}`, title: episode.title, order, url: playUrl(id, episode.line, episode.episode), volumeTitle: episode.group || null, wordCount: null, updatedAt: null, isLocked: null, attributes: [] }));
    const byLine = new Map();
    for (const row of rows)
        byLine.set(row.id.split(':')[2] ?? '', [...(byLine.get(row.id.split(':')[2] ?? '') ?? []), row]);
    const groups = [...byLine.values()].map((group, order) => frozen({ id: `group:${id}:${order}`, title: group[0]?.volumeTitle ?? `线路 ${order + 1}`, order, episodes: group }));
    return frozen({ items: rows, groups });
}
export async function getContent(request) {
    const id = contentId(request.id);
    const chapter = parseChapterId(request.chapterId, id);
    const url = playUrl(id, chapter.line, chapter.episode);
    const pageHtml = await fetchSessionHtml(url);
    const upstream = readM3u8Html(pageHtml);
    if (upstream === '')
        throw new Error('播放页未返回可直接读取的 HLS 地址；请稍后重试。');
    const headers = { Referer: url, 'User-Agent': sessionUserAgent };
    return frozen({ chapterId: request.chapterId, contentKind: 'video', title: null, updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: 'hls', url: upstream, headers }), resourceType: 'hls', resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: 'application/vnd.apple.mpegurl', headers } });
}
async function fetchSessionHtml(url) {
    await ensureBrowserSession();
    const raw = await requireContext().browser.sessionV1.request({ version: 1, sessionKey: 'jinpai-webview', url, method: 'GET', headers: { Accept: 'text/html,application/xhtml+xml' }, body: null, interaction: 'silent', presentation: 'hidden', transport: 'http', timeoutMs: 30_000, maxResponseBytes: 2 * 1024 * 1024 });
    if (!isRecord(raw))
        throw new Error('金牌影院会话 HTTP 返回格式无效。');
    const status = raw.status;
    const body = text(raw.body);
    const userAgent = text(raw.sessionUserAgent);
    if (typeof status !== 'number' || !Number.isInteger(status) || status < 200 || status >= 400 || body === '') {
        throw new Error(`金牌影院会话 HTTP 请求失败（${typeof status === 'number' ? status : '未知状态'}，${new URL(url).pathname}）。`);
    }
    if (userAgent === '')
        throw new Error('金牌影院会话未返回 WebView User-Agent。');
    sessionUserAgent = userAgent;
    if (isVerificationText(body)) {
        sessionBootstrap = undefined;
        requireContext().errors.raise({ code: 'source_access_blocked', message: '金牌影院正在刷新无感安全验证，请稍后重试。' });
    }
    return body;
}
function ensureBrowserSession() {
    if (sessionBootstrap !== undefined)
        return sessionBootstrap;
    const candidate = withPage(async (page) => requireAccessible(page, `${base}/`));
    sessionBootstrap = candidate.catch((error) => { sessionBootstrap = undefined; throw error; });
    return sessionBootstrap;
}
async function requireAccessible(page, url) {
    await page.navigate(url, { timeoutMs: 35_000 });
    const state = await page.executeJavaScript(`return (async()=>{
    let state={title:'',text:'',captcha:false};
    for(let attempt=0;attempt<24;attempt+=1){
      state={title:document.title||'',text:(document.body?.innerText||'').slice(0,4000),captcha:!!document.querySelector('#grecaptcha,[name="g-recaptcha-response"],iframe[src*="recaptcha"]')};
      if(location.protocol.startsWith('http')&&!state.captcha&&!/安全验证|浏览器安全检查|recaptcha/iu.test(state.title+' '+state.text)&&(state.text!==''||state.title!==''))return state;
      await new Promise(resolve=>setTimeout(resolve,250));
    }
    return state;
  })()`, { timeoutMs: 15_000 });
    if (isRecord(state) && (state.captcha === true || isVerificationText(`${text(state.title)} ${text(state.text)}`))) {
        await page.show({ timeoutMs: 10_000 });
        requireContext().errors.raise({ code: 'source_access_blocked', message: '金牌影院正在进行无感安全验证；验证会话会保留，请稍后重试。' });
    }
}
function readListingsHtml(html) {
    const results = [];
    const seen = new Set();
    for (const match of html.matchAll(/<a\b([^>]*?)href\s*=\s*(["'])([^"']*\/detail\/([^\/?#"']+)[^"']*)\2([^>]*)>([\s\S]*?)<\/a>/giu)) {
        const id = clean(match[4] ?? '');
        const attributes = `${match[1] ?? ''} ${match[5] ?? ''}`;
        const inner = match[6] ?? '';
        const title = listingTitle(attributes, inner);
        if (id === '' || title === '' || seen.has(id))
            continue;
        seen.add(id);
        const image = /<img\b([^>]*)>/iu.exec(inner)?.[1] ?? '';
        results.push({ id, title, cover: safeUrl(htmlAttribute(image, 'data-original') || htmlAttribute(image, 'data-src') || htmlAttribute(image, 'data-lazy-src') || htmlAttribute(image, 'src')), latest: '' });
    }
    if (results.length === 0)
        throw new Error('金牌影院会话 HTTP 未解析到影视条目。');
    return results;
}
function readDetailHtml(html, id) {
    const title = clean(htmlText(/<h1\b[^>]*>([\s\S]*?)<\/h1>/iu.exec(html)?.[1] ?? '') || htmlAttribute(/<meta\b[^>]*property\s*=\s*["']og:title["'][^>]*>/iu.exec(html)?.[0] ?? '', 'content'));
    if (title === '')
        throw new Error('金牌影院会话 HTTP 未解析到影视详情。');
    const image = /<img\b([^>]*)>/iu.exec(html)?.[1] ?? '';
    const description = clean(htmlText(/<(?:div|p)\b[^>]*class\s*=\s*["'][^"']*(?:intro|description|vod_content|detail-content)[^"']*["'][^>]*>([\s\S]*?)<\/(?:div|p)>/iu.exec(html)?.[1] ?? ''));
    return { id, title, cover: safeUrl(htmlAttribute(image, 'data-original') || htmlAttribute(image, 'data-src') || htmlAttribute(image, 'src')), latest: '', author: '', updatedAt: '', description };
}
function readEpisodesHtml(html, id) {
    const results = [];
    const seen = new Set();
    for (const match of html.matchAll(/<a\b([^>]*?)href\s*=\s*(["'])([^"']*\/vod\/play\/([^\/?#"']+)\/sid\/([^\/?#"']+)[^"']*)\2[^>]*>([\s\S]*?)<\/a>/giu)) {
        if (match[4] !== id)
            continue;
        const episode = clean(match[5] ?? '');
        const title = clean(htmlText(match[6] ?? '') || htmlAttribute(match[1] ?? '', 'title'));
        if (!/^\d+$/u.test(episode) || title === '' || seen.has(episode))
            continue;
        seen.add(episode);
        results.push({ line: '1', episode, title, group: '默认线路' });
    }
    return results;
}
function readM3u8Html(html) {
    const normalized = html
        .replaceAll('\\/', '/')
        .replaceAll('\\u002F', '/')
        .replaceAll('&amp;', '&');
    for (const match of normalized.matchAll(/(?:https?:\/\/|\/)[^"'\\\s<>]*?\.m3u8(?:\?[^"'\\\s<>]*)?/giu)) {
        const candidate = safeUrl(match[0]);
        if (/\.m3u8(?:$|\?)/iu.test(candidate))
            return candidate;
    }
    return '';
}
function listingTitle(attributes, inner) {
    const explicit = clean(htmlAttribute(attributes, 'title'));
    if (explicit !== '')
        return explicit;
    const classTitle = /<(?:a|span|h[1-6])\b[^>]*class\s*=\s*["'][^"']*(?:title|name)[^"']*["'][^>]*>([\s\S]*?)<\/(?:a|span|h[1-6])>/iu.exec(inner)?.[1] ?? '';
    const textValue = clean(htmlText(classTitle || inner) || htmlAttribute(inner, 'alt'));
    const addedTitle = clean(textValue.split('添加影片').at(-1) ?? '');
    return clean((addedTitle === '' ? textValue : addedTitle).replace(/\s+\d+(?:\.\d+)?$/u, ''));
}
function searchUrl(query, pageNumber) {
    const url = new URL(`/vod/search/${encodeURIComponent(query)}`, base);
    if (pageNumber > 1)
        url.searchParams.set('page', String(pageNumber));
    return url.toString();
}
function withPage(action) {
    const run = pageQueue.then(async () => action(await requireContext().webview.open({ visible: true, timeoutMs: 30_000 })));
    pageQueue = run.then(() => undefined, () => undefined);
    return run;
}
function summary(value) { return frozen({ id: `video:${encode(value.id)}`, title: value.title, contentKind: 'video', coverOrientation: 'portrait', author: null, url: detailUrl(value.id), coverUrl: proxyImage(value.cover), description: null, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: value.latest === '' ? null : { id: null, title: value.latest, url: null, updatedAt: null }, categories: [], tags: [], attributes: [] }); }
function proxyImage(value) { const url = safeUrl(value); return url === '' ? null : requireContext().resource.proxy({ kind: 'image', url, headers: { Referer: `${base}/` } }); }
function detailUrl(id) { return `${base}/detail/${encodeURIComponent(id)}`; }
function playUrl(id, _line, episode) { return `${base}/vod/play/${encodeURIComponent(id)}/sid/${encodeURIComponent(episode)}`; }
function contentId(value) { const encoded = /^video:([A-Za-z0-9_-]+)$/u.exec(value)?.[1]; const id = encoded === undefined ? '' : decode(encoded); if (!/^[^/?#]+$/u.test(id))
    throw new Error('Content ID is invalid.'); return id; }
function parseChapterId(value, id) { const match = new RegExp(`^jinpai:${escapeRegex(id)}:(\\d+):(\\d+)$`, 'u').exec(value); if (match?.[1] === undefined || match[2] === undefined)
    throw new Error('Chapter ID is invalid.'); return { line: match[1], episode: match[2] }; }
function cursorPage(cursor, scope) { if (cursor === null)
    return 1; const page = Number(cursor.startsWith(`${scope}:`) ? cursor.slice(scope.length + 1) : ''); if (!Number.isSafeInteger(page) || page < 2 || page > 50)
    throw new Error('Cursor is invalid.'); return page; }
function encode(value) { return Buffer.from(value).toString('base64url'); }
function decode(value) { return Buffer.from(value, 'base64url').toString('utf8'); }
function escapeRegex(value) { return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'); }
function safeUrl(value) { try {
    const url = new URL(value, base);
    return /^https?:$/u.test(url.protocol) ? url.toString() : '';
}
catch {
    return '';
} }
function clean(value) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function htmlText(value) { return clean(value.replace(/<script\b[\s\S]*?<\/script>|<style\b[\s\S]*?<\/style>|<[^>]+>/giu, ' ').replace(/&(nbsp|amp|quot|#39);/giu, (_all, entity) => ({ nbsp: ' ', amp: '&', quot: '"', '#39': "'" })[entity.toLowerCase()] ?? ' ')); }
function htmlAttribute(value, name) { return clean(new RegExp(`\\b${escapeRegex(name)}\\s*=\\s*(["'])(.*?)\\1`, 'isu').exec(value)?.[2] ?? ''); }
function text(value) { return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function isVerificationText(value) { return /安全验证|浏览器安全检查|recaptcha/iu.test(value); }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function frozen(value) { return Object.freeze(value); }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
