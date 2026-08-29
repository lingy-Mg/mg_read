/**
 * Public Node Runtime Core surface.
 *
 * Flutter applications do not import this module directly; the Runtime-owned
 * Flutter Facade owns process launch and all loopback transport details.
 */
export {
  expectedNodeVersion,
  protocolVersion,
  runtimeVersion,
  runtimeCompatibility,
} from "./runtime-version.js";
export { DesktopRuntime } from "./desktop-runtime.js";
export { RuntimeDebugHttpServer } from "./debug-http.js";
export type {
  DesktopRuntimeOptions,
  DesktopRuntimeReady,
} from "./desktop-runtime.js";
export type { RuntimeDebugHttpStatus } from "./debug-http.js";
export type { RuntimeCompatibilityMatrix } from "./runtime-version.js";
export {
  createPluginArchive,
  extractPluginArchive,
  PluginArchiveError,
} from "./plugin-archive.js";
export {
  dependencyObjectName,
  pluginApiVersion,
  pluginPackageSchemaVersion,
  PluginPackageError,
  parsePluginPackageDescriptor,
  readPluginProject,
} from "./plugin-package.js";
export type {
  LockedPluginDependency,
  PluginPackageDescriptor,
  PluginPackageMode,
  ValidatedPluginProject,
} from "./plugin-package.js";
export {
  createPluginSingleFile,
  materializePluginSingleFile,
  MAX_PLUGIN_ARTIFACT_BYTES,
  MAX_PLUGIN_ICON_BYTES,
  MAX_PLUGIN_SINGLE_FILE_HEADER_BYTES,
  parsePluginSingleFile,
  PLUGIN_SINGLE_FILE_PREFIX,
  PluginSingleFileError,
} from "./plugin-single-file.js";
export type {
  ParsedSingleFilePlugin,
  PluginArtifactFormat,
  PluginSingleFileCreateOptions,
  SingleFilePluginDescriptor,
  SingleFilePluginEnvelope,
  SingleFilePluginIcon,
} from "./plugin-single-file.js";
export {
  DependencyStore,
  DependencyStoreError,
} from "./dependency-store.js";
export type { DependencyMaterializationResult } from "./dependency-store.js";
export { PluginInstaller } from "./plugin-installer.js";
export type {
  PluginInstallerEvent,
  PluginInstallResult,
} from "./plugin-installer.js";
export { PluginManager, PluginManagerError } from "./plugin-manager.js";
export {
  maximumBrowserRequestBytes,
  maximumBrowserResponseBytes,
  maximumBrowserTimeoutMs,
  PluginBrowserSessionError,
  requestPluginBrowserInteraction,
  requestPluginBrowserSession,
} from "./plugin-browser-session.js";
export type {
  PluginBrowserHostRequest,
  PluginBrowserHostResponse,
  PluginBrowserSessionInteraction,
  PluginBrowserSessionInteractionRequest,
  PluginBrowserSessionInteractionResponse,
  PluginBrowserSessionProvider,
  PluginBrowserSessionRequest,
  PluginBrowserSessionResponse,
  PluginBrowserVerificationState,
  PluginWebViewHostRequest,
  PluginWebViewOperation,
} from "./plugin-browser-session.js";
export { maximumWebViewTimeoutMs } from "./plugin-webview-page.js";
export type {
  PluginJsonValue,
  PluginWebViewApi,
  PluginWebViewFetchRequest,
  PluginWebViewFetchResponse,
  PluginWebViewKey,
  PluginWebViewPage,
} from "./plugin-webview-page.js";
export type {
  InstalledPluginSnapshot,
  PluginInstallationUsage,
} from "./plugin-manager.js";
export { PluginContentValidationError } from "./plugin-content.js";
export type {
  ParsedPluginRequest,
  PluginAccessKind,
  PluginChapterContent,
  PluginChapterSummary,
  PluginChaptersRequest,
  PluginChaptersResult,
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
  PluginDiscoveryCategory,
  PluginDiscoveryCategoryCollectionComponent,
  PluginDiscoveryCategoryLayout,
  PluginDiscoveryComponent,
  PluginDiscoveryContentItem,
  PluginDiscoveryContentCollectionComponent,
  PluginDiscoveryContentLayout,
  PluginDiscoveryContinuation,
  PluginDiscoveryDividerComponent,
  PluginDiscoveryDocument,
  PluginDiscoveryDocumentResult,
  PluginDiscoveryAppendResult,
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
  PluginSearchRequest,
  PluginSearchResult,
  PluginSearchSuggestion,
  PluginSearchSuggestionsRequest,
  PluginSearchSuggestionsResult,
} from "./plugin-content.js";
