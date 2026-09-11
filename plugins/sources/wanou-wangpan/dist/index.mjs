const site = 'https://www.wogg.net';
const userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
const categories = Object.freeze([
    ['movie', '玩偶电影', '1'], ['series', '玩偶剧集', '2'], ['short', '短剧', '6'], ['anime', '动漫', '3'],
    ['variety', '综艺', '4'], ['documentary', '纪录片', '46'], ['music', '音乐', '5'],
]);
const videoExtensions = new Set(['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'ts']);
let context;
let pageQueue = Promise.resolve();
export async function activate(next) {
    context = next;
    pageQueue = Promise.resolve();
    next.log.info('source_activated');
}
export async function discover(request) {
    if (request.target === null) {
        if (request.cursor !== null || request.collectionId !== null)
            throw new Error('Initial discovery request is invalid.');
        return frozen({ kind: 'document', document: { components: [
                    { type: 'section', id: 'wanou-categories', title: '影视分类', subtitle: '玩偶站的网盘影视索引', icon: 'video', children: [{
                                type: 'categoryCollection', id: 'wanou-category-list', layout: 'chips',
                                categories: categories.map(([id, title]) => ({ id, title, target: `category:${id}`, count: null, url: null, icon: 'video' })),
                            }] },
                    { type: 'section', id: 'wanou-login', title: '网盘登录', subtitle: '首次播放前请在此打开并完成对应网盘的官方登录', icon: 'account', children: [{
                                type: 'categoryCollection', id: 'wanou-login-list', layout: 'chips', categories: [
                                    { id: 'quark', title: '登录夸克网盘', target: 'login:quark', count: null, url: null, icon: 'account' },
                                    { id: 'uc', title: '登录优汐网盘', target: 'login:uc', count: null, url: null, icon: 'account' },
                                    { id: 'baidu', title: '登录百度网盘', target: 'login:baidu', count: null, url: null, icon: 'account' },
                                ],
                            }] },
                ] } });
    }
    if (request.target.startsWith('login:'))
        return openLogin(request.target);
    const category = categories.find(([id]) => request.target === `category:${id}`);
    if (category === undefined)
        throw new Error('Discovery target is invalid.');
    const page = cursorPage(request.cursor, request.target);
    const values = parseListings(await fetchSite(categoryUrl(category[2], page)), 'category');
    return collectionResponse(`wanou:${category[0]}`, category[1], request, values, page);
}
export async function search(request) {
    const query = clean(request.query);
    if (query === '')
        return frozen({ items: [], nextCursor: null, totalCount: 0 });
    const page = cursorPage(request.cursor, 'search');
    const values = parseListings(await fetchSite(`${site}/vodsearch/-------------.html?wd=${encodeURIComponent(query)}${page > 1 ? `&page=${page}` : ''}`), 'search');
    const items = values.slice(0, clamp(request.pageSize)).map(summary);
    return frozen({ items, nextCursor: values.length >= clamp(request.pageSize) && page < 50 ? `search:${page + 1}` : null, totalCount: null });
}
export async function searchSuggestions(_request) { return frozen({ items: [], nextCursor: null }); }
export async function getDetail(request) {
    const url = contentUrl(request.id);
    const detail = parseDetail(await fetchSite(url), url);
    return frozen({ ...summary(detail), aliases: [], catalogUrl: url, chapterCount: null });
}
export async function getChapters(request) {
    const url = contentUrl(request.id);
    const html = await fetchSite(url);
    const shares = extractShares(html);
    const groups = [];
    const items = [];
    for (const [index, share] of shares.entries()) {
        let files = [];
        try {
            files = await listShareFiles(share);
        }
        catch (error) {
            requireContext().log.warn(`share_listing_failed:${share.provider}:${safeError(error)}`);
            // A concrete, selectable login prompt is more useful than silently dropping
            // a share. It never claims that a file or playback URL was discovered.
            files = [{ id: 'login', name: loginHint(share.provider), path: '', size: 0, token: null }];
        }
        const episodes = files.map((file, order) => chapterItem(share, file, order));
        const title = providerLabel(share.provider) + (shares.length > 1 ? ` ${index + 1}` : '');
        groups.push(frozen({ id: `cloud:${share.provider}:${share.id}:${index}`, title, order: index, episodes }));
        items.push(...episodes);
    }
    return frozen({ items, groups });
}
export async function getContent(request) {
    contentUrl(request.id); // validate ownership before requesting a provider.
    const chapter = decodeChapter(request.chapterId);
    if (chapter.file.id === 'login') {
        await openProviderLogin(chapter.share.provider);
        throw new Error(`${providerLabel(chapter.share.provider)}需要登录：已打开官方登录页，完成登录后返回并重新打开目录。`);
    }
    const resolved = await resolvePlayback(chapter);
    const resourceType = /\.m3u8(?:$|[?#])/iu.test(resolved.url) ? 'hls' : 'video';
    const headers = { Referer: resolved.referer, 'User-Agent': userAgent };
    return frozen({
        chapterId: request.chapterId, contentKind: 'video', title: chapter.file.name, updatedAt: null, text: null, pages: [],
        media: { url: requireContext().resource.proxy({ kind: resourceType, url: resolved.url, headers }), resourceType,
            resourcePolicy: 'sessionOnly', expiresAt: null, mimeType: resourceType === 'hls' ? 'application/vnd.apple.mpegurl' : 'video/mp4', headers },
    });
}
async function openLogin(target) {
    const provider = target.slice('login:'.length);
    if (provider !== 'quark' && provider !== 'uc' && provider !== 'baidu')
        throw new Error('Login provider is invalid.');
    await openProviderLogin(provider);
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `wanou-${provider}-login-opened`, title: `${providerLabel(provider)}登录已打开`, subtitle: '请在打开的官方页面完成登录；完成后回到详情页重新加载线路。', icon: 'account', children: [] }] } });
}
async function openProviderLogin(provider) {
    const url = provider === 'quark' ? 'https://pan.quark.cn/' : provider === 'uc' ? 'https://drive.uc.cn/' : 'https://pan.baidu.com/';
    await withPage(async (page) => { await page.navigate(url, { timeoutMs: 45_000 }); await page.show({ timeoutMs: 15_000 }); });
    requireContext().log.info(`login_page_opened:${provider}`);
}
async function listShareFiles(share) {
    if (share.provider === 'quark' || share.provider === 'uc')
        return listUcLikeShare(share);
    return listBaiduShare(share);
}
async function listUcLikeShare(share) {
    const origin = share.provider === 'quark' ? 'https://drive-h.quark.cn' : 'https://pc-api.uc.cn';
    const query = share.provider === 'quark' ? 'pr=ucpro&fr=pc' : 'pr=UCBrowser&fr=pc';
    return withPage(async (page) => {
        await page.navigate(share.url, { timeoutMs: 45_000 });
        const token = await page.fetch({ url: `${origin}/1/clouddrive/share/sharepage/token?${query}`, method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pwd_id: share.id, passcode: share.passcode }), responseType: 'json', timeoutMs: 30_000 });
        const stoken = nestedString(token.body, ['data', 'stoken']);
        if (stoken === '')
            throw new Error('login_or_share_password_required');
        const queue = [{ id: '0', path: '' }];
        const files = [];
        const visited = new Set();
        while (queue.length > 0 && visited.size < 30) {
            const folder = queue.shift();
            if (folder === undefined || visited.has(folder.id))
                continue;
            visited.add(folder.id);
            const url = `${origin}/1/clouddrive/share/sharepage/detail?${query}&pwd_id=${encodeURIComponent(share.id)}&stoken=${encodeURIComponent(stoken)}&pdir_fid=${encodeURIComponent(folder.id)}&force=0&_page=1&_size=200&_sort=file_type:asc,file_name:asc`;
            const response = await page.fetch({ url, responseType: 'json', timeoutMs: 30_000 });
            const list = nestedArray(response.body, ['data', 'list']);
            for (const value of list) {
                if (!isRecord(value))
                    continue;
                const id = firstString(value.fid, value.file_id);
                const name = firstString(value.file_name, value.name);
                if (id === '' || name === '')
                    continue;
                const path = `${folder.path}${name}`;
                const dir = value.dir === true || value.dir === 1 || value.file === false || value.file_type === 'folder';
                if (dir) {
                    queue.push({ id, path: `${path}/` });
                    continue;
                }
                if (isVideo(name, value))
                    files.push({ id, name, path, size: number(value.size, value.file_size), token: nullable(firstString(value.share_fid_token)) });
            }
        }
        if (files.length === 0)
            throw new Error('no_playable_files_or_login_required');
        return files.sort((a, b) => a.path.localeCompare(b.path, 'zh-CN', { numeric: true }));
    });
}
async function listBaiduShare(share) {
    return withPage(async (page) => {
        await page.navigate(share.url, { timeoutMs: 45_000 });
        const shorturl = share.id;
        const url = `https://pan.baidu.com/share/list?app_id=250528&channel=chunlei&clienttype=0&web=1&desc=1&order=time&page=1&num=200&root=1&shorturl=${encodeURIComponent(shorturl)}`;
        const response = await page.fetch({ url, responseType: 'json', timeoutMs: 30_000 });
        const list = firstArray(response.body, 'list', 'data');
        const files = list.flatMap((value) => {
            if (!isRecord(value) || number(value.isdir, value.is_dir) !== 0)
                return [];
            const id = firstString(value.fs_id, value.fsid);
            const name = firstString(value.server_filename, value.name);
            if (id === '' || name === '' || !isVideo(name, value))
                return [];
            return [{ id, name, path: firstString(value.path, name), size: number(value.size), token: null }];
        });
        if (files.length === 0)
            throw new Error('no_playable_files_or_login_required');
        return files.sort((a, b) => a.path.localeCompare(b.path, 'zh-CN', { numeric: true }));
    });
}
async function resolvePlayback(chapter) {
    // The three providers deliberately keep download authorization in their own
    // browser profile. The source does not manufacture cookies, transfer files,
    // scrape QR data, or use the legacy script's embedded app keys.
    return withPage(async (page) => {
        await page.navigate(chapter.share.url, { timeoutMs: 45_000 });
        const raw = await page.executeJavaScript(`(async()=>{
      const wanted=${JSON.stringify(chapter.file.id)};
      const rows=Array.from(document.querySelectorAll('[data-fid],[data-file-id],[data-id]'));
      const row=rows.find(node=>[node.dataset.fid,node.dataset.fileId,node.dataset.id].includes(wanted));
      if(row instanceof HTMLElement) row.click();
      const direct=Array.from(document.querySelectorAll('video')).map(node=>node.currentSrc||node.src||'').find(url=>/^https?:/i.test(url));
      if(direct)return direct;
      const entries=performance.getEntriesByType('resource').map(entry=>entry.name).filter(url=>/^https?:/i.test(url)&&(/\\.m3u8(?:[?#]|$)/i.test(url)||/download|play|video/i.test(url)));
      return entries.at(-1)||'';
    })()`, { timeoutMs: 25_000 });
        const url = typeof raw === 'string' ? safeUrl(raw) : '';
        if (url === '')
            throw new Error('播放地址未由网盘页面提供。请确认已登录并在官方分享页有播放权限。');
        return { url, referer: chapter.share.url };
    });
}
async function fetchSite(url) {
    // Wogg returned 403 through the configured HTTP proxy during the source-test
    // probe. Its public page is the source of truth, so request it directly just
    // as the media source does; this never accepts a source-provided proxy URL.
    const response = await requireContext().http.fetch(url, { proxyMode: 'direct', headers: {
            Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8', Referer: `${site}/`, 'User-Agent': userAgent,
        } });
    if (response.ok)
        return response.text();
    // Wogg can put a browser verification in front of an otherwise public page.
    // A normal page navigation preserves that site's own cookies/challenge state;
    // it is deliberately not a CAPTCHA bypass or a replay of browser credentials.
    if (response.status === 403 || response.status === 429) {
        requireContext().log.warn(`site_http_fallback_webview:${response.status}`);
        return withPage(async (page) => {
            await page.navigate(url, { timeoutMs: 45_000 });
            return page.getHtml({ timeoutMs: 20_000 });
        });
    }
    throw new Error(`玩偶站请求失败：${response.status}`);
}
function collectionResponse(id, title, request, values, page) {
    const items = values.slice(0, clamp(request.pageSize)).map((content) => frozen({ content: summary(content), rank: null, metric: null, recommendation: null }));
    const continuation = values.length >= clamp(request.pageSize) && page < 50 ? frozen({ target: request.target, cursor: `${request.target}:${page + 1}` }) : null;
    if (request.collectionId !== null) {
        if (request.collectionId !== id)
            throw new Error('Discovery collection is invalid.');
        return frozen({ kind: 'append', collectionId: id, items, continuation });
    }
    return frozen({ kind: 'document', document: { components: [{ type: 'section', id: `${id}:section`, title, subtitle: null, icon: 'video', children: [{ type: 'contentCollection', id, layout: 'coverGrid', items, continuation }] }] } });
}
function parseListings(html, mode) {
    const blocks = mode === 'search' ? html.match(/<[^>]*class=["'][^"']*module-search-item[^"']*["'][^>]*>[\s\S]*?<\/[^>]+>/giu) ?? [] : html.match(/<[^>]*class=["'][^"']*module-item[^"']*["'][^>]*>[\s\S]*?<\/[^>]+>/giu) ?? [];
    const values = blocks.flatMap((block) => listingFromHtml(block));
    return [...new Map(values.map((value) => [value.id, value])).values()];
}
function listingFromHtml(html) {
    const href = attribute(html, /<a\b[^>]*href=["']([^"']*voddetail[^"']*)["'][^>]*>/iu) || attribute(html, /<a\b[^>]*href=["']([^"']+)["'][^>]*>/iu);
    const image = /<img\b[^>]*>/iu.exec(html)?.[0] ?? '';
    const title = clean(attribute(image, /alt=["']([^"']+)["']/iu) || attribute(html, /title=["']([^"']+)["']/iu) || textOf(html));
    const url = absolute(href);
    if (title === '' || url === '')
        return [];
    return [{ id: encodeText(url), title, cover: absolute(attribute(image, /(?:data-src|data-original|src)=["']([^"']+)["']/iu)), latest: clean(textOf(firstMatch(html, /(?:module-item-text|video-serial|module-item-note)[^>]*>([\s\S]*?)<\//iu))), url }];
}
function parseDetail(html, url) {
    const title = clean(textOf(firstMatch(html, /<h1\b[^>]*>([\s\S]*?)<\/h1>/iu))) || '玩偶视频';
    const image = /(?:mobile-play|video-cover|module-item-cover)[\s\S]{0,1200}?<img\b[^>]*>/iu.exec(html)?.[0] ?? '';
    const cover = absolute(attribute(image, /(?:data-src|data-original|src)=["']([^"']+)["']/iu));
    const description = clean(textOf(firstMatch(html, /(?:video-info-content|module-info-introduction-content|detail-content|vod_content)[^>]*>([\s\S]*?)<\//iu)));
    return { id: encodeText(url), title, cover, latest: description, url };
}
function extractShares(html) {
    const variants = [html, html.replaceAll('\\/', '/').replaceAll('&amp;', '&')];
    const values = [];
    for (const value of variants) {
        for (const match of value.matchAll(/https?:\/\/(?:pan\.quark\.cn\/s\/[A-Za-z0-9_-]+|(?:pan\.baidu\.com\/s\/[A-Za-z0-9_-]+)|(?:(?:drive|pan)\.uc\.cn\/s\/[A-Za-z0-9_-]+))(?:\?[^"'<>\s]*)?/giu)) {
            const raw = match[0];
            const provider = /quark/iu.test(raw) ? 'quark' : /baidu/iu.test(raw) ? 'baidu' : 'uc';
            const id = provider === 'baidu' ? (/\/s\/1?([A-Za-z0-9_-]+)/iu.exec(raw)?.[1] ?? '') : (/\/s\/([A-Za-z0-9_-]+)/iu.exec(raw)?.[1] ?? '');
            if (id === '')
                continue;
            values.push({ provider, id, url: raw.replace(/[?#].*$/u, ''), passcode: passwordNear(value, match.index ?? 0) });
        }
    }
    return [...new Map(values.map((share) => [`${share.provider}:${share.id}`, share])).values()];
}
function summary(value) { return frozen({ id: `wanou:${value.id}`, title: value.title, contentKind: 'video', coverOrientation: 'portrait', author: null, url: value.url, coverUrl: value.cover === '' ? null : requireContext().resource.proxy({ kind: 'image', url: value.cover, headers: { Referer: `${site}/` } }), description: value.latest === '' ? null : value.latest, language: 'zh-CN', status: 'unknown', access: 'unknown', wordCount: null, chapterCount: null, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [] }); }
function chapterItem(share, file, order) { const id = encodeText(JSON.stringify({ share, file })); return frozen({ id: `wanou-chapter:${id}`, title: file.name, order, url: null, volumeTitle: providerLabel(share.provider), wordCount: null, updatedAt: null, isLocked: file.id === 'login', attributes: [] }); }
function decodeChapter(value) { const encoded = /^wanou-chapter:([A-Za-z0-9_-]+)$/u.exec(value)?.[1]; if (encoded === undefined)
    throw new Error('Chapter ID is invalid.'); try {
    const parsed = JSON.parse(decodeText(encoded));
    if (!isRecord(parsed) || !isRecord(parsed.share) || !isRecord(parsed.file))
        throw new Error();
    const provider = parsed.share.provider;
    if (provider !== 'baidu' && provider !== 'quark' && provider !== 'uc')
        throw new Error();
    const url = firstString(parsed.share.url);
    const id = firstString(parsed.share.id);
    const name = firstString(parsed.file.name);
    const fileId = firstString(parsed.file.id);
    if (url === '' || id === '' || name === '' || fileId === '')
        throw new Error();
    return { share: { provider, url, id, passcode: firstString(parsed.share.passcode) }, file: { id: fileId, name, path: firstString(parsed.file.path), size: number(parsed.file.size), token: nullable(firstString(parsed.file.token)) } };
}
catch {
    throw new Error('Chapter ID is invalid.');
} }
function contentUrl(value) { const encoded = /^wanou:([A-Za-z0-9_-]+)$/u.exec(value)?.[1]; if (encoded === undefined)
    throw new Error('Content ID is invalid.'); const url = safeUrl(decodeText(encoded)); if (!url.startsWith(site))
    throw new Error('Content ID is invalid.'); return url; }
function categoryUrl(id, page) { return page === 1 ? `${site}/vodshow/${id}-----------.html` : `${site}/vodshow/${id}--------${page}---.html`; }
function withPage(action) { const run = pageQueue.then(async () => action(await requireContext().webview.open({ visible: false, timeoutMs: 30_000 }))); pageQueue = run.then(() => undefined, () => undefined); return run; }
function providerLabel(provider) { return provider === 'quark' ? '夸克网盘' : provider === 'uc' ? '优汐网盘' : '百度网盘'; }
function loginHint(provider) { return `${providerLabel(provider)}（请先在发现页的“网盘登录”完成登录）`; }
function isVideo(name, value) { const extension = /\.([a-z0-9]+)(?:$|[?#])/iu.exec(name)?.[1]?.toLowerCase() ?? ''; return videoExtensions.has(extension) || /video/iu.test(firstString(value.obj_category, value.category, value.file_type)); }
function nestedArray(value, keys) { let current = value; for (const key of keys) {
    if (!isRecord(current))
        return [];
    current = current[key];
} return Array.isArray(current) ? current : []; }
function nestedString(value, keys) { let current = value; for (const key of keys) {
    if (!isRecord(current))
        return '';
    current = current[key];
} return firstString(current); }
function firstArray(value, ...keys) { if (!isRecord(value))
    return []; for (const key of keys) {
    const candidate = value[key];
    if (Array.isArray(candidate))
        return candidate;
    if (isRecord(candidate) && Array.isArray(candidate.list))
        return candidate.list;
} return []; }
function firstString(...values) { for (const value of values)
    if (typeof value === 'string' || typeof value === 'number') {
        const text = String(value).trim();
        if (text !== '')
            return text;
    } return ''; }
function number(...values) { const value = Number(values.find((item) => item !== null && item !== undefined && item !== '') ?? 0); return Number.isFinite(value) && value >= 0 ? value : 0; }
function nullable(value) { return value === '' ? null : value; }
function cursorPage(cursor, target) { if (cursor === null)
    return 1; const value = Number(cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : ''); if (!Number.isSafeInteger(value) || value < 2 || value > 50)
    throw new Error('Cursor is invalid.'); return value; }
function clamp(value) { return Math.max(1, Math.min(50, Math.floor(value))); }
function absolute(value) { if (value === '')
    return ''; try {
    return new URL(value, site).toString();
}
catch {
    return '';
} }
function safeUrl(value) { try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.toString() : '';
}
catch {
    return '';
} }
function attribute(value, pattern) { return pattern.exec(value)?.[1] ? decodeHtml(pattern.exec(value)?.[1] ?? '') : ''; }
function firstMatch(value, pattern) { return pattern.exec(value)?.[1] ?? ''; }
function textOf(value) { return decodeHtml(value.replace(/<[^>]+>/gu, ' ').replace(/\s+/gu, ' ')); }
function decodeHtml(value) { return value.replace(/&(?:amp|#38);/giu, '&').replace(/&nbsp;/giu, ' ').replace(/&quot;/giu, '"').replace(/&#39;/giu, "'"); }
function clean(value) { return value.replace(/[\s\u3000\u00a0]+/gu, ' ').trim(); }
function passwordNear(value, index) { return /(?:提取码|密码|pwd|passcode)\s*[:：=]\s*([A-Za-z0-9]{4,})/iu.exec(value.slice(Math.max(0, index - 120), index + 240))?.[1] ?? ''; }
function encodeText(value) { return Buffer.from(value, 'utf8').toString('base64url'); }
function decodeText(value) { return Buffer.from(value, 'base64url').toString('utf8'); }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function frozen(value) { return Object.freeze(value); }
function safeError(error) { return error instanceof Error ? error.message.slice(0, 120) : 'unknown'; }
function requireContext() { if (context === undefined)
    throw new Error('Source is not activated.'); return context; }
