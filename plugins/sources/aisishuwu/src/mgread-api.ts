/** Public Plugin API v1 projection used for compile-time checking only. */
export interface MgReadPluginContext {
  readonly dataDir: string;
  readonly cacheDir: string;
  readonly http: {
    fetch(input: string | URL, init?: RequestInit): Promise<Response>;
  };
  readonly log: {
    debug(event: string): void;
    info(event: string): void;
    warn(event: string): void;
    error(event: string): void;
  };
  readonly app: {
    readonly runtimeVersion: string;
    readonly nodeVersion: string;
    readonly pluginApi: number;
  };
  readonly plugin: { readonly id: string; readonly version: string };
}

export type ContentKind = 'novel' | 'manga';
export type ContentStatus = 'ongoing' | 'completed' | 'hiatus' | 'unknown';
export type AccessKind = 'free' | 'paid' | 'mixed' | 'unknown';
export type DiscoveryLayout = 'featured' | 'carousel' | 'ranking' | 'list' | 'categories';

export interface ContentAttribute {
  readonly key: string;
  readonly label: string;
  readonly value: string;
}

export interface LatestChapter {
  readonly id: string | null;
  readonly title: string;
  readonly url: string | null;
  readonly updatedAt: string | null;
}

export interface ContentSummary {
  readonly id: string;
  readonly title: string;
  readonly contentKind: ContentKind;
  readonly author: string | null;
  readonly url: string | null;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly language: string | null;
  readonly status: ContentStatus;
  readonly access: AccessKind;
  readonly wordCount: number | null;
  readonly chapterCount: number | null;
  readonly publishedAt: string | null;
  readonly updatedAt: string | null;
  readonly latestChapter: LatestChapter | null;
  readonly categories: readonly string[];
  readonly tags: readonly string[];
  readonly attributes: readonly ContentAttribute[];
}

export interface SearchRequest { readonly query: string; readonly cursor: string | null; readonly pageSize: number; }
export interface SearchResult { readonly items: readonly ContentSummary[]; readonly nextCursor: string | null; readonly totalCount: number | null; }
export interface DiscoverRequest { readonly target: string | null; readonly cursor: string | null; readonly pageSize: number; }
export interface DiscoveryCategory { readonly id: string; readonly title: string; readonly target: string; readonly count: number | null; readonly url: string | null; }
export interface DiscoveryContentItem { readonly content: ContentSummary; readonly rank: number | null; readonly metric: { readonly label: string; readonly value: string } | null; readonly recommendation: string | null; }
export interface DiscoverySection { readonly id: string; readonly title: string; readonly subtitle: string | null; readonly layout: DiscoveryLayout; readonly items: readonly DiscoveryContentItem[]; readonly categories: readonly DiscoveryCategory[]; }
export interface DiscoverResult { readonly tabs: readonly { readonly id: string; readonly label: string; readonly target: string }[]; readonly selectedTabId: string | null; readonly sections: readonly DiscoverySection[]; readonly nextCursor: string | null; }
export interface ContentReferenceRequest { readonly id: string; }
export interface ContentDetail extends ContentSummary { readonly aliases: readonly string[]; readonly catalogUrl: string | null; }
export interface ChaptersRequest { readonly id: string; readonly cursor: string | null; readonly pageSize: number; }
export interface ChapterSummary { readonly id: string; readonly title: string; readonly order: number; readonly url: string | null; readonly volumeTitle: string | null; readonly wordCount: number | null; readonly updatedAt: string | null; readonly isLocked: boolean | null; readonly attributes: readonly ContentAttribute[]; }
export interface ChaptersResult { readonly items: readonly ChapterSummary[]; readonly nextCursor: string | null; readonly totalCount: number | null; }
export interface ContentRequest { readonly id: string; readonly chapterId: string; }
export interface ChapterContent { readonly chapterId: string; readonly contentKind: ContentKind; readonly title: string | null; readonly updatedAt: string | null; readonly text: string | null; readonly pages: readonly { readonly id: string; readonly index: number; readonly url: string; readonly mimeType: string | null; readonly width: number | null; readonly height: number | null; }[]; }
