export interface HtmlCachePolicy {
  readonly namespace: string;
  readonly staleAfterMs: number;
  readonly serveStaleWhileRevalidate?: boolean;
  readonly allowStaleOnError?: boolean;
}

export interface CachedHtmlResult {
  readonly body: string;
  readonly storedAtMs: number;
}

export interface PluginHtmlCacheOptions {
  readonly maximumCacheBytes?: number;
  readonly maximumEntryBytes?: number;
  readonly now?: () => number;
}

export class PluginHtmlCache {
  constructor(cacheDir: string, options?: PluginHtmlCacheOptions);
  getOrFetch(url: URL, policy: HtmlCachePolicy, fetcher: () => Promise<string>): Promise<string>;
  getOrFetchResult(url: URL, policy: HtmlCachePolicy, fetcher: () => Promise<string>): Promise<CachedHtmlResult>;
}
