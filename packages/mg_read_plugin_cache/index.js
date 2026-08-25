/**
 * MgRead 插件私有通用缓存库。
 *
 * 职责：
 * - 在 Runtime 注入的绝对 cacheDir 下原子保存有界文本或 JSON 投影。
 * - 提供单飞、过期回退、后台刷新和 LRU 淘汰。
 *
 * 注意：
 * - 只能缓存稳定、可重复取得的展示投影，不能缓存正文、Cookie 或凭据。
 * - 调用方必须为 JSON 投影提供解码器；损坏或旧结构一律按未命中处理。
 *
 * TODO:
 * - 无。
 */
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, rename, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';

const schemaVersion = 2;
const directoryName = 'plugin-cache-v2';
const maximumCacheBytes = 100 * 1024 * 1024;
const maximumEntryBytes = 1024 * 1024;
const cacheFilePattern = /^[a-f0-9]{64}\.json$/u;

/** Bounded, persistent cache for source HTML and decoded source projections. */
export class PluginCache {
  #root;
  #now;
  #maximumCacheBytes;
  #maximumEntryBytes;
  #inflight = new Map();
  #backgroundRefreshes = new Map();

  constructor(cacheDir, options = {}) {
    this.#root = isAbsolute(cacheDir) ? resolve(cacheDir, directoryName) : undefined;
    this.#now = options.now ?? Date.now;
    this.#maximumCacheBytes = positiveLimit(options.maximumCacheBytes ?? maximumCacheBytes);
    this.#maximumEntryBytes = positiveLimit(options.maximumEntryBytes ?? maximumEntryBytes);
  }

  getOrFetchText(url, policy, fetcher) { return this.getOrFetchTextResult(url, policy, fetcher).then((result) => result.value); }
  getOrFetchTextResult(url, policy, fetcher) { return this.#getOrFetch(cacheKey(policy.namespace, url), policy, async () => ({ value: await fetcher(), storedAtMs: this.#now() }), asText); }
  getOrFetchJson(cacheKeyInput, policy, fetcher, decode) { return this.getOrFetchJsonResult(cacheKeyInput, policy, fetcher, decode).then((result) => result.value); }
  getOrFetchJsonResult(cacheKeyInput, policy, fetcher, decode) {
    if (typeof cacheKeyInput !== 'string' || cacheKeyInput.length === 0 || cacheKeyInput.length > 512) throw new Error('Cache key is invalid.');
    return this.#getOrFetch(cacheKey(policy.namespace, cacheKeyInput), policy, fetcher, decode);
  }

  #getOrFetch(key, policy, fetcher, decode) {
    if (this.#root === undefined) return fetcher();
    const existing = this.#inflight.get(key);
    if (existing !== undefined) return existing;
    const pending = this.#readOrFetch(key, policy, fetcher, decode);
    this.#inflight.set(key, pending);
    void pending.then(() => this.#inflight.delete(key), () => this.#inflight.delete(key));
    return pending;
  }

  async #readOrFetch(key, policy, fetcher, decode) {
    const cached = await this.#read(key, decode);
    if (cached !== undefined && this.#now() - cached.storedAtMs <= policy.staleAfterMs) { void this.#touch(key); return cached; }
    if (cached !== undefined && policy.serveStaleWhileRevalidate === true) { void this.#refreshInBackground(key, fetcher); void this.#touch(key); return cached; }
    const backgroundRefresh = this.#backgroundRefreshes.get(key);
    if (backgroundRefresh !== undefined) {
      await backgroundRefresh;
      const refreshed = await this.#read(key, decode);
      if (refreshed !== undefined && this.#now() - refreshed.storedAtMs <= policy.staleAfterMs) return refreshed;
    }
    try {
      const fetched = await fetcher();
      const storedAtMs = validStoredAt(fetched.storedAtMs) ? fetched.storedAtMs : this.#now();
      await this.#write(key, fetched.value, storedAtMs);
      return Object.freeze({ value: fetched.value, storedAtMs });
    } catch (error) {
      if (cached !== undefined && policy.allowStaleOnError !== false) return cached;
      throw error;
    }
  }

  #refreshInBackground(key, fetcher) {
    const existing = this.#backgroundRefreshes.get(key);
    if (existing !== undefined) return existing;
    const refresh = (async () => {
      try {
        const fetched = await fetcher();
        await this.#write(key, fetched.value, validStoredAt(fetched.storedAtMs) ? fetched.storedAtMs : this.#now());
      } catch { /* Stale discovery data is already usable. */ }
    })();
    this.#backgroundRefreshes.set(key, refresh);
    void refresh.then(() => this.#backgroundRefreshes.delete(key), () => this.#backgroundRefreshes.delete(key));
    return refresh;
  }

  async #read(key, decode) {
    try {
      const path = this.#entryPath(key); const metadata = await stat(path);
      if (!metadata.isFile() || metadata.size > this.#maximumEntryBytes) return undefined;
      const record = JSON.parse(await readFile(path, 'utf8'));
      if (!isRecord(record) || record.schemaVersion !== schemaVersion || !validStoredAt(record.storedAtMs)) return undefined;
      const value = decode(record.value);
      if (value === undefined || byteLength(record) > this.#maximumEntryBytes) return undefined;
      return Object.freeze({ value, storedAtMs: record.storedAtMs });
    } catch { return undefined; }
  }

  async #write(key, value, storedAtMs) {
    if (this.#root === undefined) return;
    const temporary = resolve(this.#root, `.${key}.${randomUUID()}.partial`);
    try {
      await mkdir(this.#root, { recursive: true });
      const encoded = JSON.stringify({ schemaVersion, storedAtMs, value });
      if (Buffer.byteLength(encoded, 'utf8') > this.#maximumEntryBytes) return;
      await writeFile(temporary, encoded, 'utf8'); await rename(temporary, this.#entryPath(key)); await this.#enforceCapacity();
    } catch { /* Cache I/O is best effort. */
    } finally { await rm(temporary, { force: true }).catch(() => undefined); }
  }

  async #touch(key) { try { const now = new Date(this.#now()); await utimes(this.#entryPath(key), now, now); } catch { /* LRU is expendable. */ } }
  async #enforceCapacity() {
    if (this.#root === undefined) return;
    const entries = await readdir(this.#root, { withFileTypes: true });
    const candidates = await Promise.all(entries.filter((entry) => entry.isFile() && cacheFilePattern.test(entry.name)).map(async (entry) => {
      const path = resolve(this.#root, entry.name); const metadata = await stat(path); return { path, size: metadata.size, accessedAtMs: metadata.mtimeMs };
    }));
    let total = candidates.reduce((sum, entry) => sum + entry.size, 0);
    for (const entry of candidates.sort((left, right) => left.accessedAtMs - right.accessedAtMs)) { if (total <= this.#maximumCacheBytes) return; await rm(entry.path, { force: true }); total -= entry.size; }
  }
  #entryPath(key) { if (this.#root === undefined || !/^[a-f0-9]{64}$/u.test(key)) throw new Error('Cache key is invalid.'); return resolve(this.#root, `${key}.json`); }
}

/** Backward-compatible HTML facade for existing standard plugins. */
export class PluginHtmlCache extends PluginCache {
  getOrFetch(url, policy, fetcher) { return this.getOrFetchText(url, policy, fetcher); }
  getOrFetchResult(url, policy, fetcher) { return this.getOrFetchTextResult(url, policy, fetcher).then((result) => Object.freeze({ body: result.value, storedAtMs: result.storedAtMs })); }
}

function cacheKey(namespace, input) { return createHash('sha256').update(`${namespace}\n${input}`, 'utf8').digest('hex'); }
function positiveLimit(value) { if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Cache limit is invalid.'); return value; }
function validStoredAt(value) { return Number.isSafeInteger(value) && value >= 0; }
function isRecord(value) { return typeof value === 'object' && value !== null && !Array.isArray(value); }
function asText(value) { return typeof value === 'string' ? value : undefined; }
function byteLength(value) { try { return Buffer.byteLength(JSON.stringify(value), 'utf8'); } catch { return Number.POSITIVE_INFINITY; } }
