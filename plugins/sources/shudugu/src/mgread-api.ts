export interface MgReadPluginContext {
  readonly dataDir: string;
  readonly cacheDir: string;
  readonly http: { fetch(input: string | URL, init?: RequestInit): Promise<Response> };
  readonly log: { debug(event: string): void; info(event: string): void; warn(event: string): void; error(event: string): void };
  readonly app: { readonly runtimeVersion: string; readonly nodeVersion: string; readonly pluginApi: number };
  readonly plugin: { readonly id: string; readonly version: string };
}
export type ContentKind = 'novel' | 'manga';
export type ContentStatus = 'ongoing' | 'completed' | 'hiatus' | 'unknown';
export type AccessKind = 'free' | 'paid' | 'mixed' | 'unknown';
export type DiscoveryContentLayout = 'featured' | 'carousel' | 'ranking' | 'list';
export interface ContentAttribute { readonly key: string; readonly label: string; readonly value: string; }
export interface LatestChapter { readonly id: string | null; readonly title: string; readonly url: string | null; readonly updatedAt: string | null; }
export interface ContentSummary {
  readonly id: string; readonly title: string; readonly contentKind: ContentKind; readonly author: string | null;
  readonly url: string | null; readonly coverUrl: string | null; readonly description: string | null;
  readonly language: string | null; readonly status: ContentStatus; readonly access: AccessKind;
  readonly wordCount: number | null; readonly chapterCount: number | null; readonly publishedAt: string | null;
  readonly updatedAt: string | null; readonly latestChapter: LatestChapter | null;
  readonly categories: readonly string[]; readonly tags: readonly string[]; readonly attributes: readonly ContentAttribute[];
}
export interface SearchRequest { readonly query: string; readonly cursor: string | null; readonly pageSize: number; }
export interface SearchResult { readonly items: readonly ContentSummary[]; readonly nextCursor: string | null; readonly totalCount: number | null; }
export interface SearchSuggestionsRequest { readonly cursor: string | null; readonly pageSize: number; }
export interface SearchSuggestionsResult { readonly items: readonly { readonly query: string; readonly metric: string | null }[]; readonly nextCursor: string | null; }
export interface DiscoverRequest { readonly target: string | null; readonly cursor: string | null; readonly collectionId: string | null; readonly pageSize: number; }
export interface DiscoveryCategory { readonly id: string; readonly title: string; readonly target: string; readonly count: number | null; readonly url: string | null; }
export interface DiscoveryContentItem { readonly content: ContentSummary; readonly rank: number | null; readonly metric: { readonly label: string; readonly value: string } | null; readonly recommendation: string | null; }
export interface DiscoveryContinuation { readonly target: string; readonly cursor: string; }
export interface DiscoverySection { readonly type: 'section'; readonly id: string; readonly title: string; readonly subtitle: string | null; readonly children: readonly DiscoveryComponent[]; }
export interface DiscoveryContentCollection { readonly type: 'contentCollection'; readonly id: string; readonly layout: DiscoveryContentLayout; readonly items: readonly DiscoveryContentItem[]; readonly continuation: DiscoveryContinuation | null; }
export interface DiscoveryCategoryCollection { readonly type: 'categoryCollection'; readonly id: string; readonly layout: 'grid' | 'list'; readonly categories: readonly DiscoveryCategory[]; }
export interface DiscoveryText { readonly type: 'text'; readonly id: string; readonly text: string; }
export type DiscoveryComponent = DiscoverySection | DiscoveryContentCollection | DiscoveryCategoryCollection | DiscoveryText;
export type DiscoverResult = { readonly kind: 'document'; readonly document: { readonly components: readonly DiscoveryComponent[] } } | { readonly kind: 'append'; readonly collectionId: string; readonly items: readonly DiscoveryContentItem[]; readonly continuation: DiscoveryContinuation | null; };
export interface ContentReferenceRequest { readonly id: string; }
export interface ContentDetail extends ContentSummary { readonly aliases: readonly string[]; readonly catalogUrl: string | null; }
export interface ChaptersRequest { readonly id: string; }
export interface ChapterSummary { readonly id: string; readonly title: string; readonly order: number; readonly url: string | null; readonly volumeTitle: string | null; readonly wordCount: number | null; readonly updatedAt: string | null; readonly isLocked: boolean | null; readonly attributes: readonly ContentAttribute[]; }
export interface ChaptersResult { readonly items: readonly ChapterSummary[]; }
export interface ContentRequest { readonly id: string; readonly chapterId: string; }
export interface ChapterContent { readonly chapterId: string; readonly contentKind: ContentKind; readonly title: string | null; readonly updatedAt: string | null; readonly text: string | null; readonly pages: readonly { readonly id: string; readonly index: number; readonly url: string; readonly mimeType: string | null; readonly width: number | null; readonly height: number | null }[]; }
