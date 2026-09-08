/**
 * Runtime 插件管理器。
 *
 * 职责：
 * - 在唯一 Node VM 中管理待升级插件冷激活、稳定插件懒加载、开发刷新与内容调用。
 * - 维护受限插件上下文、资源代理、共享调用/独占清缓存协调和传输队列。
 *
 * 注意：
 * - 不暴露路径、端口、PID 或 raw transport 给 Flutter。
 * - 已确认的 current 版本在首次调用时单飞加载；pending 仍在冷启动激活并完成提交或回滚。
 * - 开发项目冷启动只建立元数据快照，首次调用或传输时才创建私有 generation。
 * - 取消和超时必须只有一个终态。
 * - 客户端终态可以早于插件真实结束；未结束工作继续占用每插件有界容量。
 *
 * TODO:
 * - 将剩余 VM 编排方法继续下沉到显式内部端口。
 */
import { createHash } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { createRequire } from "node:module";
import {
  access,
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { dirname, resolve } from "node:path";

import type { JsonObject } from "./protocol.js";
import { activatePlugin, defaultPluginActivationTimeoutMs } from "./plugin-activation.js";
import type { PluginBrowserSessionProvider } from "./plugin-browser-session.js";
import { DevelopmentPluginRegistry } from "./development-plugin-registry.js";
import { loadDevelopmentPlugin } from "./development-plugin-runtime.js";
import { createPluginContext } from "./plugin-manager-context.js";
import {
  PluginOperationCoordinator,
  type PluginOperationCoordinatorOptions,
} from "./plugin-operation-coordinator.js";
import {
  positiveMilliseconds,
  settlePluginOperation,
  waitForPluginOperation,
} from "./plugin-operation-wait.js";
import { SourceResourceCoordinator } from "./source-resource-coordinator.js";
import { encodeSourceResourceToken } from "./source-resource-token.js";
import {
  type PluginPackageDescriptor,
  readPluginProject,
  resolveInside,
} from "./plugin-package.js";
import { PluginInstaller } from "./plugin-installer.js";
import { PluginIconResources } from "./plugin-icon-resources.js";
import { measureInstallationTree, retainedArtifactPath } from "./plugin-installation-usage.js";
import { createDevelopmentPackageArtifactResource, listExportablePluginArtifacts, listPluginTransferOffers, prepareActiveDevelopmentArtifact, toDevelopmentTransferProject } from "./plugin-manager-artifact-transfer.js";
import { PluginArtifactTransferManager, type PluginTransferArtifact, type PluginTransferOffer, type PluginTransferPlanItem, type PluginTransferResource } from "./plugin-artifact-transfer.js";
import {
  type PluginChapterContent,
  type PluginChaptersRequest,
  type PluginChaptersResult,
  type PluginContentDetail,
  type PluginContentOperation,
  type PluginContentReferenceRequest,
  type PluginContentRequest,
  type PluginDiscoverRequest,
  type PluginDiscoverResult,
  type PluginSearchRequest,
  type PluginSearchResult,
  type PluginSearchSuggestionsRequest,
  type PluginSearchSuggestionsResult,
  validateChaptersResult,
  validateContentResult,
  validateDetailResult,
  validateDiscoverResult,
  validateSearchResult,
  validateSearchSuggestionsResult,
} from "./plugin-content.js";
import { invokeLoadedPluginContent } from "./plugin-content-invocation.js";

import {
  PluginManagerError,
  type PluginCacheClearItem,
  type PluginCacheClearResult,
  type PluginCacheUsage,
  type PluginCodeDirectory,
  type PluginInstallationUsage,
  type PluginIconResource,
  type PluginUninstallAllResult,
  type PluginUninstallResult,
  type PluginStartupRecoverySummary,
  type DevelopmentPlugin,
  type InstalledPluginSnapshot,
  type LoadedPlugin,
  type MgReadPluginContext,
  type PluginInvocationScope,
  type PluginManagerEvent,
  type PluginManagerEventSink,
  type PluginRuntimeHttpClient,
  type PluginRuntimeTraceContext,
} from "./plugin-manager-contract.js";

import {
  atomicWrite,
  exists,
  isMissingPath,
  isPluginId,
  normalizePluginModule,
  removePluginStorage,
  readVersionPointer,
  snapshotFrom,
  withEnabledPluginSnapshot,
} from "./plugin-manager-files.js";

const DEFAULT_CACHE_CLEAR_TIMEOUT_MS = 5_000;

export {
  PluginManagerError,
  isPluginManagerError,
  type InstalledPluginSnapshot,
  type PluginCacheClearItem,
  type PluginCacheClearResult,
  type PluginCacheUsage,
  type PluginCodeDirectory,
  type PluginInstallationUsage,
  type PluginManagerEvent,
  type PluginManagerEventCode,
  type PluginManagerEventSink,
  type PluginUninstallAllResult,
  type PluginUninstallResult,
  type PluginRuntimeHttpClient,
  type PluginRuntimeTraceContext,
  type PluginStartupRecoverySummary,
} from "./plugin-manager-contract.js";

/** Metadata-first registry with one shared VM/module cache. */
export class PluginManager {
  readonly #dataRoot: string;
  readonly #embedded: boolean;
  readonly #development: DevelopmentPluginRegistry;
  readonly #events: PluginManagerEventSink;
  readonly #debugLogEnabled: () => boolean;
  readonly #http: PluginRuntimeHttpClient;
  readonly #sourceResources: SourceResourceCoordinator;
  readonly #browserSession: PluginBrowserSessionProvider | undefined;
  readonly #pluginIcons: PluginIconResources;
  #resourceOrigin = "http://127.0.0.1";
  readonly #invocationScope = new AsyncLocalStorage<PluginInvocationScope>();
  readonly #installedLoaded = new Map<string, LoadedPlugin>();
  readonly #installedLoadPromises = new Map<string, Promise<LoadedPlugin>>();
  readonly #pluginOperations: PluginOperationCoordinator;
  readonly #pluginTransfer: PluginArtifactTransferManager;
  readonly #cacheClearTimeoutMs: number;
  readonly #pluginActivationTimeoutMs: number;
  #initializePromise: Promise<void> | undefined;
  #startupQuarantinedCount = 0;
  #installedSnapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly developmentPluginRoot?: string;
      readonly developmentNpmCli?: string;
      readonly embedded?: boolean;
      readonly events?: PluginManagerEventSink;
      readonly http?: PluginRuntimeHttpClient;
      readonly browserSession?: PluginBrowserSessionProvider;
      readonly debugLogEnabled?: () => boolean;
      readonly cacheClearTimeoutMs?: number;
      readonly maxActiveInvocationsPerPlugin?: number;
      readonly maxQueuedOperationsPerPlugin?: number;
      readonly pluginActivationTimeoutMs?: number;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#embedded = options.embedded ?? false;
    this.#events = options.events ?? (() => {});
    this.#debugLogEnabled = options.debugLogEnabled ?? (() => false);
    this.#http = options.http ?? { fetch: (input, init) => fetch(input, init) };
    this.#sourceResources = new SourceResourceCoordinator(this.#http, this.#events, this.#debugLogEnabled);
    this.#browserSession = options.browserSession;
    this.#cacheClearTimeoutMs = positiveMilliseconds(
      options.cacheClearTimeoutMs,
      DEFAULT_CACHE_CLEAR_TIMEOUT_MS,
    );
    this.#pluginActivationTimeoutMs = positiveMilliseconds(
      options.pluginActivationTimeoutMs,
      defaultPluginActivationTimeoutMs,
    );
    this.#pluginOperations = new PluginOperationCoordinator({
      ...(options.maxActiveInvocationsPerPlugin === undefined
        ? {}
        : { maxActiveInvocations: options.maxActiveInvocationsPerPlugin }),
      ...(options.maxQueuedOperationsPerPlugin === undefined
        ? {}
        : { maxQueuedOperations: options.maxQueuedOperationsPerPlugin }),
    } satisfies PluginOperationCoordinatorOptions);
    this.#pluginTransfer = new PluginArtifactTransferManager(this.#dataRoot);
    this.#pluginIcons = new PluginIconResources(this.#dataRoot);
    this.#development = new DevelopmentPluginRegistry({
      dataRoot: this.#dataRoot,
      events: this.#events,
      load: (projectRoot, descriptor) => this.#loadDevelopmentProject(projectRoot, descriptor),
      ...(options.developmentPluginRoot === undefined
        ? {}
        : { root: options.developmentPluginRoot }),
      ...(options.developmentNpmCli === undefined
        ? {}
        : { npmCli: options.developmentNpmCli }),
    });
  }

  /** Builds metadata snapshots and validates pending versions exactly once before readiness. */
  initialize(): Promise<void> {
    return (this.#initializePromise ??= this.#initialize());
  }

  /** Returns and clears the safe recovery summary for this Runtime process. */
  async consumeStartupRecovery(): Promise<PluginStartupRecoverySummary> {
    await this.initialize();
    const quarantinedCount = this.#startupQuarantinedCount;
    this.#startupQuarantinedCount = 0;
    return Object.freeze({ quarantinedCount });
  }

  setResourceOrigin(origin: string): void { this.#resourceOrigin = origin; }

  createResourceUrl(pluginId: string, request: JsonObject): string {
    if (!isPluginId(pluginId) || Buffer.byteLength(JSON.stringify(request), "utf8") > 16 * 1024) throw new PluginManagerError("invalid_request");
    const token = encodeSourceResourceToken(pluginId, request);
    this.#sourceResources.created(pluginId, request, (next) => this.createResourceUrl(pluginId, next));
    return `${this.#resourceOrigin}/v1/source-resource/${token}`;
  }

  openSourceResource(token: string, requestHeaders: Readonly<Record<string, string>>, signal: AbortSignal) {
    return this.#sourceResources.open(token, requestHeaders, signal, (pluginId, request) => this.createResourceUrl(pluginId, request));
  }


  /** Returns the immutable cold-start installation projection. */
  async listInstalled(): Promise<readonly InstalledPluginSnapshot[]> {
    await this.initialize();
    return Object.freeze(await Promise.all(this.#combinedSnapshots().map((snapshot) =>
      this.#pluginIcons.project(snapshot, this.#development.projects(), this.#resourceOrigin))));
  }

  /** Lists retained artifacts plus explicit development exports, loading those projects on demand. */
  async listExportableArtifacts(): Promise<readonly PluginTransferArtifact[]> {
    await this.initialize();
    await this.#development.ensureAllLoaded();
    return listExportablePluginArtifacts(this.#pluginTransfer, this.#installedSnapshots, this.#development.loadedValues());
  }

  /** Lists transferable versions after lazily fingerprinting development projects. */
  async listPluginTransferOffers(): Promise<readonly PluginTransferOffer[]> {
    await this.initialize();
    await this.#development.ensureAllLoaded();
    return listPluginTransferOffers(
      this.#pluginTransfer,
      this.#installedSnapshots,
      this.#development.loadedValues(),
    );
  }

  async close(): Promise<void> {
    await this.#development.close();
    await this.#pluginTransfer.dispose();
  }

  /** Compares sender SemVer against this Runtime's installed versions. */
  async planPluginTransfer(incoming: readonly PluginTransferArtifact[], forceUpgradeIds: ReadonlySet<string> = new Set()): Promise<readonly PluginTransferPlanItem[]> {
    await this.initialize();
    await this.#development.ensureAllLoaded();
    const development = [...this.#development.loadedValues()].map((plugin) => ({ fingerprint: plugin.fingerprint, id: plugin.loaded.descriptor.id, syncRevision: plugin.syncRevision }));
    return this.#pluginTransfer.plan(incoming, this.#combinedSnapshots(), development, forceUpgradeIds);
  }

  async planPluginTransferOffers(incoming: readonly PluginTransferOffer[], forceUpgradeIds: ReadonlySet<string> = new Set()): Promise<readonly PluginTransferPlanItem[]> {
    await this.initialize();
    await this.#development.ensureAllLoaded();
    const development = [...this.#development.loadedValues()].map((plugin) => ({ fingerprint: plugin.fingerprint, id: plugin.loaded.descriptor.id, syncRevision: plugin.syncRevision }));
    return this.#pluginTransfer.planOffers(incoming, this.#combinedSnapshots(), development, forceUpgradeIds);
  }

  /** Creates a one-shot Runtime-private resource for bounded artifact streaming. */
  async createPluginTransferResource(id: string, version: string): Promise<{ readonly token: string; readonly artifact: PluginTransferArtifact }> {
    await this.initialize();
    const development = await this.#development.ensureLoaded(id);
    return this.#pluginTransfer.createResource(
      id,
      version,
      development === undefined ? undefined : toDevelopmentTransferProject(development),
    );
  }

  /** Lazily loads and packages one Windows Debug development source without exposing its path. */
  async createDevelopmentPackageResource(pluginId: string): Promise<{ readonly artifact: PluginTransferArtifact; readonly fileName: string; readonly token: string }> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const development = await this.#development.ensureLoaded(pluginId);
    if (development === undefined) throw new PluginManagerError("plugin_not_found");
    return createDevelopmentPackageArtifactResource(this.#pluginTransfer, development);
  }

  async verifyPluginTransferInbox(incoming: readonly PluginTransferArtifact[]): Promise<void> {
    return this.#pluginTransfer.verifyInbox(incoming);
  }

  consumePluginTransferResource(token: string): PluginTransferResource | undefined {
    return this.#pluginTransfer.consumeResource(token);
  }

  async consumePluginIconResource(token: string): Promise<PluginIconResource | undefined> {
    return this.#pluginIcons.consume(token);
  }

  /**
   * Resolves the current source directory only for a Runtime-owned desktop
   * action. This absolute path must never cross the Flutter Facade.
   */
  async resolveCodeDirectory(pluginId: string): Promise<PluginCodeDirectory> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const development = this.#development.project(pluginId);
    if (development !== undefined) {
      return Object.freeze({
        directory: development.projectRoot,
        kind: "development",
      } satisfies PluginCodeDirectory);
    }
    const snapshot = this.#installedSnapshots.find((item) => item.id === pluginId);
    if (snapshot === undefined) throw new PluginManagerError("plugin_not_found");
    const version = snapshot.activeVersion ?? snapshot.pendingVersion;
    if (version === null) {
      throw new PluginManagerError("plugin_load_failed");
    }
    const directory = resolve(
      this.#dataRoot,
      "plugins",
      pluginId,
      "versions",
      version,
    );
    if (!await exists(directory)) throw new PluginManagerError("plugin_load_failed");
    return Object.freeze({ directory, kind: "installed" } satisfies PluginCodeDirectory);
  }

  /** Reports byte usage for installed plugins without exposing cache paths. */
  async listCacheUsage(pluginId?: string): Promise<readonly PluginCacheUsage[]> {
    await this.initialize();
    const selected = this.#combinedSnapshots().filter((snapshot) => pluginId === undefined || snapshot.id === pluginId);
    return Object.freeze(await Promise.all(selected.map(async (snapshot) =>
      Object.freeze({
        bytes: await this.#cacheBytes(snapshot.id),
        pluginId: snapshot.id,
      } satisfies PluginCacheUsage)
    )));
  }

  /**
   * Measures one installed source subtree asynchronously.
   *
   * Data excludes every `node_modules` directory; npm includes the complete
   * materialized dependency tree; archive reports the retained original
   * `.mgplugin.js` or `.mgplugin`. Only totals cross the Facade.
   */
  async measureInstallationUsage(
    pluginId: string,
    scope: "archive" | "data" | "npm",
  ): Promise<PluginInstallationUsage> {
    await this.initialize();
    if (
      !isPluginId(pluginId) ||
      (scope !== "archive" && scope !== "data" && scope !== "npm")
    ) {
      throw new PluginManagerError("invalid_request");
    }
    const snapshot = this.#installedSnapshots.find((item) => item.id === pluginId);
    if (snapshot === undefined) throw new PluginManagerError("plugin_not_found");
    const version = snapshot.activeVersion ?? snapshot.pendingVersion;
    if (version === null) throw new PluginManagerError("plugin_load_failed");
    const versionRoot = resolve(
      this.#dataRoot,
      "plugins",
      pluginId,
      "versions",
      version,
    );
    const root = scope === "archive"
      ? await retainedArtifactPath(this.#dataRoot, pluginId, version)
      : scope === "npm"
        ? resolve(versionRoot, "node_modules")
        : versionRoot;
    const result = await measureInstallationTree(root, scope);
    return Object.freeze({
      bytes: result.bytes,
      fileCount: result.fileCount,
      pluginId,
      scope,
      version,
    } satisfies PluginInstallationUsage);
  }

  /** Clears one installed plugin's private cache and returns a stable outcome. */
  async clearPluginCache(
    pluginId: string,
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginCacheClearResult> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    if (!this.#combinedSnapshots().some((item) => item.id === pluginId)) {
      throw new PluginManagerError("plugin_not_found");
    }
    const cancellation = signal ?? new AbortController().signal;
    const deadline = deadlineUnixMs ?? String(Date.now() + this.#cacheClearTimeoutMs);
    return Object.freeze({
      items: Object.freeze([await this.#clearCache(pluginId, cancellation, deadline)]),
    } satisfies PluginCacheClearResult);
  }

  /** Clears every currently installed plugin cache, preserving per-plugin status. */
  async clearAllPluginCaches(
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginCacheClearResult> {
    await this.initialize();
    const pluginIds = this.#combinedSnapshots().map((item) => item.id);
    const cancellation = signal ?? new AbortController().signal;
    const deadline = deadlineUnixMs ?? String(Date.now() + this.#cacheClearTimeoutMs);
    return Object.freeze({
      items: Object.freeze(await Promise.all(pluginIds.map((pluginId) =>
        this.#clearCache(pluginId, cancellation, deadline)
      ))),
    } satisfies PluginCacheClearResult);
  }

  /**
   * Persists one source's enabled state and immediately gates dispatch in this
   * Runtime process without unloading or recreating the shared Node VM.
   */
  async setEnabled(pluginId: string, enabled: boolean): Promise<InstalledPluginSnapshot> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    if (this.#development.has(pluginId)) {
      throw new PluginManagerError("invalid_request");
    }
    const index = this.#installedSnapshots.findIndex((item) => item.id === pluginId);
    if (index < 0) throw new PluginManagerError("plugin_not_found");

    await new PluginInstaller(this.#dataRoot).setEnabled(pluginId, enabled);
    const { snapshots, updated } = withEnabledPluginSnapshot(this.#installedSnapshots, index, enabled);
    this.#installedSnapshots = snapshots;
    this.#events({
      code: enabled ? "plugin_enabled" : "plugin_disabled",
      outcome: "success",
      pluginId,
    });
    return this.#pluginIcons.project(updated, this.#development.projects(), this.#resourceOrigin);
  }

  /** Removes one installed source after current source calls have released their lease. */
  async uninstall(
    pluginId: string,
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginUninstallResult> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    if (this.#development.has(pluginId)) {
      throw new PluginManagerError("invalid_request");
    }
    if (!this.#installedSnapshots.some((item) => item.id === pluginId)) {
      throw new PluginManagerError("plugin_not_found");
    }
    await this.#uninstallInstalled(pluginId, signal, deadlineUnixMs);
    return Object.freeze({ pluginId, removed: true } satisfies PluginUninstallResult);
  }

  /** Removes every installed source, preserving workspace development projects. */
  async uninstallAll(
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginUninstallAllResult> {
    await this.initialize();
    const pluginIds = this.#installedSnapshots.map((item) => item.id);
    for (const pluginId of pluginIds) {
      await this.#uninstallInstalled(pluginId, signal, deadlineUnixMs);
    }
    return Object.freeze({ removedCount: pluginIds.length } satisfies PluginUninstallAllResult);
  }

  async #uninstallInstalled(
    pluginId: string,
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<void> {
    const cancellation = signal ?? new AbortController().signal;
    const deadline = deadlineUnixMs ?? String(Date.now() + this.#cacheClearTimeoutMs);
    const release = await this.#pluginOperations.acquireCacheClear(pluginId, cancellation, deadline);
    try {
      await removePluginStorage(this.#dataRoot, pluginId);
      await new PluginInstaller(this.#dataRoot).collectUnusedDependencies();
      this.#installedLoaded.delete(pluginId);
      this.#installedLoadPromises.delete(pluginId);
      this.#installedSnapshots = Object.freeze(
        this.#installedSnapshots.filter((item) => item.id !== pluginId),
      );
      this.#events({
        code: "plugin_uninstall_completed",
        outcome: "success",
        pluginId,
      });
    } finally {
      release();
    }
  }

  async discover(
    pluginId: string,
    request: PluginDiscoverRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginDiscoverResult> {
    return this.#invokeContent(
      pluginId,
      "discover",
      request,
      signal,
      deadlineUnixMs,
      validateDiscoverResult,
      trace,
      (result) => request.collectionId === null
        ? result.kind === "document"
        : result.kind === "append" && result.collectionId === request.collectionId,
    );
  }

  async search(
    pluginId: string,
    request: PluginSearchRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginSearchResult> {
    return this.#invokeContent(
      pluginId,
      "search",
      request,
      signal,
      deadlineUnixMs,
      validateSearchResult,
      trace,
    );
  }

  async searchSuggestions(
    pluginId: string,
    request: PluginSearchSuggestionsRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginSearchSuggestionsResult> {
    return this.#invokeContent(
      pluginId,
      "searchSuggestions",
      request,
      signal,
      deadlineUnixMs,
      validateSearchSuggestionsResult,
      trace,
    );
  }

  async getDetail(
    pluginId: string,
    request: PluginContentReferenceRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<
    PluginContentDetail & {
      readonly pluginId: string;
      readonly sourceName: string;
    }
  > {
    return this.#invokeContent(
      pluginId,
      "getDetail",
      request,
      signal,
      deadlineUnixMs,
      validateDetailResult,
      trace,
      (result) => result.id === request.id,
    );
  }

  async getChapters(
    pluginId: string,
    request: PluginChaptersRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginChaptersResult> {
    return this.#invokeContent(
      pluginId,
      "getChapters",
      request,
      signal,
      deadlineUnixMs,
      validateChaptersResult,
      trace,
    );
  }

  async getContent(
    pluginId: string,
    request: PluginContentRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginChapterContent> {
    return this.#invokeContent(
      pluginId,
      "getContent",
      request,
      signal,
      deadlineUnixMs,
      validateContentResult,
      trace,
      (result) => result.chapterId === request.chapterId,
    );
  }

  async #invokeContent<TResult extends JsonObject>(
    pluginId: string,
    operation: PluginContentOperation,
    request: JsonObject,
    signal: AbortSignal,
    deadlineUnixMs: string,
    validate: (pluginId: string, sourceName: string, value: unknown) => TResult,
    trace?: PluginRuntimeTraceContext,
    validateCorrelation?: (result: TResult) => boolean,
  ): Promise<TResult> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const queuedAt = performance.now();
    const releaseOperation = await this.#pluginOperations.acquireInvocation(
      pluginId,
      signal,
      deadlineUnixMs,
    );
    let development: DevelopmentPlugin | undefined;
    let operationStarted = false;
    try {
      if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "debug", logMessage: `插件调用取得队列：操作=${operation}，等待毫秒=${Math.round(performance.now() - queuedAt)}`, outcome: "success", pluginId });
      const execution = (async () => {
        try {
          development = await this.#development.ensureLoaded(pluginId);
          if (development !== undefined) this.#development.retain(development);
          const installed = development === undefined
            ? await this.#ensureInstalledLoaded(pluginId)
            : undefined;
          return await invokeLoadedPluginContent({
            debugLogEnabled: this.#debugLogEnabled,
            ...(development === undefined
              ? {}
              : { developmentIsCurrent: () => this.#development.getLoaded(pluginId) === development }),
            deadlineUnixMs,
            events: this.#events,
            invocationScope: this.#invocationScope,
            operation,
            plugin: development?.loaded ?? installed,
            pluginId,
            request,
            signal,
            snapshot: this.#combinedSnapshots().find((item) => item.id === pluginId),
            ...(trace === undefined ? {} : { trace }),
            validate,
            ...(validateCorrelation === undefined ? {} : { validateCorrelation }),
          });
        } finally {
          try {
            if (development !== undefined) await this.#development.release(development);
          } finally {
            releaseOperation();
          }
        }
      })();
      operationStarted = true;
      return await waitForPluginOperation(
        settlePluginOperation(execution),
        signal,
        deadlineUnixMs,
      );
    } finally {
      if (!operationStarted) {
        try {
          if (development !== undefined) await this.#development.release(development);
        } finally {
          releaseOperation();
        }
      }
    }
  }

  async #initialize(): Promise<void> {
    const pluginsRoot = resolve(this.#dataRoot, "plugins");
    await mkdir(pluginsRoot, { recursive: true });
    await rm(resolve(this.#dataRoot, "development-generations"), {
      force: true,
      recursive: true,
    });
    await this.#development.initialize();
    const snapshots: InstalledPluginSnapshot[] = [];
    const entries = await readdir(pluginsRoot, { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      if (!entry.isDirectory() || !isPluginId(entry.name)) continue;
      const pluginRoot = resolve(pluginsRoot, entry.name);
      if (await exists(resolve(pluginRoot, "uninstall-pending"))) {
        await removePluginStorage(this.#dataRoot, entry.name);
        this.#events({
          code: "plugin_uninstall_completed",
          outcome: "success",
          pluginId: entry.name,
        });
        continue;
      }
      // The imported version remains a cold-start fallback, but must not share activation or private state with its development source.
      if (this.#development.has(entry.name)) continue;
      snapshots.push(await this.#initializePlugin(entry.name, pluginRoot));
    }
    this.#installedSnapshots = Object.freeze(snapshots);
  }

  async #loadDevelopmentProject(
    projectRoot: string,
    descriptor: PluginPackageDescriptor,
  ): Promise<DevelopmentPlugin> {
    return prepareActiveDevelopmentArtifact(this.#pluginTransfer, await loadDevelopmentPlugin({
      createContext: (candidate) => this.#createContext(candidate),
      dataRoot: this.#dataRoot,
      descriptor,
      events: this.#events,
      loadModule: (entryPath) => this.#loadModule(entryPath),
      activationTimeoutMs: this.#pluginActivationTimeoutMs,
      projectRoot,
    }));
  }

  #combinedSnapshots(): readonly InstalledPluginSnapshot[] {
    const combined = new Map<string, InstalledPluginSnapshot>();
    for (const snapshot of this.#installedSnapshots) combined.set(snapshot.id, snapshot);
    for (const snapshot of this.#development.snapshots) combined.set(snapshot.id, snapshot);
    return Object.freeze(
      [...combined.values()].sort((left, right) => left.id.localeCompare(right.id)),
    );
  }

  /** Clears cache only after current source/resource calls have released shared leases. */
  async #clearCache(
    pluginId: string,
    signal: AbortSignal,
    deadlineUnixMs: string,
  ): Promise<PluginCacheClearItem> {
    let release: (() => void) | undefined;
    let bytesBefore = 0;
    try {
      release = await this.#pluginOperations.acquireCacheClear(
        pluginId,
        signal,
        deadlineUnixMs,
      );
      bytesBefore = await this.#cacheBytes(pluginId);
      const cacheDir = this.#cacheDirectory(pluginId);
      let entries: string[];
      try {
        entries = await readdir(cacheDir);
      } catch (error) {
        if (!isMissingPath(error)) throw error;
        entries = [];
      }
      await Promise.all(
        entries.map((entry) =>
          rm(resolve(cacheDir, entry), { force: true, recursive: true }),
        ),
      );
      return Object.freeze({
        bytesBefore,
        bytesRemaining: await this.#cacheBytes(pluginId),
        pluginId,
        status: "cleared",
      } satisfies PluginCacheClearItem);
    } catch {
      let bytesRemaining = bytesBefore;
      try {
        bytesRemaining = await this.#cacheBytes(pluginId);
      } catch {
        // The terminal status remains useful even if the failed directory cannot be read.
      }
      return Object.freeze({
        bytesBefore,
        bytesRemaining,
        pluginId,
        status: "failed",
      } satisfies PluginCacheClearItem);
    } finally {
      release?.();
    }
  }

  async #cacheBytes(pluginId: string): Promise<number> {
    const root = this.#cacheDirectory(pluginId);
    try {
      return await this.#cacheBytesAt(root);
    } catch (error) {
      if (isMissingPath(error)) return 0;
      throw error;
    }
  }

  async #cacheBytesAt(path: string): Promise<number> {
    const metadata = await lstat(path);
    if (!metadata.isDirectory()) return metadata.size;
    const entries = await readdir(path, { withFileTypes: true });
    let total = 0;
    for (const entry of entries) {
      total += await this.#cacheBytesAt(resolve(path, entry.name));
      if (!Number.isSafeInteger(total)) throw new PluginManagerError("plugin_load_failed");
    }
    return total;
  }

  #cacheDirectory(pluginId: string): string {
    return resolve(this.#dataRoot, "plugin-cache", pluginId);
  }

  async #initializePlugin(
    pluginId: string,
    pluginRoot: string,
  ): Promise<InstalledPluginSnapshot> {
    const disabled = await exists(resolve(pluginRoot, "disabled"));
    const current = await readVersionPointer(resolve(pluginRoot, "current"));
    const pending = await readVersionPointer(resolve(pluginRoot, "pending"));
    const quarantined = await readVersionPointer(resolve(pluginRoot, "quarantined"));
    let descriptor = await this.#readDescriptor(pluginRoot, pending ?? current);
    if (disabled) {
      return snapshotFrom(descriptor, pluginId, current, pending, false, "disabled");
    }

    if (pending !== null) {
      try {
        const loaded = await this.#loadVersion(pluginId, pluginRoot, pending);
        if (current !== null && current !== pending) {
          await atomicWrite(resolve(pluginRoot, "previous"), `${current}\n`);
        }
        await atomicWrite(resolve(pluginRoot, "current"), `${pending}\n`);
        await rm(resolve(pluginRoot, "pending"), { force: true });
        await rm(resolve(pluginRoot, "quarantined"), { force: true });
        this.#installedLoaded.set(pluginId, loaded);
        descriptor = loaded.descriptor;
        return snapshotFrom(descriptor, pluginId, pending, null, true, "active");
      } catch {
        await atomicWrite(resolve(pluginRoot, "failed"), `${pending}\n`);
        await rm(resolve(pluginRoot, "pending"), { force: true });
        if (current === null) {
          await this.#quarantine(pluginId, pluginRoot, pending);
          return snapshotFrom(descriptor, pluginId, null, null, false, "quarantined");
        }
      }
    }

    if (current !== null) {
      if (quarantined === current) {
        return snapshotFrom(descriptor, pluginId, current, null, false, "quarantined");
      }
      if (pending !== null) descriptor = await this.#readDescriptor(pluginRoot, current);
      return snapshotFrom(descriptor, pluginId, current, null, true, "active");
    }
    if (quarantined !== null) {
      return snapshotFrom(descriptor, pluginId, null, null, false, "quarantined");
    }
    return snapshotFrom(descriptor, pluginId, null, pending, true, pending ? "pending" : "damaged");
  }

  async #quarantine(
    pluginId: string,
    pluginRoot: string,
    version: string,
    countAsStartupRecovery = true,
  ): Promise<void> {
    const marker = resolve(pluginRoot, "quarantined");
    const alreadyQuarantined = await readVersionPointer(marker);
    if (alreadyQuarantined === version) return;
    await atomicWrite(marker, `${version}\n`);
    if (countAsStartupRecovery) this.#startupQuarantinedCount += 1;
    this.#events({
      code: "plugin_quarantined",
      outcome: "error",
      pluginId,
    });
  }

  async #ensureInstalledLoaded(pluginId: string): Promise<LoadedPlugin | undefined> {
    const loaded = this.#installedLoaded.get(pluginId);
    if (loaded !== undefined) return loaded;
    const snapshot = this.#installedSnapshots.find((item) => item.id === pluginId);
    if (
      snapshot === undefined ||
      snapshot.enabled !== true ||
      snapshot.status !== "active" ||
      snapshot.activeVersion === null
    ) {
      return undefined;
    }
    const existing = this.#installedLoadPromises.get(pluginId);
    if (existing !== undefined) return existing;

    const version = snapshot.activeVersion;
    const loading = this.#loadInstalledCurrent(pluginId, version);
    this.#installedLoadPromises.set(pluginId, loading);
    void loading.then(
      () => this.#installedLoadPromises.delete(pluginId),
      () => this.#installedLoadPromises.delete(pluginId),
    );
    return loading;
  }

  async #loadInstalledCurrent(pluginId: string, version: string): Promise<LoadedPlugin> {
    const pluginRoot = resolve(this.#dataRoot, "plugins", pluginId);
    try {
      const loaded = await this.#loadVersion(pluginId, pluginRoot, version);
      const snapshot = this.#installedSnapshots.find((item) => item.id === pluginId);
      if (snapshot?.enabled === true && snapshot.activeVersion === version) {
        this.#installedLoaded.set(pluginId, loaded);
      }
      return loaded;
    } catch {
      await this.#quarantine(pluginId, pluginRoot, version, false);
      const index = this.#installedSnapshots.findIndex((item) => item.id === pluginId);
      const snapshot = this.#installedSnapshots[index];
      if (
        snapshot !== undefined &&
        snapshot.enabled === true &&
        snapshot.status === "active" &&
        snapshot.activeVersion === version
      ) {
        const quarantined = Object.freeze({
          ...snapshot,
          enabled: false,
          pendingVersion: null,
          status: "quarantined",
        } satisfies InstalledPluginSnapshot);
        this.#installedSnapshots = Object.freeze([
          ...this.#installedSnapshots.slice(0, index),
          quarantined,
          ...this.#installedSnapshots.slice(index + 1),
        ]);
      }
      throw new PluginManagerError("plugin_load_failed");
    }
  }

  async #loadVersion(
    pluginId: string,
    pluginRoot: string,
    version: string,
  ): Promise<LoadedPlugin> {
    const startedAt = performance.now();
    this.#events({ code: "plugin_load_started", outcome: "started", pluginId });
    try {
      const versionRoot = resolve(pluginRoot, "versions", version);
      const project = await readPluginProject(versionRoot);
      if (project.descriptor.id !== pluginId || project.descriptor.version !== version) {
        throw new PluginManagerError("plugin_load_failed");
      }
      // Node 24 synchronously loads standard ESM projects without top-level
      // await through require(). This preserves ordinary Node resolution while
      // avoiding the Javet dynamic-import callback path on Android.
      const entryPath = resolveInside(versionRoot, project.descriptor.entry);
      const imported = await this.#loadModule(entryPath);
      const candidate = normalizePluginModule(imported);
      if (candidate === undefined) {
        throw new PluginManagerError("plugin_load_failed");
      }
      const context = await this.#createContext(project.descriptor);
      await activatePlugin(candidate, context, this.#pluginActivationTimeoutMs);
      const loaded = Object.freeze({ descriptor: project.descriptor, module: candidate });
      this.#events({
        code: "plugin_load_completed",
        durationMs: performance.now() - startedAt,
        outcome: "success",
        pluginId,
      });
      return loaded;
    } catch {
      this.#events({
        code: "plugin_load_failed",
        durationMs: performance.now() - startedAt,
        outcome: "error",
        pluginId,
      });
      throw new PluginManagerError("plugin_load_failed");
    }
  }

  async #createContext(descriptor: PluginPackageDescriptor): Promise<MgReadPluginContext> {
    const context = await createPluginContext({
      browserSession: this.#browserSession,
      dataRoot: this.#dataRoot,
      descriptor,
      events: this.#events,
      debugLogEnabled: this.#debugLogEnabled,
      http: this.#http,
      invocationScope: () => this.#invocationScope.getStore(),
    });
    return Object.freeze({
      ...context,
      resource: Object.freeze({ proxy: (request: JsonObject) => this.createResourceUrl(descriptor.id, request) }),
    });
  }

  async #loadModule(entryPath: string): Promise<Record<string, unknown>> {
    if (this.#embedded) {
      // Javet owns the V8 module resolver on Android. Ask that resolver to
      // compile the plugin module so installed files and their dependencies
      // stay in the same VM/module cache as the Runtime Core.
      const loader = (globalThis as {
        __mgreadLoadPluginModule?: (path: string) => Record<string, unknown>;
      }).__mgreadLoadPluginModule;
      if (typeof loader === "function") {
        return loader(entryPath);
      }
      // Node-only embedded Core tests intentionally exercise the Android
      // dispatch path without Javet. They have no native resolver, so retain
      // ordinary Node loading there; real Android always installs the loader.
      return createRequire(entryPath)(entryPath) as Record<string, unknown>;
    }
    return createRequire(entryPath)(entryPath) as Record<string, unknown>;
  }

  async #readDescriptor(
    pluginRoot: string,
    version: string | null,
  ): Promise<PluginPackageDescriptor | undefined> {
    if (version === null) return undefined;
    try {
      return (await readPluginProject(resolve(pluginRoot, "versions", version))).descriptor;
    } catch {
      return undefined;
    }
  }

}
