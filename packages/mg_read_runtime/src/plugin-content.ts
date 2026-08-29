/**
 * Stable public entry for the Plugin API content wire contract.
 * Types, request parsing, flat result validation and recursive discovery
 * validation live in focused modules and remain re-exported from here.
 */

export { PluginContentValidationError } from "./plugin-content-types.js";
export type {
  ParsedPluginRequest,
  PluginAccessKind,
  PluginChapterContent,
  PluginChaptersRequest,
  PluginChaptersResult,
  PluginChapterSummary,
  PluginContentAttribute,
  PluginContentDetail,
  PluginContentKind,
  PluginContentOperation,
  PluginContentReferenceRequest,
  PluginContentRequest,
  PluginContentStatus,
  PluginContentSummary,
  PluginDiscoverRequest,
  PluginDiscoverResult,
  PluginDiscoveryAppendResult,
  PluginDiscoveryCategory,
  PluginDiscoveryCategoryCollectionComponent,
  PluginDiscoveryCategoryLayout,
  PluginDiscoveryComponent,
  PluginDiscoveryContentCollectionComponent,
  PluginDiscoveryContentItem,
  PluginDiscoveryContentLayout,
  PluginDiscoveryContinuation,
  PluginDiscoveryDividerComponent,
  PluginDiscoveryDocument,
  PluginDiscoveryDocumentResult,
  PluginDiscoveryGroupComponent,
  PluginDiscoveryGroupLayout,
  PluginDiscoveryIcon,
  PluginDiscoveryMetric,
  PluginDiscoverySectionComponent,
  PluginDiscoveryTab,
  PluginDiscoveryTabsComponent,
  PluginDiscoveryTextComponent,
  PluginLatestChapter,
  PluginMangaPage,
  PluginMediaGroup,
  PluginMediaResource,
  PluginMediaResourcePolicy,
  PluginMediaResourceType,
  PluginSearchRequest,
  PluginSearchResult,
  PluginSearchSuggestion,
  PluginSearchSuggestionsRequest,
  PluginSearchSuggestionsResult,
} from "./plugin-content-types.js";
export {
  parseChaptersParams,
  parseContentParams,
  parseDetailParams,
  parseDiscoverParams,
  parseSearchParams,
  parseSearchSuggestionsParams,
} from "./plugin-content-request.js";
export {
  pluginContentResultCount,
  validateChaptersResult,
  validateContentResult,
  validateDetailResult,
  validateSearchResult,
  validateSearchSuggestionsResult,
} from "./plugin-content-validation.js";
export { validateDiscoverResult } from "./plugin-content-discovery.js";
