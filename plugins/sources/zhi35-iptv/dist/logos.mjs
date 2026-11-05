import { safeHttpUrl } from './playlist.mjs';
const catalogUrl = 'https://upload.112114.xyz/logo/';
const day = 24 * 60 * 60_000;
const maximumCatalogBytes = 3 * 1024 * 1024;
export function canonicalLogoUrl(value) {
    const safe = safeHttpUrl(value);
    if (safe === null)
        return null;
    const url = new URL(safe);
    if (['live.fanmingming.cn', 'live.fanmingming.com'].includes(url.hostname) && /^\/tv\/[^/]+\.png$/iu.test(url.pathname)) {
        return `https://raw.githubusercontent.com/fanmingming/live/main${url.pathname}`;
    }
    if (url.hostname !== 'ghproxy.zhi35.com' && url.hostname !== 'ghp.ci')
        return safe;
    const embedded = url.pathname.slice(1).replace(/^raw\.githubusercontent\.com\//u, 'https://raw.githubusercontent.com/');
    const upstream = safeHttpUrl(embedded);
    if (upstream === null)
        return null;
    const raw = new URL(upstream);
    // 上游 CTI3.pngg 为笔误；该仓库真实文件 img/CTI3.png 对应中天娱乐台标。
    if (raw.origin === 'https://raw.githubusercontent.com' && raw.pathname === '/wanglindl/TVlogo/main/img/CTI3.pngg') {
        raw.pathname = '/wanglindl/TVlogo/main/img/CTI3.png';
    }
    if (raw.origin !== 'https://raw.githubusercontent.com' ||
        !/^\/(?:wanglindl\/TVlogo\/main\/img|suxuang\/myIPTV\/main\/tvlog)\/[^/]+\.png$/iu.test(raw.pathname))
        return null;
    return raw.href;
}
export function parseLogoCatalog(html) {
    const result = new Map();
    for (const match of html.matchAll(/href\s*=\s*["']([^"']+\.png)["']/giu)) {
        try {
            const url = new URL(match[1].replaceAll('&amp;', '&'), catalogUrl);
            if (url.origin !== new URL(catalogUrl).origin || !url.pathname.startsWith('/logo/') || url.search || url.hash)
                continue;
            const filename = decodeURIComponent(url.pathname.slice('/logo/'.length));
            if (!filename || filename.length > 256 || /[\u0000-\u001f\u007f/\\]/u.test(filename) || !/\.png$/iu.test(filename))
                continue;
            result.set(filename, url.href);
            if (result.size > 20_000)
                throw new Error('logo_catalog_too_many_entries');
        }
        catch (error) {
            if (error instanceof Error && error.message === 'logo_catalog_too_many_entries')
                throw error;
        }
    }
    if (result.size === 0)
        throw new Error('logo_catalog_empty');
    return result;
}
export function createLogoResolver(context, now = Date.now) {
    const cache = new Map();
    const pending = new Map();
    let catalog;
    let catalogExpires = 0;
    let catalogPending;
    let running = 0;
    const waiting = [];
    return { prepare };
    async function prepare(channels) {
        return Promise.all(channels.map(async (channel) => ({ ...channel, cover: await resolve(channel.cover) })));
    }
    async function resolve(cover) {
        if (cover === null)
            return null;
        const canonical = canonicalLogoUrl(cover);
        if (canonical === null)
            return null;
        const url = new URL(canonical);
        if (url.hostname !== 'tb.zbds.top' || !/^\/logo\/[^/]+\.png$/iu.test(url.pathname))
            return canonical;
        const cached = cache.get(canonical);
        if (cached !== undefined && cached.expires > now())
            return cached.url;
        const existing = pending.get(canonical);
        if (existing !== undefined)
            return existing;
        const current = limited(() => repairLocalLogo(canonical));
        pending.set(canonical, current);
        try {
            return await current;
        }
        finally {
            if (pending.get(canonical) === current)
                pending.delete(canonical);
        }
    }
    async function limited(action) {
        if (running >= 4)
            await new Promise((done) => waiting.push(done));
        else
            running += 1;
        try {
            return await action();
        }
        finally {
            const next = waiting.shift();
            if (next !== undefined)
                next();
            else
                running -= 1;
        }
    }
    function remember(key, value, ttl) {
        cache.delete(key);
        cache.set(key, { url: value, expires: now() + ttl });
        while (cache.size > 512)
            cache.delete(cache.keys().next().value);
        return value;
    }
    async function inspect(url) {
        try {
            const response = await context.http.fetch(url, { method: 'HEAD', headers: { Accept: 'image/*' }, signal: AbortSignal.timeout(4000) });
            await response.body?.cancel();
            const mime = (response.headers.get('content-type') ?? '').toLowerCase();
            if (response.ok && /^image\/(?:png|jpeg|gif|webp)(?:;|$)/u.test(mime))
                return 'image';
            if (response.status === 404 || response.status === 410 || (response.ok && /^text\/html/u.test(mime)))
                return 'missing';
        }
        catch {
            context.log.warn('iptv_logo_probe_unavailable');
        }
        return 'unknown';
    }
    async function repairLocalLogo(original) {
        const state = await inspect(original);
        if (state === 'image')
            return remember(original, original, day);
        if (state === 'unknown')
            return remember(original, original, 60_000);
        const entries = await loadCatalog();
        let filename;
        try {
            filename = decodeURIComponent(new URL(original).pathname.slice('/logo/'.length));
        }
        catch {
            return remember(original, null, 5 * 60_000);
        }
        const fallback = entries?.get(filename);
        if (fallback !== undefined && await inspect(fallback) === 'image') {
            context.log.info('iptv_logo_recovered');
            return remember(original, fallback, day);
        }
        context.log.info('iptv_logo_missing');
        return remember(original, null, 5 * 60_000);
    }
    async function loadCatalog() {
        if (catalogExpires > now())
            return catalog;
        if (catalogPending !== undefined)
            return catalogPending;
        const current = (async () => {
            try {
                const response = await context.http.fetch(catalogUrl, { headers: { Accept: 'text/html' }, signal: AbortSignal.timeout(8000) });
                if (!response.ok) {
                    await response.body?.cancel();
                    throw new Error('logo_catalog_http_failed');
                }
                catalog = parseLogoCatalog(await readCatalogHtml(response));
                catalogExpires = now() + day;
                context.log.info(`iptv_logo_catalog_loaded entries=${catalog.size}`);
            }
            catch {
                catalogExpires = now() + 5 * 60_000;
                context.log.warn('iptv_logo_catalog_unavailable');
            }
            return catalog;
        })();
        catalogPending = current;
        try {
            return await current;
        }
        finally {
            if (catalogPending === current)
                catalogPending = undefined;
        }
    }
}
async function readCatalogHtml(response) {
    if (Number(response.headers.get('content-length')) > maximumCatalogBytes || response.body === null) {
        await response.body?.cancel();
        throw new Error('logo_catalog_size_invalid');
    }
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    try {
        while (true) {
            const chunk = await reader.read();
            if (chunk.done)
                break;
            size += chunk.value.byteLength;
            if (size > maximumCatalogBytes)
                throw new Error('logo_catalog_too_large');
            chunks.push(chunk.value);
        }
        return Buffer.concat(chunks).toString('utf8');
    }
    finally {
        await reader.cancel().catch(() => { });
        reader.releaseLock();
    }
}
