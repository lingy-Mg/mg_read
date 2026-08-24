import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';

export interface HtmlCachePolicy { readonly namespace: string; readonly staleAfterMs: number; }
interface RecordValue { readonly body: string; readonly storedAtMs: number; readonly schemaVersion: 1; }

export class PluginHtmlCache {
  readonly #root: string | undefined;
  readonly #pending = new Map<string, Promise<string>>();
  constructor(cacheDir: string) { this.#root = isAbsolute(cacheDir) ? resolve(cacheDir, 'html-cache-v1') : undefined; }
  getOrFetch(url: URL, policy: HtmlCachePolicy, fetcher: () => Promise<string>): Promise<string> {
    if (this.#root === undefined) return fetcher();
    const key = createHash('sha256').update(`${policy.namespace}\n${url}`).digest('hex');
    const running = this.#pending.get(key);
    if (running !== undefined) return running;
    const task = this.#read(key, policy, fetcher);
    this.#pending.set(key, task);
    void task.then(
      () => this.#pending.delete(key),
      () => this.#pending.delete(key),
    );
    return task;
  }
  async #read(key: string, policy: HtmlCachePolicy, fetcher: () => Promise<string>): Promise<string> {
    const path = resolve(this.#root!, `${key}.json`);
    let cached: RecordValue | undefined;
    try {
      const value = JSON.parse(await readFile(path, 'utf8')) as Partial<RecordValue>;
      if (value.schemaVersion === 1 && typeof value.body === 'string' && typeof value.storedAtMs === 'number') cached = value as RecordValue;
    } catch { /* cache miss */ }
    if (cached !== undefined && Date.now() - cached.storedAtMs <= policy.staleAfterMs) return cached.body;
    try {
      const body = await fetcher();
      if (Buffer.byteLength(body, 'utf8') <= 1024 * 1024) {
        await mkdir(this.#root!, { recursive: true });
        const temporary = resolve(this.#root!, `.${key}.${randomUUID()}.partial`);
        try {
          await writeFile(temporary, JSON.stringify({ body, storedAtMs: Date.now(), schemaVersion: 1 }), 'utf8');
          await rename(temporary, path);
        } finally { await rm(temporary, { force: true }).catch(() => undefined); }
      }
      return body;
    } catch (error) {
      if (cached !== undefined) return cached.body;
      throw error;
    }
  }
}
