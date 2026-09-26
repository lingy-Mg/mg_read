/**
 * Runtime 插件管理器。
 *
 * 职责：
 * - 在唯一 Node VM 中管理待升级插件冷激活、稳定插件懒加载与开发刷新。
 * - 组合受限插件上下文、来源调用、存储控制、资源代理和传输队列。
 *
 * 注意：
 * - 不暴露路径、端口、PID 或 raw transport 给 Flutter。
 * - current 首次调用时单飞加载；pending 冷启动有界并发激活，各自提交或回滚。
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
import { mkdir, readdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

import type { JsonObject } from "./protocol.js";
import { activatePlugin, defaultPluginActivationTimeoutMs } from "./plugin-activation.js";
import type { PluginBrowserSessionProvider } from "./plugin-browser-session.js";
import { DevelopmentPluginRegistry } from "./development-plugin-registry.js";
import { loadDevelopmentPlugin } from "./development-plugin-runtime.js";
import { PluginContentDispatcher } from "./plugin-content-dispatcher.js";
import { createPluginContext } from "./plugin-manager-context.js";
import {
  PluginOperationCoordinator,
  type PluginOperationCoordinatorOptions,
} from "./plugin-operation-coordinator.js";
import { positiveMilliseconds } from "./plugin-operation-wait.js";
import { SourceResourceCoordinator } from "./source-resource-coordinator.js";
import { encodeSourceResourceToken } from "./source-resource-token.js";
import {
  type PluginPackageDescriptor,
  readPluginProject,
  resolveInside,
} from "./plugin-package.js";
import { PluginInstaller } from "./plugin-installer.js";
import {
  InstalledPluginCatalog,
  type InstalledPluginCatalogRecord,
} from "./plugin-catalog.js";
import { PluginIconResources } from "./plugin-icon-resources.js";
import { createDevelopmentPackageArtifactResource, listExportablePluginArtifacts, listPluginTransferOffers, prepareActiveDevelopmentArtifact, toDevelopmentTransferProject } from "./plugin-manager-artifact-transfer.js";
import { PluginManagerStorage } from "./plugin-manager-storage.js";
import { PluginArtifactTransferManager, type PluginTransferArtifact, type PluginTransferOffer, type PluginTransferPlanItem, type PluginTransferResource } from "./plugin-artifact-transfer.js";
import {
  type PluginChapterContent,
  type PluginChaptersRequest,
  type PluginChaptersResult,
  type PluginContentDetail,
  type PluginContentReferenceRequest,
  type PluginContentRequest,
  type PluginDiscoverRequest,
  type PluginDiscoverResult,
  type PluginSearchRequest,
  type PluginSearchResult,
  type PluginSearchSuggestionsRequest,
  type PluginSearchSuggestionsResult,
} from "./plugin-content.js";

import {
  PluginManagerError,
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
  exists,
  isPluginId,
  normalizePluginModule,
  readVersionPointer,
  snapshotFrom,
} from "./plugin-manager-files.js";

const DEFAULT_CACHE_CLEAR_TIMEOUT_MS = 5_000;
const DEFAULT_UNINSTALL_CONCURRENCY = 4;
const EMBEDDED_UNINSTALL_CONCURRENCY = 2;

export {
  PluginManagerError,
  pluginManagerErrorDetail,
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
  readonly #catalog: InstalledPluginCatalog;
  readonly #catalogSubscription: () => void;
  readonly #installer: PluginInstaller;
  #resourceOrigin = "http://127.0.0.1";
  readonly #invocationScope = new AsyncLocalStorage<PluginInvocationScope>();
  readonly #installedLoaded = new Map<string, LoadedPlugin>();
  readonly #installedLoadPromises = new Map<string, Promise<LoadedPlugin>>();
  readonly #pluginOperations: PluginOperationCoordinator;
  readonly #pluginTransfer: PluginArtifactTransferManager;
  readonly #content: PluginContentDispatcher;
  readonly #storage: PluginManagerStorage;
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
      readonly catalog?: InstalledPluginCatalog;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#embedded = options.embedded ?? false;
    this.#events = options.events ?? (() => {});
    this.#catalog = options.catalog ?? new InstalledPluginCatalog(this.#dataRoot);
    this.#catalogSubscription = this.#catalog.observe((change) => {
      this.#events({
        code: "plugin_catalog_changed",
        itemCount: change.itemCount,
        outcome: "success",
        ...(change.pluginId === undefined ? {} : { pluginId: change.pluginId }),
      });
    });
    this.#debugLogEnabled = options.debugLogEnabled ?? (() => false);
    this.#http = options.http ?? { fetch: (input, init) => fetch(input, init) };
    this.#sourceResources = new SourceResourceCoordinator(
      this.#http, this.#events, this.#debugLogEnabled,
      (pluginId, request, signal) => this.#resolveImageResource(pluginId, request, signal),
    );
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
    this.#installer = new PluginInstaller(this.#dataRoot, { catalog: this.#catalog });
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
    this.#content = new PluginContentDispatcher({
      debugLogEnabled: this.#debugLogEnabled,
      development: this.#development,
      ensureInstalledLoaded: (pluginId) => this.#ensureInstalledLoaded(pluginId),
      events: this.#events,
      initialize: () => this.initialize(),
      invocationScope: this.#invocationScope,
      operations: this.#pluginOperations,
      snapshots: () => this.#combinedSnapshots(),
    });
    this.#storage = new PluginManagerStorage({
      cacheClearTimeoutMs: this.#cacheClearTimeoutMs,
      dataRoot: this.#dataRoot,
      developmentProjectRoot: (pluginId) => this.#development.project(pluginId)?.projectRoot,
      initialize: () => this.initialize(),
      installedSnapshots: () => this.#installedSnapshots,
      operations: this.#pluginOperations,
      snapshots: () => this.#combinedSnapshots(),
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

  /** Invokes an optional source image handler under the same per-plugin lease and HTTP scope as content calls. */
  async #resolveImageResource(pluginId: string, request: JsonObject, signal: AbortSignal): Promise<Response | undefined> {
    await this.initialize();
    if (this.#combinedSnapshots().find((snapshot) => snapshot.id === pluginId)?.enabled !== true) return undefined;
    const deadlineUnixMs = String(Date.now() + 30_000);
    const scopedSignal = AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
    const release = await this.#pluginOperations.acquireInvocation(pluginId, scopedSignal, deadlineUnixMs);
    let development: DevelopmentPlugin | undefined;
    try {
      development = await this.#development.ensureLoaded(pluginId);
      if (development !== undefined) this.#development.retain(development);
      const installed = development === undefined ? await this.#ensureInstalledLoaded(pluginId) : undefined;
      const plugin = development?.loaded ?? installed;
      if (plugin?.module.getResource === undefined) return undefined;
      const value: unknown = await this.#invocationScope.run(
        Object.freeze({ deadlineUnixMs, signal: scopedSignal }),
        () => plugin.module.getResource!(request),
      );
      if (scopedSignal.aborted || this.#combinedSnapshots().find((snapshot) => snapshot.id === pluginId)?.enabled !== true ||
          (development !== undefined && this.#development.getLoaded(pluginId) !== development)) return undefined;
      if (value === null || typeof value !== "object") return undefined;
      const resource = value as { readonly bytes?: unknown; readonly mimeType?: unknown };
      if (!(resource.bytes instanceof Uint8Array) || resource.bytes.byteLength === 0 || resource.bytes.byteLength > 24 * 1024 * 1024 ||
          !["image/jpeg", "image/png", "image/webp", "image/gif"].includes(String(resource.mimeType))) return undefined;
      return new Response(Buffer.from(resource.bytes), {
        headers: { "content-type": String(resource.mimeType), "content-length": String(resource.bytes.byteLength), "cache-control": "no-store" },
      });
    } finally {
      try {
        if (development !== undefined) await this.#development.release(development);
      } finally {
        release();
      }
    }
  }


  /** Returns the immutable cold-start installation projection. */
  async listInstalled(): Promise<readonly InstalledPluginSnapshot[]> {
    await this.initialize();
    return Object.freeze(await Promise.all(this.#combinedSnapshots().map((snapshot) =>
      this.#pluginIcons.project(
        snapshot,
        this.#development.projects(),
        this.#resourceOrigin,
        this.#catalog.record(snapshot.id)?.descriptor,
      ))));
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
    this.#catalogSubscription();
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
    return this.#storage.resolveCodeDirectory(pluginId);
  }

  /** Reports byte usage for installed plugins without exposing cache paths. */
  async listCacheUsage(pluginId?: string): Promise<readonly PluginCacheUsage[]> {
    return this.#storage.listCacheUsage(pluginId);
  }

  /**
   * Measures one installed source subtree asynchronously.
   *
   * Data reports the installed source tree; archive reports the retained
   * original `.mgplugin.js` or `.mgplugin`. Only totals cross the Facade.
   */
  async measureInstallationUsage(
    pluginId: string,
    scope: "archive" | "data",
  ): Promise<PluginInstallationUsage> {
    return this.#storage.measureInstallationUsage(pluginId, scope);
  }

  /** Clears one installed plugin's private cache and returns a stable outcome. */
  async clearPluginCache(
    pluginId: string,
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginCacheClearResult> {
    return this.#storage.clearPluginCache(pluginId, signal, deadlineUnixMs);
  }

  /** Clears every currently installed plugin cache, preserving per-plugin status. */
  async clearAllPluginCaches(
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginCacheClearResult> {
    return this.#storage.clearAllPluginCaches(signal, deadlineUnixMs);
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

    const record = await this.#catalog.setEnabled(pluginId, enabled);
    if (record === undefined) throw new PluginManagerError("plugin_not_found");
    const updated = record.snapshot;
    this.#installedSnapshots = Object.freeze([
      ...this.#installedSnapshots.slice(0, index),
      updated,
      ...this.#installedSnapshots.slice(index + 1),
    ]);
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
    const snapshot = this.#installedSnapshots.find((item) => item.id === pluginId);
    if (snapshot === undefined) {
      throw new PluginManagerError("plugin_not_found");
    }
    this.#reportUninstallProgress("plugin_uninstall_started", snapshot, 0, 1);
    await this.#uninstallInstalled(pluginId, signal, deadlineUnixMs);
    this.#reportUninstallProgress("plugin_uninstall_completed", snapshot, 1, 1);
    return Object.freeze({ pluginId, removed: true } satisfies PluginUninstallResult);
  }

  /** Removes every installed source, preserving workspace development projects. */
  async uninstallAll(
    signal?: AbortSignal,
    deadlineUnixMs?: string,
  ): Promise<PluginUninstallAllResult> {
    await this.initialize();
    const snapshots = this.#installedSnapshots;
    let completedCount = 0;
    await mapWithConcurrency(
      snapshots,
      this.#embedded ? EMBEDDED_UNINSTALL_CONCURRENCY : DEFAULT_UNINSTALL_CONCURRENCY,
      async (snapshot) => {
        this.#reportUninstallProgress("plugin_uninstall_started", snapshot, completedCount, snapshots.length);
        await this.#uninstallInstalled(snapshot.id, signal, deadlineUnixMs);
        completedCount += 1;
        this.#reportUninstallProgress("plugin_uninstall_completed", snapshot, completedCount, snapshots.length);
      },
    );
    return Object.freeze({ removedCount: snapshots.length } satisfies PluginUninstallAllResult);
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
      await this.#catalog.remove(pluginId);
      this.#installedLoaded.delete(pluginId);
      this.#installedLoadPromises.delete(pluginId);
      this.#installedSnapshots = Object.freeze(
        this.#installedSnapshots.filter((item) => item.id !== pluginId),
      );
    } finally {
      release();
    }
  }

  #reportUninstallProgress(
    code: "plugin_uninstall_started" | "plugin_uninstall_completed",
    snapshot: InstalledPluginSnapshot,
    itemCount: number,
    totalItemCount: number,
  ): void {
    this.#events({
      code,
      itemCount,
      outcome: code === "plugin_uninstall_started" ? "started" : "success",
      pluginId: snapshot.id,
      pluginName: snapshot.displayName,
      totalItemCount,
    });
  }

  async discover(
    pluginId: string,
    request: PluginDiscoverRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginDiscoverResult> {
    return this.#content.discover(pluginId, request, signal, deadlineUnixMs, trace);
  }

  async search(
    pluginId: string,
    request: PluginSearchRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginSearchResult> {
    return this.#content.search(pluginId, request, signal, deadlineUnixMs, trace);
  }

  async searchSuggestions(
    pluginId: string,
    request: PluginSearchSuggestionsRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginSearchSuggestionsResult> {
    return this.#content.searchSuggestions(pluginId, request, signal, deadlineUnixMs, trace);
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
    return this.#content.getDetail(pluginId, request, signal, deadlineUnixMs, trace);
  }

  async getChapters(
    pluginId: string,
    request: PluginChaptersRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginChaptersResult> {
    return this.#content.getChapters(pluginId, request, signal, deadlineUnixMs, trace);
  }

  async getContent(
    pluginId: string,
    request: PluginContentRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginChapterContent> {
    return this.#content.getContent(pluginId, request, signal, deadlineUnixMs, trace);
  }

  async #initialize(): Promise<void> {
    const pluginsRoot = resolve(this.#dataRoot, "plugins");
    await mkdir(pluginsRoot, { recursive: true });
    await rm(resolve(this.#dataRoot, "development-generations"), {
      force: true,
      recursive: true,
    });
    const developmentStartedAt = performance.now();
    await this.#development.initialize();
    this.#startupPhase(
      "development_scan",
      this.#development.snapshots.length,
      performance.now() - developmentStartedAt,
    );

    const installedStartedAt = performance.now();
    let records = await this.#catalog.load();
    let catalogState: "hit" | "rebuilt" = "hit";
    if (records === undefined) {
      catalogState = "rebuilt";
      const entries = (await readdir(pluginsRoot, { withFileTypes: true }))
        .filter((entry) => entry.isDirectory() && isPluginId(entry.name))
        .sort((left, right) => left.name.localeCompare(right.name));
      const inspected = await mapWithConcurrency(
        entries,
        this.#embedded ? 4 : 8,
        (entry) => this.#inspectInstalledPlugin(
          entry.name,
          resolve(pluginsRoot, entry.name),
        ),
      );
      for (const record of inspected.filter((entry) => entry.uninstallPending)) {
        await this.#catalog.remove(record.snapshot.id);
        this.#events({
          code: "plugin_uninstall_completed",
          outcome: "success",
          pluginId: record.snapshot.id,
        });
      }
      records = inspected.filter((entry) => !entry.uninstallPending);
      await this.#catalog.recover(records);
    } else {
      for (const record of records.filter((entry) => entry.uninstallPending)) {
        await this.#catalog.remove(record.snapshot.id);
        this.#events({
          code: "plugin_uninstall_completed",
          outcome: "success",
          pluginId: record.snapshot.id,
        });
      }
      records = this.#catalog.records;
    }
    this.#syncInstalledSnapshots();
    this.#startupPhase(
      "installed_snapshot",
      this.#installedSnapshots.length,
      performance.now() - installedStartedAt,
      catalogState,
    );

    const pending = records.filter((record) =>
      !record.uninstallPending &&
      record.snapshot.enabled &&
      record.snapshot.pendingVersion !== null &&
      !this.#development.has(record.snapshot.id),
    );
    const pendingStartedAt = performance.now();
    await mapWithConcurrency(pending, this.#embedded ? 4 : 8, (record) => this.#activatePending(record));
    this.#syncInstalledSnapshots();
    this.#startupPhase(
      "pending_activation",
      pending.length,
      performance.now() - pendingStartedAt,
    );
  }

  #syncInstalledSnapshots(): void {
    this.#installedSnapshots = Object.freeze(
      this.#catalog.records
        .filter((record) => !this.#development.has(record.snapshot.id))
        .map((record) => record.snapshot),
    );
  }

  #startupPhase(
    startupPhase: "development_scan" | "installed_snapshot" | "pending_activation",
    itemCount: number,
    durationMs: number,
    catalogState?: "hit" | "rebuilt",
  ): void {
    this.#events({
      code: "plugin_startup_phase_completed",
      ...(catalogState === undefined ? {} : { catalogState }),
      durationMs,
      itemCount,
      outcome: "success",
      startupPhase,
    });
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

  async #inspectInstalledPlugin(
    pluginId: string,
    pluginRoot: string,
  ): Promise<InstalledPluginCatalogRecord> {
    const disabled = await exists(resolve(pluginRoot, "disabled"));
    const current = await readVersionPointer(resolve(pluginRoot, "current"));
    const pending = await readVersionPointer(resolve(pluginRoot, "pending"));
    const quarantined = await readVersionPointer(resolve(pluginRoot, "quarantined"));
    const uninstallPending = await exists(resolve(pluginRoot, "uninstall-pending"));
    const descriptor = await this.#readDescriptor(pluginRoot, pending ?? current);
    let snapshot: InstalledPluginSnapshot;
    if (disabled) {
      snapshot = snapshotFrom(descriptor, pluginId, current, pending, false, "disabled");
    } else if (current !== null && quarantined === current) {
      snapshot = snapshotFrom(descriptor, pluginId, current, pending, false, "quarantined");
    } else if (pending !== null) {
      snapshot = snapshotFrom(descriptor, pluginId, current, pending, true, "pending");
    } else if (current !== null) {
      snapshot = snapshotFrom(descriptor, pluginId, current, null, true, "active");
    } else if (quarantined !== null) {
      snapshot = snapshotFrom(descriptor, pluginId, null, null, false, "quarantined");
    } else {
      snapshot = snapshotFrom(descriptor, pluginId, null, null, true, "damaged");
    }
    return Object.freeze({ descriptor, snapshot, uninstallPending });
  }

  async #activatePending(record: InstalledPluginCatalogRecord): Promise<void> {
    const { snapshot } = record;
    const pending = snapshot.pendingVersion;
    if (pending === null) return;
    const pluginId = snapshot.id;
    const pluginRoot = resolve(this.#dataRoot, "plugins", pluginId);
    try {
      const loaded = await this.#loadVersion(pluginId, pluginRoot, pending);
      const activated = Object.freeze({
        descriptor: loaded.descriptor,
        snapshot: snapshotFrom(loaded.descriptor, pluginId, pending, null, true, "active"),
        uninstallPending: false,
      } satisfies InstalledPluginCatalogRecord);
      await this.#catalog.activate(activated);
      this.#installedLoaded.set(pluginId, loaded);
    } catch {
      const current = snapshot.activeVersion;
      // A forced same-version replacement has no older version tree to fall
      // back to. Never report that failed candidate as an active source.
      if (current === null || current === pending) {
        const quarantined = Object.freeze({
          descriptor: record.descriptor,
          snapshot: snapshotFrom(record.descriptor, pluginId, current, null, false, "quarantined"),
          uninstallPending: false,
        } satisfies InstalledPluginCatalogRecord);
        await this.#catalog.quarantinePending(quarantined, pending);
        this.#startupQuarantinedCount += 1;
        this.#events({ code: "plugin_quarantined", outcome: "error", pluginId });
        return;
      }
      const descriptor = await this.#readDescriptor(pluginRoot, current);
      const recovered = Object.freeze({
        descriptor,
        snapshot: snapshotFrom(descriptor, pluginId, current, null, true, "active"),
        uninstallPending: false,
      } satisfies InstalledPluginCatalogRecord);
      await this.#catalog.recoverPending(recovered, pending);
    }
  }

  async #quarantine(
    pluginId: string,
    pluginRoot: string,
    version: string,
    countAsStartupRecovery = true,
  ): Promise<void> {
    const alreadyQuarantined = await readVersionPointer(resolve(pluginRoot, "quarantined"));
    if (alreadyQuarantined === version) return;
    const current = this.#catalog.record(pluginId);
    const quarantined = current === undefined
      ? undefined
      : Object.freeze({
          ...current,
          snapshot: Object.freeze({
            ...current.snapshot,
            enabled: false,
            pendingVersion: null,
            status: "quarantined",
          } satisfies InstalledPluginSnapshot),
        } satisfies InstalledPluginCatalogRecord);
    if (quarantined === undefined) {
      throw new PluginManagerError("plugin_not_found");
    } else {
      await this.#catalog.quarantineCurrent(quarantined, version);
      this.#syncInstalledSnapshots();
    }
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
      // Node synchronously loads standard ESM projects without top-level
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
      // compile the bundled plugin module so it and Node builtin modules
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

async function mapWithConcurrency<TInput, TResult>(
  inputs: readonly TInput[],
  concurrency: number,
  operation: (input: TInput) => Promise<TResult>,
): Promise<readonly TResult[]> {
  const results = new Array<TResult>(inputs.length);
  let nextIndex = 0;
  const workers = Array.from(
    { length: Math.min(Math.max(1, concurrency), inputs.length) },
    async () => {
      while (nextIndex < inputs.length) {
        const index = nextIndex++;
        results[index] = await operation(inputs[index]!);
      }
    },
  );
  await Promise.all(workers);
  return Object.freeze(results);
}
