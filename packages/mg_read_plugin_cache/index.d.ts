export interface PluginCachePolicy {
  readonly namespace: string;
  readonly staleAfterMs: number;
  readonly serveStaleWhileRevalidate?: boolean;
  readonly allowStaleOnError?: boolean;
}
export type HtmlCachePolicy = PluginCachePolicy;
export interface CachedResult<T> { readonly value: T; readonly storedAtMs: number; }
export interface CachedHtmlResult { readonly body: string; readonly storedAtMs: number; }
export interface PluginCacheOptions { readonly maximumCacheBytes?: number; readonly maximumEntryBytes?: number; readonly now?: () => number; }
export type PluginHtmlCacheOptions = PluginCacheOptions;
export class PluginCache {
  constructor(cacheDir: string, options?: PluginCacheOptions);
  getOrFetchText(url: URL, policy: PluginCachePolicy, fetcher: () => Promise<string>): Promise<string>;
  getOrFetchTextResult(url: URL, policy: PluginCachePolicy, fetcher: () => Promise<string>): Promise<CachedResult<string>>;
  getOrFetchJson<T>(cacheKey: string, policy: PluginCachePolicy, fetcher: () => Promise<CachedResult<T>>, decode: (value: unknown) => T | undefined): Promise<T>;
  getOrFetchJsonResult<T>(cacheKey: string, policy: PluginCachePolicy, fetcher: () => Promise<CachedResult<T>>, decode: (value: unknown) => T | undefined): Promise<CachedResult<T>>;
}
export class PluginHtmlCache extends PluginCache {
  getOrFetch(url: URL, policy: HtmlCachePolicy, fetcher: () => Promise<string>): Promise<string>;
  getOrFetchResult(url: URL, policy: HtmlCachePolicy, fetcher: () => Promise<string>): Promise<CachedHtmlResult>;
}
