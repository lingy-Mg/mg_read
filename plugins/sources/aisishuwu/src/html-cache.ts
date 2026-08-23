import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, rename, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';

const cacheSchemaVersion = 1;
const cacheDirectoryName = 'html-cache-v1';
const defaultMaximumCacheBytes = 100 * 1024 * 1024;
const defaultMaximumEntryBytes = 1024 * 1024;
const cacheFilePattern = /^[a-f0-9]{64}\.json$/u;

export interface HtmlCachePolicy {
  readonly namespace: string;
  readonly staleAfterMs: number;
}

interface PluginHtmlCacheOptions {
  readonly maximumCacheBytes?: number;
  readonly maximumEntryBytes?: number;
  readonly now?: () => number;
}

interface CachedHtml {
  readonly body: string;
  readonly storedAtMs: number;
}

interface CacheRecord {
  readonly body: string;
  readonly schemaVersion: number;
  readonly storedAtMs: number;
}

/**
 * Bounded plugin-private HTML cache.
 *
 * The only writable root is the absolute `ctx.cacheDir` supplied by Runtime.
 * A relative or unavailable test context deliberately degrades to a cache miss.
 */
export class PluginHtmlCache {
  readonly #root: string | undefined;
  readonly #now: () => number;
  readonly #maximumCacheBytes: number;
  readonly #maximumEntryBytes: number;
  readonly #inflight = new Map<string, Promise<string>>();

  constructor(
    cacheDir: string,
    {
      maximumCacheBytes = defaultMaximumCacheBytes,
      maximumEntryBytes = defaultMaximumEntryBytes,
      now = Date.now,
    }: PluginHtmlCacheOptions = {},
  ) {
    this.#root = isAbsolute(cacheDir)
      ? resolve(cacheDir, cacheDirectoryName)
      : undefined;
    this.#now = now;
    this.#maximumCacheBytes = positiveCacheLimit(maximumCacheBytes);
    this.#maximumEntryBytes = positiveCacheLimit(maximumEntryBytes);
  }

  getOrFetch(
    url: URL,
    policy: HtmlCachePolicy,
    fetcher: () => Promise<string>,
  ): Promise<string> {
    if (this.#root === undefined) return fetcher();
    const key = cacheKey(policy.namespace, url);
    const existing = this.#inflight.get(key);
    if (existing !== undefined) return existing;
    const pending = this.#getOrFetch(key, policy, fetcher);
    this.#inflight.set(key, pending);
    void pending.then(
      () => this.#inflight.delete(key),
      () => this.#inflight.delete(key),
    );
    return pending;
  }

  async #getOrFetch(
    key: string,
    policy: HtmlCachePolicy,
    fetcher: () => Promise<string>,
  ): Promise<string> {
    const cached = await this.#read(key);
    if (cached !== undefined && this.#now() - cached.storedAtMs <= policy.staleAfterMs) {
      await this.#touch(key);
      return cached.body;
    }
    try {
      const body = await fetcher();
      await this.#write(key, body);
      return body;
    } catch (error) {
      // Stale data is an offline fallback. A cache failure must never mask the
      // source request's normal error when no usable prior entry exists.
      if (cached !== undefined) return cached.body;
      throw error;
    }
  }

  async #read(key: string): Promise<CachedHtml | undefined> {
    try {
      const path = this.#entryPath(key);
      const metadata = await stat(path);
      if (!metadata.isFile() || metadata.size > this.#maximumEntryBytes) return undefined;
      const value: unknown = JSON.parse(await readFile(path, 'utf8'));
      if (!isCacheRecord(value)) return undefined;
      if (Buffer.byteLength(value.body, 'utf8') > this.#maximumEntryBytes) return undefined;
      return Object.freeze({ body: value.body, storedAtMs: value.storedAtMs });
    } catch {
      return undefined;
    }
  }

  async #write(key: string, body: string): Promise<void> {
    if (Buffer.byteLength(body, 'utf8') > this.#maximumEntryBytes) return;
    const root = this.#root;
    if (root === undefined) return;
    const temporaryPath = resolve(root, `.${key}.${randomUUID()}.partial`);
    try {
      await mkdir(root, { recursive: true });
      const record: CacheRecord = Object.freeze({
        body,
        schemaVersion: cacheSchemaVersion,
        storedAtMs: this.#now(),
      });
      const encoded = JSON.stringify(record);
      if (Buffer.byteLength(encoded, 'utf8') > this.#maximumEntryBytes) return;
      await writeFile(temporaryPath, encoded, 'utf8');
      await rename(temporaryPath, this.#entryPath(key));
      await this.#enforceCapacity();
    } catch {
      // Cache I/O is best effort; page delivery always keeps the fresh result.
    } finally {
      await rm(temporaryPath, { force: true }).catch(() => undefined);
    }
  }

  async #touch(key: string): Promise<void> {
    try {
      const now = new Date(this.#now());
      await utimes(this.#entryPath(key), now, now);
    } catch {
      // LRU metadata is expendable.
    }
  }

  async #enforceCapacity(): Promise<void> {
    const root = this.#root;
    if (root === undefined) return;
    const entries = await readdir(root, { withFileTypes: true });
    const candidates = await Promise.all(
      entries
        .filter((entry) => entry.isFile() && cacheFilePattern.test(entry.name))
        .map(async (entry) => {
          const path = resolve(root, entry.name);
          const metadata = await stat(path);
          return { path, size: metadata.size, accessedAtMs: metadata.mtimeMs };
        }),
    );
    let totalBytes = candidates.reduce((total, entry) => total + entry.size, 0);
    for (const entry of candidates.sort((left, right) => left.accessedAtMs - right.accessedAtMs)) {
      if (totalBytes <= this.#maximumCacheBytes) return;
      await rm(entry.path, { force: true });
      totalBytes -= entry.size;
    }
  }

  #entryPath(key: string): string {
    const root = this.#root;
    if (root === undefined || !/^[a-f0-9]{64}$/u.test(key)) {
      throw new Error('Cache key is invalid.');
    }
    return resolve(root, `${key}.json`);
  }
}

function cacheKey(namespace: string, url: URL): string {
  return createHash('sha256')
    .update(`${namespace}\n${url.toString()}`, 'utf8')
    .digest('hex');
}

function isCacheRecord(value: unknown): value is CacheRecord {
  return typeof value === 'object' &&
    value !== null &&
    'body' in value && typeof value.body === 'string' &&
    'schemaVersion' in value && value.schemaVersion === cacheSchemaVersion &&
    'storedAtMs' in value &&
    typeof value.storedAtMs === 'number' &&
    Number.isSafeInteger(value.storedAtMs) &&
    value.storedAtMs >= 0;
}

function positiveCacheLimit(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error('Cache limit is invalid.');
  }
  return value;
}
