import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, rename, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';

const schemaVersion = 1;
const directoryName = 'html-cache-v1';
const maximumCacheBytes = 100 * 1024 * 1024;
const maximumEntryBytes = 1024 * 1024;
const cacheFilePattern = /^[a-f0-9]{64}\.json$/u;

/**
 * Bounded plugin-private HTML cache. It only writes below Runtime's absolute
 * ctx.cacheDir and has no dependency on Flutter, Runtime transports, or URLs
 * outside the supplied request key.
 */
export class PluginHtmlCache {
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

  getOrFetch(url, policy, fetcher) {
    return this.getOrFetchResult(url, policy, fetcher).then((result) => result.body);
  }

  getOrFetchResult(url, policy, fetcher) {
    if (this.#root === undefined) {
      return fetcher().then((body) => Object.freeze({ body, storedAtMs: this.#now() }));
    }
    const key = cacheKey(policy.namespace, url);
    const existing = this.#inflight.get(key);
    if (existing !== undefined) return existing;
    const pending = this.#readOrFetch(key, policy, fetcher);
    this.#inflight.set(key, pending);
    void pending.then(() => this.#inflight.delete(key), () => this.#inflight.delete(key));
    return pending;
  }

  async #readOrFetch(key, policy, fetcher) {
    const cached = await this.#read(key);
    if (cached !== undefined && this.#now() - cached.storedAtMs <= policy.staleAfterMs) {
      await this.#touch(key);
      return cached;
    }
    if (cached !== undefined && policy.serveStaleWhileRevalidate === true) {
      // Discovery cards carry low-volatility display data. Rendering a stale
      // projection avoids a loading flash; one background refresh supplies the
      // next visit without overlapping requests.
      void this.#refreshInBackground(key, fetcher);
      await this.#touch(key);
      return cached;
    }
    // A user may open a detail while discovery is refreshing the same stale
    // HTML. Join that refresh before considering a strict foreground request,
    // so the two paths never duplicate the remote fetch.
    const backgroundRefresh = this.#backgroundRefreshes.get(key);
    if (backgroundRefresh !== undefined) {
      await backgroundRefresh;
      const refreshed = await this.#read(key);
      if (refreshed !== undefined && this.#now() - refreshed.storedAtMs <= policy.staleAfterMs) {
        await this.#touch(key);
        return refreshed;
      }
    }
    try {
      const body = await fetcher();
      const storedAtMs = this.#now();
      await this.#write(key, body, storedAtMs);
      return Object.freeze({ body, storedAtMs });
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
        const body = await fetcher();
        await this.#write(key, body, this.#now());
      } catch {
        // The foreground already returned a usable stale discovery projection.
      }
    })();
    this.#backgroundRefreshes.set(key, refresh);
    void refresh.then(() => this.#backgroundRefreshes.delete(key), () => this.#backgroundRefreshes.delete(key));
    return refresh;
  }

  async #read(key) {
    try {
      const path = this.#entryPath(key);
      const metadata = await stat(path);
      if (!metadata.isFile() || metadata.size > this.#maximumEntryBytes) return undefined;
      const value = JSON.parse(await readFile(path, 'utf8'));
      if (!isRecord(value) || value.schemaVersion !== schemaVersion || typeof value.body !== 'string' || !Number.isSafeInteger(value.storedAtMs) || value.storedAtMs < 0 || Buffer.byteLength(value.body, 'utf8') > this.#maximumEntryBytes) return undefined;
      return Object.freeze({ body: value.body, storedAtMs: value.storedAtMs });
    } catch { return undefined; }
  }

  async #write(key, body, storedAtMs) {
    if (Buffer.byteLength(body, 'utf8') > this.#maximumEntryBytes || this.#root === undefined) return;
    const temporary = resolve(this.#root, `.${key}.${randomUUID()}.partial`);
    try {
      await mkdir(this.#root, { recursive: true });
      const encoded = JSON.stringify({ body, schemaVersion, storedAtMs });
      if (Buffer.byteLength(encoded, 'utf8') > this.#maximumEntryBytes) return;
      await writeFile(temporary, encoded, 'utf8');
      await rename(temporary, this.#entryPath(key));
      await this.#enforceCapacity();
    } catch { /* Cache I/O is best effort. */
    } finally { await rm(temporary, { force: true }).catch(() => undefined); }
  }

  async #touch(key) {
    try { const now = new Date(this.#now()); await utimes(this.#entryPath(key), now, now); } catch { /* LRU is expendable. */ }
  }

  async #enforceCapacity() {
    if (this.#root === undefined) return;
    const entries = await readdir(this.#root, { withFileTypes: true });
    const candidates = await Promise.all(entries.filter((entry) => entry.isFile() && cacheFilePattern.test(entry.name)).map(async (entry) => {
      const path = resolve(this.#root, entry.name);
      const metadata = await stat(path);
      return { path, size: metadata.size, accessedAtMs: metadata.mtimeMs };
    }));
    let total = candidates.reduce((sum, entry) => sum + entry.size, 0);
    for (const entry of candidates.sort((left, right) => left.accessedAtMs - right.accessedAtMs)) {
      if (total <= this.#maximumCacheBytes) return;
      await rm(entry.path, { force: true });
      total -= entry.size;
    }
  }

  #entryPath(key) {
    if (this.#root === undefined || !/^[a-f0-9]{64}$/u.test(key)) throw new Error('Cache key is invalid.');
    return resolve(this.#root, `${key}.json`);
  }
}

function cacheKey(namespace, url) { return createHash('sha256').update(`${namespace}\n${url}`, 'utf8').digest('hex'); }
function positiveLimit(value) { if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Cache limit is invalid.'); return value; }
function isRecord(value) { return typeof value === 'object' && value !== null && !Array.isArray(value); }
