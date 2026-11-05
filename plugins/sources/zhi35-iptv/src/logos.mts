/**
 * IPTV 台标地址修复与缺图确认，独立于频道/线路身份。
 * live.fanmingming.cn/com 的 /tv/ 原图取同一官方 GitHub 仓库；失效 GitHub 镜像仅解包允许的原图路径。
 * 地方台先以 HEAD 保留可用原址；确认 404/410/HTML 后，才查现有提供方 112114 的公开目录精确同名回退。
 * 目录只读至多 3 MiB HTML，不猜名称、不模糊匹配、不读取图片/媒体主体。缺图返回 null，保留频道。
 * 每次 activate 创建实例；HEAD 每页至多四路、单 URL 单飞、缓存最多 512 项；目录单飞缓存 24 小时。
 * 传输失败保留原址并短缓存，不把网络波动当作已缺图；无磁盘 IO、定时器或后台任务。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { safeHttpUrl, type Channel } from './playlist.mjs';

const catalogUrl = 'https://upload.112114.xyz/logo/';
const day = 24 * 60 * 60_000;
const maximumCatalogBytes = 3 * 1024 * 1024;
type CachedLogo = { url: string | null; expires: number };

export function canonicalLogoUrl(value: string): string | null {
  const safe = safeHttpUrl(value);
  if (safe === null) return null;
  const url = new URL(safe);
  if (['live.fanmingming.cn', 'live.fanmingming.com'].includes(url.hostname) && /^\/tv\/[^/]+\.png$/iu.test(url.pathname)) {
    return `https://raw.githubusercontent.com/fanmingming/live/main${url.pathname}`;
  }
  if (url.hostname !== 'ghproxy.zhi35.com' && url.hostname !== 'ghp.ci') return safe;
  const embedded = url.pathname.slice(1).replace(/^raw\.githubusercontent\.com\//u, 'https://raw.githubusercontent.com/');
  const upstream = safeHttpUrl(embedded);
  if (upstream === null) return null;
  const raw = new URL(upstream);
  // 上游 CTI3.pngg 为笔误；该仓库真实文件 img/CTI3.png 对应中天娱乐台标。
  if (raw.origin === 'https://raw.githubusercontent.com' && raw.pathname === '/wanglindl/TVlogo/main/img/CTI3.pngg') {
    raw.pathname = '/wanglindl/TVlogo/main/img/CTI3.png';
  }
  if (raw.origin !== 'https://raw.githubusercontent.com' ||
      !/^\/(?:wanglindl\/TVlogo\/main\/img|suxuang\/myIPTV\/main\/tvlog)\/[^/]+\.png$/iu.test(raw.pathname)) return null;
  return raw.href;
}

export function parseLogoCatalog(html: string): Map<string, string> {
  const result = new Map<string, string>();
  for (const match of html.matchAll(/href\s*=\s*["']([^"']+\.png)["']/giu)) {
    try {
      const url = new URL(match[1]!.replaceAll('&amp;', '&'), catalogUrl);
      if (url.origin !== new URL(catalogUrl).origin || !url.pathname.startsWith('/logo/') || url.search || url.hash) continue;
      const filename = decodeURIComponent(url.pathname.slice('/logo/'.length));
      if (!filename || filename.length > 256 || /[\u0000-\u001f\u007f/\\]/u.test(filename) || !/\.png$/iu.test(filename)) continue;
      result.set(filename, url.href);
      if (result.size > 20_000) throw new Error('logo_catalog_too_many_entries');
    } catch (error) {
      if (error instanceof Error && error.message === 'logo_catalog_too_many_entries') throw error;
    }
  }
  if (result.size === 0) throw new Error('logo_catalog_empty');
  return result;
}

export function createLogoResolver(context: MgReadPluginContext, now = Date.now) {
  const cache = new Map<string, CachedLogo>();
  const pending = new Map<string, Promise<string | null>>();
  let catalog: Map<string, string> | undefined;
  let catalogExpires = 0;
  let catalogPending: Promise<Map<string, string> | undefined> | undefined;
  let running = 0;
  const waiting: (() => void)[] = [];
  return { prepare };

  async function prepare(channels: readonly Channel[]): Promise<Channel[]> {
    return Promise.all(channels.map(async (channel) => ({ ...channel, cover: await resolve(channel.cover) })));
  }

  async function resolve(cover: string | null): Promise<string | null> {
    if (cover === null) return null;
    const canonical = canonicalLogoUrl(cover);
    if (canonical === null) return null;
    const url = new URL(canonical);
    if (url.hostname !== 'tb.zbds.top' || !/^\/logo\/[^/]+\.png$/iu.test(url.pathname)) return canonical;
    const cached = cache.get(canonical);
    if (cached !== undefined && cached.expires > now()) return cached.url;
    const existing = pending.get(canonical);
    if (existing !== undefined) return existing;
    const current = limited(() => repairLocalLogo(canonical));
    pending.set(canonical, current);
    try { return await current; }
    finally { if (pending.get(canonical) === current) pending.delete(canonical); }
  }

  async function limited<T>(action: () => Promise<T>): Promise<T> {
    if (running >= 4) await new Promise<void>((done) => waiting.push(done));
    else running += 1;
    try { return await action(); }
    finally {
      const next = waiting.shift();
      if (next !== undefined) next();
      else running -= 1;
    }
  }

  function remember(key: string, value: string | null, ttl: number): string | null {
    cache.delete(key);
    cache.set(key, { url: value, expires: now() + ttl });
    while (cache.size > 512) cache.delete(cache.keys().next().value!);
    return value;
  }

  async function inspect(url: string): Promise<'image' | 'missing' | 'unknown'> {
    try {
      const response = await context.http.fetch(url, { method: 'HEAD', headers: { Accept: 'image/*' }, signal: AbortSignal.timeout(4000) });
      await response.body?.cancel();
      const mime = (response.headers.get('content-type') ?? '').toLowerCase();
      if (response.ok && /^image\/(?:png|jpeg|gif|webp)(?:;|$)/u.test(mime)) return 'image';
      if (response.status === 404 || response.status === 410 || (response.ok && /^text\/html/u.test(mime))) return 'missing';
    } catch { context.log.warn('iptv_logo_probe_unavailable'); }
    return 'unknown';
  }

  async function repairLocalLogo(original: string): Promise<string | null> {
    const state = await inspect(original);
    if (state === 'image') return remember(original, original, day);
    if (state === 'unknown') return remember(original, original, 60_000);
    const entries = await loadCatalog();
    let filename: string;
    try { filename = decodeURIComponent(new URL(original).pathname.slice('/logo/'.length)); }
    catch { return remember(original, null, 5 * 60_000); }
    const fallback = entries?.get(filename);
    if (fallback !== undefined && await inspect(fallback) === 'image') {
      context.log.info('iptv_logo_recovered');
      return remember(original, fallback, day);
    }
    context.log.info('iptv_logo_missing');
    return remember(original, null, 5 * 60_000);
  }

  async function loadCatalog(): Promise<Map<string, string> | undefined> {
    if (catalogExpires > now()) return catalog;
    if (catalogPending !== undefined) return catalogPending;
    const current = (async () => {
      try {
        const response = await context.http.fetch(catalogUrl, { headers: { Accept: 'text/html' }, signal: AbortSignal.timeout(8000) });
        if (!response.ok) { await response.body?.cancel(); throw new Error('logo_catalog_http_failed'); }
        catalog = parseLogoCatalog(await readCatalogHtml(response));
        catalogExpires = now() + day;
        context.log.info(`iptv_logo_catalog_loaded entries=${catalog.size}`);
      } catch {
        catalogExpires = now() + 5 * 60_000;
        context.log.warn('iptv_logo_catalog_unavailable');
      }
      return catalog;
    })();
    catalogPending = current;
    try { return await current; }
    finally { if (catalogPending === current) catalogPending = undefined; }
  }
}

async function readCatalogHtml(response: Response): Promise<string> {
  if (Number(response.headers.get('content-length')) > maximumCatalogBytes || response.body === null) {
    await response.body?.cancel();
    throw new Error('logo_catalog_size_invalid');
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > maximumCatalogBytes) throw new Error('logo_catalog_too_large');
      chunks.push(chunk.value);
    }
    return Buffer.concat(chunks).toString('utf8');
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}
