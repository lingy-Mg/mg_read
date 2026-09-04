/**
 * Source-local bounded cache for public listing, detail and catalog text.
 *
 * It stores only reproducible public responses under Runtime's injected cacheDir.
 * Chapter and user-specific state are handled outside this cache.
 */
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, rename, rm, stat, utimes, writeFile, } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';
const schemaVersion = 1;
const maximumCacheBytes = 100 * 1024 * 1024;
const maximumEntryBytes = 2 * 1024 * 1024;
const cacheFilePattern = /^[a-f0-9]{64}\.json$/u;
export class BoundedTextCache {
    #root;
    #inflight = new Map();
    #backgroundRefreshes = new Map();
    constructor(cacheDir) {
        this.#root = isAbsolute(cacheDir)
            ? resolve(cacheDir, 'source-text-cache-v1')
            : undefined;
    }
    getOrFetchText(url, policy, fetcher) {
        if (this.#root === undefined)
            return fetcher();
        const key = createHash('sha256')
            .update(`${policy.namespace}\n${url.toString()}`, 'utf8')
            .digest('hex');
        const existing = this.#inflight.get(key);
        if (existing !== undefined)
            return existing;
        const pending = this.#readOrFetch(key, policy, fetcher);
        this.#inflight.set(key, pending);
        void pending.then(() => this.#inflight.delete(key), () => this.#inflight.delete(key));
        return pending;
    }
    async #readOrFetch(key, policy, fetcher) {
        const cached = await this.#read(key);
        if (cached !== undefined &&
            Date.now() - cached.storedAtMs <= policy.staleAfterMs) {
            void this.#touch(key);
            return cached.body;
        }
        if (cached !== undefined &&
            policy.serveStaleWhileRevalidate === true) {
            void this.#refreshInBackground(key, fetcher);
            void this.#touch(key);
            return cached.body;
        }
        try {
            const body = await fetcher();
            await this.#write(key, body, Date.now());
            return body;
        }
        catch (error) {
            if (cached !== undefined && policy.allowStaleOnError !== false) {
                return cached.body;
            }
            throw error;
        }
    }
    #refreshInBackground(key, fetcher) {
        const existing = this.#backgroundRefreshes.get(key);
        if (existing !== undefined)
            return existing;
        const refresh = (async () => {
            try {
                await this.#write(key, await fetcher(), Date.now());
            }
            catch {
                // Stale public discovery data remains usable.
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
            if (!metadata.isFile() || metadata.size > maximumEntryBytes) {
                return undefined;
            }
            const value = JSON.parse(await readFile(path, 'utf8'));
            if (!isRecord(value) || value.schemaVersion !== schemaVersion) {
                return undefined;
            }
            if (typeof value.body !== 'string' ||
                !Number.isSafeInteger(value.storedAtMs) ||
                Number(value.storedAtMs) < 0) {
                return undefined;
            }
            return Object.freeze({
                body: value.body,
                storedAtMs: Number(value.storedAtMs),
            });
        }
        catch {
            return undefined;
        }
    }
    async #write(key, body, storedAtMs) {
        if (this.#root === undefined)
            return;
        const encoded = JSON.stringify({
            schemaVersion,
            storedAtMs,
            body,
        });
        if (Buffer.byteLength(encoded, 'utf8') > maximumEntryBytes)
            return;
        const temporary = resolve(this.#root, `.${key}.${randomUUID()}.partial`);
        try {
            await mkdir(this.#root, { recursive: true });
            await writeFile(temporary, encoded, 'utf8');
            await rm(this.#entryPath(key), { force: true });
            await rename(temporary, this.#entryPath(key));
            await this.#enforceCapacity();
        }
        catch {
            // Cache I/O is best effort.
        }
        finally {
            await rm(temporary, { force: true }).catch(() => undefined);
        }
    }
    async #touch(key) {
        try {
            const now = new Date();
            await utimes(this.#entryPath(key), now, now);
        }
        catch {
            // LRU metadata is expendable.
        }
    }
    async #enforceCapacity() {
        if (this.#root === undefined)
            return;
        try {
            const entries = await readdir(this.#root, { withFileTypes: true });
            const candidates = await Promise.all(entries
                .filter((entry) => entry.isFile() && cacheFilePattern.test(entry.name))
                .map(async (entry) => {
                const path = resolve(this.#root, entry.name);
                const metadata = await stat(path);
                return {
                    path,
                    size: metadata.size,
                    accessedAtMs: metadata.mtimeMs,
                };
            }));
            let total = candidates.reduce((sum, entry) => sum + entry.size, 0);
            for (const entry of candidates.sort((left, right) => left.accessedAtMs - right.accessedAtMs)) {
                if (total <= maximumCacheBytes)
                    break;
                await rm(entry.path, { force: true });
                total -= entry.size;
            }
        }
        catch {
            // Capacity enforcement is retried after the next successful write.
        }
    }
    #entryPath(key) {
        if (this.#root === undefined || !/^[a-f0-9]{64}$/u.test(key)) {
            throw new Error('Cache key is invalid.');
        }
        return resolve(this.#root, `${key}.json`);
    }
}
function isRecord(value) {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
}
