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
export type {
  DesktopRuntimeOptions,
  DesktopRuntimeReady,
} from "./desktop-runtime.js";
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
  readPluginProject,
} from "./plugin-package.js";
export type {
  LockedPluginDependency,
  PluginPackageDescriptor,
  ValidatedPluginProject,
} from "./plugin-package.js";
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
export type { InstalledPluginSnapshot } from "./plugin-manager.js";
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
  PluginDiscoveryMetric,
  PluginDiscoverySectionComponent,
  PluginDiscoveryTab,
  PluginDiscoveryTabsComponent,
  PluginDiscoveryTextComponent,
  PluginLatestChapter,
  PluginMangaPage,
  PluginSearchRequest,
  PluginSearchResult,
} from "./plugin-content.js";
