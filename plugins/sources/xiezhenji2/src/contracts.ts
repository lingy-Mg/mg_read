/** Content types remain source-local; the host context comes from the shared public API. */
export type { MgReadPluginContext } from '@mgread/source-api';
export interface ContentAttribute { readonly key: string; readonly label: string; readonly value: string; }
export interface ContentSummary { readonly id: string; readonly title: string; readonly contentKind: 'novel' | 'manga'; readonly author: string | null; readonly url: string | null; readonly coverUrl: string | null; readonly description: string | null; readonly language: string | null; readonly status: 'ongoing' | 'completed' | 'hiatus' | 'unknown'; readonly access: 'free' | 'paid' | 'mixed' | 'unknown'; readonly wordCount: number | null; readonly chapterCount: number | null; readonly publishedAt: string | null; readonly updatedAt: string | null; readonly latestChapter: { readonly id: string | null; readonly title: string; readonly url: string | null; readonly updatedAt: string | null } | null; readonly categories: readonly string[]; readonly tags: readonly string[]; readonly attributes: readonly ContentAttribute[]; }
export interface ContentDetail extends ContentSummary { readonly aliases: readonly string[]; readonly catalogUrl: string | null; }
export interface SearchRequest { readonly query: string; readonly cursor: string | null; readonly pageSize: number; }
export interface DiscoverRequest { readonly target: string | null; readonly cursor: string | null; readonly collectionId: string | null; readonly pageSize: number; }
export interface ContentReferenceRequest { readonly id: string; }
export interface ChaptersRequest { readonly id: string; }
export interface ContentRequest { readonly id: string; readonly chapterId: string; }
export interface SearchSuggestionsRequest { readonly cursor: string | null; readonly pageSize: number; }
