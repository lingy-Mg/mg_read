/**
 * Plugin content wire protocol types and immutable validation limits.
 * This module contains no request parsing or result-tree traversal.
 */

import type { JsonObject } from "./protocol.js";

export const MAX_ID_CHARACTERS = 8_192;
export const MAX_LABEL_CHARACTERS = 256;
export const MAX_TEXT_METADATA_CHARACTERS = 32_768;
export const MAX_URL_CHARACTERS = 8_192;
export const MAX_CURSOR_CHARACTERS = 2_048;
export const MAX_PAGE_SIZE = 50;
export const MAX_SEARCH_ITEMS = 50;
export const MAX_SEARCH_SUGGESTIONS = 50;
export const MAX_DISCOVERY_TABS = 16;
export const MAX_DISCOVERY_COMPONENTS = 128;
export const MAX_DISCOVERY_DEPTH = 8;
export const MAX_DISCOVERY_ITEMS = 50;
export const MAX_CATEGORIES = 32;
export const MAX_TAGS = 64;
export const MAX_ATTRIBUTES = 32;
export const MAX_CHAPTER_ITEMS = 5_000;
export const MAX_MANGA_PAGES = 500;
export const MAX_INLINE_RESULT_BYTES = 56 * 1_024;
export const MAX_INLINE_CHAPTER_CATALOG_BYTES = 2 * 1_024 * 1_024;
export const MAX_INLINE_TEXT_BYTES = 48 * 1_024;
export const MAX_INLINE_MANGA_MANIFEST_BYTES = 512 * 1_024;
export const MAX_MEDIA_GROUPS = 128;
export const MAX_MEDIA_HEADERS = 16;

/** Content kinds shared by package metadata, Plugin API, wire and Flutter. */
export type PluginContentKind = "audio" | "manga" | "novel" | "video";
export type PluginMangaPageResourcePolicy = "sessionOnly" | "refreshable" | "durable";
/** Media is always addressed through a Runtime proxy. A refreshable URL must
 * be re-resolved with getContent; no source may cache or replay credentials. */
export type PluginMediaResourcePolicy = "sessionOnly" | "refreshable";
export type PluginMediaResourceType = "audio" | "hls" | "video";

/** Stable publication state. Unknown is explicit and never encoded as null. */
export type PluginContentStatus =
  | "completed"
  | "hiatus"
  | "ongoing"
  | "unknown";

/** Stable access projection. Unknown is explicit and never encoded as null. */
export type PluginAccessKind = "free" | "mixed" | "paid" | "unknown";

/** Host-supported discovery content presentation hint. */
export type PluginDiscoveryContentLayout =
  | "carousel"
  | "compact"
  | "coverGrid"
  | "featured"
  | "list"
  | "ranking"
  | "shelf";
export type PluginDiscoveryCategoryLayout = "chips" | "grid" | "list";
export type PluginDiscoveryGroupLayout = "vertical" | "horizontal" | "grid";

/** Host-rendered semantic icon shared by discovery components and entries. */
export type PluginDiscoveryIcon =
  | "allTimeRanking"
  | "audio"
  | "book"
  | "books"
  | "category"
  | "classic"
  | "completed"
  | "dailyRanking"
  | "explore"
  | "fanFiction"
  | "fantasy"
  | "free"
  | "game"
  | "globe"
  | "history"
  | "horror"
  | "hot"
  | "lightNovel"
  | "manga"
  | "military"
  | "monthlyRanking"
  | "mystery"
  | "newRelease"
  | "ongoing"
  | "other"
  | "ranking"
  | "recommendation"
  | "romance"
  | "rural"
  | "school"
  | "scienceFiction"
  | "sports"
  | "star"
  | "system"
  | "timeTravel"
  | "trending"
  | "urban"
  | "weeklyRanking"
  | "wuxia";

/** Operation names used by the one Runtime plugin-invocation diagnostic span. */
export type PluginContentOperation =
  | "discover"
  | "getChapters"
  | "getContent"
  | "getDetail"
  | "search"
  | "searchSuggestions";

export interface PluginContentAttribute extends JsonObject {
  readonly key: string;
  readonly label: string;
  readonly value: string;
}

export interface PluginLatestChapter extends JsonObject {
  readonly id: string | null;
  readonly title: string;
  readonly updatedAt: string | null;
  readonly url: string | null;
}

/** Fixed rich summary shared by search, discovery and detail. */
export interface PluginContentSummary extends JsonObject {
  readonly access: PluginAccessKind;
  readonly attributes: readonly PluginContentAttribute[];
  readonly author: string | null;
  readonly categories: readonly string[];
  readonly chapterCount: number | null;
  readonly contentKind: PluginContentKind;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly id: string;
  readonly language: string | null;
  readonly latestChapter: PluginLatestChapter | null;
  readonly publishedAt: string | null;
  readonly status: PluginContentStatus;
  readonly tags: readonly string[];
  readonly title: string;
  readonly updatedAt: string | null;
  readonly url: string | null;
  readonly wordCount: number | null;
}

export interface PluginSearchRequest extends JsonObject {
  readonly cursor: string | null;
  readonly pageSize: number;
  readonly query: string;
}

export interface PluginSearchResult extends JsonObject {
  readonly items: readonly PluginContentSummary[];
  readonly nextCursor: string | null;
  readonly pluginId: string;
  readonly sourceName: string;
  readonly totalCount: number | null;
}

/** A source-owned popular search term. Its query is safe only for immediate
 * user-initiated search and must never enter default diagnostics. */
export interface PluginSearchSuggestion extends JsonObject {
  readonly query: string;
  readonly metric: string | null;
}

export interface PluginSearchSuggestionsRequest extends JsonObject {
  readonly cursor: string | null;
  readonly pageSize: number;
}

export interface PluginSearchSuggestionsResult extends JsonObject {
  readonly items: readonly PluginSearchSuggestion[];
  readonly nextCursor: string | null;
  readonly pluginId: string;
  readonly sourceName: string;
}

export interface PluginDiscoverRequest extends JsonObject {
  readonly collectionId: string | null;
  readonly cursor: string | null;
  readonly pageSize: number;
  readonly target: string | null;
}

export interface PluginDiscoveryTab extends JsonObject {
  readonly icon?: PluginDiscoveryIcon | null;
  readonly id: string;
  readonly label: string;
  readonly target: string;
}

export interface PluginDiscoveryMetric extends JsonObject {
  readonly label: string;
  readonly value: string;
}

export interface PluginDiscoveryContentItem extends JsonObject {
  readonly content: PluginContentSummary;
  readonly metric: PluginDiscoveryMetric | null;
  readonly rank: number | null;
  readonly recommendation: string | null;
}

export interface PluginDiscoveryCategory extends JsonObject {
  readonly count: number | null;
  readonly icon?: PluginDiscoveryIcon | null;
  readonly id: string;
  readonly target: string;
  readonly title: string;
  readonly url: string | null;
}

export interface PluginDiscoveryContinuation extends JsonObject {
  readonly cursor: string;
  readonly target: string;
}

export interface PluginDiscoveryTabsComponent extends JsonObject {
  readonly id: string;
  readonly selectedTabId: string | null;
  readonly tabs: readonly PluginDiscoveryTab[];
  readonly type: "tabs";
}

export interface PluginDiscoverySectionComponent extends JsonObject {
  readonly children: readonly PluginDiscoveryComponent[];
  readonly icon?: PluginDiscoveryIcon | null;
  readonly id: string;
  readonly subtitle: string | null;
  readonly title: string;
  readonly type: "section";
}

export interface PluginDiscoveryGroupComponent extends JsonObject {
  readonly children: readonly PluginDiscoveryComponent[];
  readonly id: string;
  readonly layout: PluginDiscoveryGroupLayout;
  readonly type: "group";
}

export interface PluginDiscoveryContentCollectionComponent extends JsonObject {
  readonly continuation: PluginDiscoveryContinuation | null;
  readonly id: string;
  readonly items: readonly PluginDiscoveryContentItem[];
  readonly layout: PluginDiscoveryContentLayout;
  readonly type: "contentCollection";
}

export interface PluginDiscoveryCategoryCollectionComponent extends JsonObject {
  readonly categories: readonly PluginDiscoveryCategory[];
  readonly id: string;
  readonly layout: PluginDiscoveryCategoryLayout;
  readonly type: "categoryCollection";
}

export interface PluginDiscoveryTextComponent extends JsonObject {
  readonly id: string;
  readonly text: string;
  readonly type: "text";
}

export interface PluginDiscoveryDividerComponent extends JsonObject {
  readonly id: string;
  readonly type: "divider";
}

export type PluginDiscoveryComponent =
  | PluginDiscoveryTabsComponent
  | PluginDiscoverySectionComponent
  | PluginDiscoveryGroupComponent
  | PluginDiscoveryContentCollectionComponent
  | PluginDiscoveryCategoryCollectionComponent
  | PluginDiscoveryTextComponent
  | PluginDiscoveryDividerComponent;

export interface PluginDiscoveryDocument extends JsonObject {
  readonly components: readonly PluginDiscoveryComponent[];
}

export interface PluginDiscoveryDocumentResult extends JsonObject {
  readonly document: PluginDiscoveryDocument;
  readonly kind: "document";
  readonly pluginId: string;
  readonly sourceName: string;
}

export interface PluginDiscoveryAppendResult extends JsonObject {
  readonly collectionId: string;
  readonly continuation: PluginDiscoveryContinuation | null;
  readonly items: readonly PluginDiscoveryContentItem[];
  readonly kind: "append";
  readonly pluginId: string;
  readonly sourceName: string;
}

export type PluginDiscoverResult =
  | PluginDiscoveryDocumentResult
  | PluginDiscoveryAppendResult;

export interface PluginContentReferenceRequest extends JsonObject {
  readonly id: string;
}

export interface PluginContentDetail extends PluginContentSummary {
  readonly aliases: readonly string[];
  readonly catalogUrl: string | null;
}

export interface PluginChaptersRequest extends JsonObject {
  readonly id: string;
}

export interface PluginChapterSummary extends JsonObject {
  readonly attributes: readonly PluginContentAttribute[];
  readonly id: string;
  readonly isLocked: boolean | null;
  readonly order: number;
  readonly title: string;
  readonly updatedAt: string | null;
  readonly url: string | null;
  readonly volumeTitle: string | null;
  readonly wordCount: number | null;
}

export interface PluginChaptersResult extends JsonObject {
  /** Empty for novel/manga and audio sources without an explicit grouping.
   * Video groups intentionally carry no season/line semantics. */
  readonly groups?: readonly PluginMediaGroup[];
  readonly items: readonly PluginChapterSummary[];
  readonly pluginId: string;
  readonly sourceName: string;
}

/** A neutral ordered collection of media episodes. It can mean a season,
 * source line, edition, or any other source-defined grouping. */
export interface PluginMediaGroup extends JsonObject {
  readonly episodes: readonly PluginChapterSummary[];
  readonly id: string;
  readonly order: number;
  readonly title: string;
}

export interface PluginContentRequest extends JsonObject {
  readonly chapterId: string;
  readonly id: string;
}

export interface PluginMangaPage extends JsonObject {
  readonly expiresAt: string | null;
  readonly height: number | null;
  readonly id: string;
  readonly index: number;
  readonly mimeType: string | null;
  readonly url: string;
  readonly resourcePolicy: PluginMangaPageResourcePolicy;
  readonly width: number | null;
}

export interface PluginChapterContent extends JsonObject {
  readonly chapterId: string;
  readonly contentKind: PluginContentKind;
  /** Present only for audio/video content. `url` must be a Runtime proxy URL,
   * never an upstream signed media URL. */
  readonly media?: PluginMediaResource | null;
  readonly pages: readonly PluginMangaPage[];
  readonly pluginId: string;
  readonly sourceName: string;
  readonly text: string | null;
  readonly title: string | null;
  readonly updatedAt: string | null;
}

/** Playable media metadata retained by the Flutter host and passed to exactly
 * one independent player package. Headers remain data-plane-only at the proxy. */
export interface PluginMediaResource extends JsonObject {
  readonly expiresAt: string | null;
  readonly headers: Readonly<Record<string, string>>;
  readonly mimeType: string | null;
  readonly resourcePolicy: PluginMediaResourcePolicy;
  readonly resourceType: PluginMediaResourceType;
  readonly url: string;
}

export interface ParsedPluginRequest<T extends JsonObject> {
  readonly pluginId: string;
  readonly request: T;
}

/** Stable validation failure mapped to plugin_invalid_response/invalid_request. */
export class PluginContentValidationError extends Error {
  constructor() {
    super("The Plugin API content object is invalid.");
    this.name = "PluginContentValidationError";
  }
}
