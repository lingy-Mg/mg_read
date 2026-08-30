/** File-local MgRead Plugin API v1 projection used by this manga source. */
export interface MgReadPluginContext {
  readonly dataDir: string; readonly cacheDir: string;
  readonly http: { fetch(input: string | URL, init?: RequestInit): Promise<Response> };
  readonly resource: { proxy(request: Record<string, unknown>): string };
  readonly log: { debug(event: string): void; info(event: string): void; warn(event: string): void; error(event: string): void };
  readonly app: { readonly runtimeVersion: string; readonly nodeVersion: string; readonly pluginApi: number };
  readonly plugin: { readonly id: string; readonly version: string };
}
export type Status = 'ongoing' | 'completed' | 'hiatus' | 'unknown';
export interface Summary {
  readonly id: string; readonly title: string; readonly contentKind: 'manga'; readonly author: string | null;
  readonly url: string | null; readonly coverUrl: string | null; readonly description: string | null;
  readonly language: string | null; readonly status: Status; readonly access: 'free'; readonly wordCount: null;
  readonly chapterCount: number | null; readonly publishedAt: string | null; readonly updatedAt: string | null;
  readonly latestChapter: { readonly id: string | null; readonly title: string; readonly url: string | null; readonly updatedAt: string | null } | null;
  readonly categories: readonly string[]; readonly tags: readonly string[];
  readonly attributes: readonly { readonly key: string; readonly label: string; readonly value: string }[];
}
export interface Detail extends Summary { readonly aliases: readonly string[]; readonly catalogUrl: string | null }
export interface DiscoveryItem { readonly content: Summary; readonly rank: number | null; readonly metric: null; readonly recommendation: string | null }
export interface Continuation { readonly target: string; readonly cursor: string }
export interface DiscoverRequest { readonly target: string | null; readonly cursor: string | null; readonly collectionId: string | null; readonly pageSize: number }
export type DiscoverResult =
  | { readonly kind: 'document'; readonly document: { readonly components: readonly unknown[] } }
  | { readonly kind: 'append'; readonly collectionId: string; readonly items: readonly DiscoveryItem[]; readonly continuation: Continuation | null };
export interface SearchRequest { readonly query: string; readonly cursor: string | null; readonly pageSize: number }
export interface SearchResult { readonly items: readonly Summary[]; readonly nextCursor: string | null; readonly totalCount: number | null }
export interface Chapter {
  readonly id: string; readonly title: string; readonly order: number; readonly url: string | null;
  readonly volumeTitle: string | null; readonly wordCount: null; readonly updatedAt: string | null;
  readonly isLocked: boolean | null; readonly attributes: readonly [];
}
export interface MangaPage {
  readonly id: string; readonly index: number; readonly url: string; readonly mimeType: string | null;
  readonly width: null; readonly height: null;
}
export interface ChapterContent {
  readonly chapterId: string; readonly contentKind: 'manga'; readonly title: string | null; readonly updatedAt: null;
  readonly text: null; readonly pages: readonly MangaPage[];
}
