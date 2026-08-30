/**
 * Runtime 插件管理器。
 *
 * 职责：
 * - 在唯一 Node VM 中管理插件冷激活、开发刷新与内容调用。
 * - 维护受限插件上下文、资源代理、缓存和传输队列。
 *
 * 注意：
 * - 不暴露路径、端口、PID 或 raw transport 给 Flutter。
 * - 已安装插件只在 Runtime 冷启动激活；取消和超时必须只有一个终态。
 *
 * TODO:
 * - 将剩余 VM 编排方法继续下沉到显式内部端口。
 */
import { createHash, randomBytes, randomUUID } from "node:crypto";
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
import type { PluginBrowserSessionProvider } from "./plugin-browser-session.js";
import { createPluginContext } from "./plugin-manager-context.js";
import { openMediaProxyResource } from "./media-resource-proxy.js";
import {
  type PluginPackageDescriptor,
  readPluginProject,
  resolveInside,
} from "./plugin-package.js";
import { PluginInstaller } from "./plugin-installer.js";
import { PluginIconResources } from "./plugin-icon-resources.js";
import { measureInstallationTree, retainedArtifactPath } from "./plugin-installation-usage.js";
import {
  createDevelopmentPackageArtifactResource,
  listExportablePluginArtifacts,
} from "./plugin-manager-artifact-transfer.js";
import {
  PluginArtifactTransferManager,
  type PluginTransferArtifact,
  type PluginTransferPlanItem,
  type PluginTransferResource,
} from "./plugin-artifact-transfer.js";
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
  PluginContentValidationError,
  validateChaptersResult,
  validateContentResult,
  validateDetailResult,
  validateDiscoverResult,
  validateSearchResult,
  validateSearchSuggestionsResult,
} from "./plugin-content.js";

import {
  PluginManagerError,
  isPluginManagerError,
  type PluginCacheClearItem,
  type PluginCacheClearResult,
  type PluginCacheUsage,
  type PluginCodeDirectory,
  type PluginInstallationUsage,
  type PluginIconResource,
  type PluginResourceResponse,
  type PluginStartupRecoverySummary,
  type DevelopmentPlugin,
  type InstalledPluginSnapshot,
  type LoadedPlugin,
  type LoadedPluginModule,
  type MgReadPluginContext,
  type PluginContentFunction,
  type PluginInvocationScope,
  type PluginManagerEvent,
  type PluginManagerEventSink,
  type PluginRuntimeHttpClient,
  type PluginRuntimeTraceContext,
} from "./plugin-manager-contract.js";
import {
  atomicWrite,
  collectDevelopmentFiles,
  developmentProjectFingerprint,
  exists,
  isMissingPath,
  isPluginId,
  normalizePluginModule,
  removePluginStorage,
  readVersionPointer,
  snapshotFrom,
  withEnabledPluginSnapshot,
} from "./plugin-manager-files.js";

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
  type PluginResourceResponse,
  type PluginRuntimeHttpClient,
  type PluginRuntimeTraceContext,
  type PluginStartupRecoverySummary,
} from "./plugin-manager-contract.js";

/** Cold-start loader for standard Node projects in one shared VM/module cache. */
export class PluginManager {
  readonly #dataRoot: string;
  readonly #embedded: boolean;
  readonly #developmentPluginRoot: string | undefined;
  readonly #events: PluginManagerEventSink;
  readonly #debugLogEnabled: () => boolean;
  readonly #http: PluginRuntimeHttpClient;
  readonly #browserSession: PluginBrowserSessionProvider | undefined;
  readonly #resources = new Map<string, { pluginId: string; request: JsonObject }>();
  readonly #pluginIcons: PluginIconResources;
  #resourceOrigin = "http://127.0.0.1";
  readonly #invocationScope = new AsyncLocalStorage<PluginInvocationScope>();
  readonly #installedLoaded = new Map<string, LoadedPlugin>();
  readonly #developmentLoaded = new Map<string, DevelopmentPlugin>();
  readonly #cacheOperationTails = new Map<string, Promise<void>>();
  readonly #pluginTransfer: PluginArtifactTransferManager;
  readonly #developmentInvocationTails = new Map<string, Promise<void>>();
  #initializePromise: Promise<void> | undefined;
  #startupQuarantinedCount = 0;
  #installedSnapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);
  #developmentSnapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);
  #developmentRefreshTail: Promise<void> = Promise.resolve();

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly developmentPluginRoot?: string;
      readonly embedded?: boolean;
      readonly events?: PluginManagerEventSink;
      readonly http?: PluginRuntimeHttpClient;
      readonly browserSession?: PluginBrowserSessionProvider;
      readonly debugLogEnabled?: () => boolean;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#embedded = options.embedded ?? false;
    this.#developmentPluginRoot = options.developmentPluginRoot === undefined
      ? undefined
      : resolve(options.developmentPluginRoot);
    this.#events = options.events ?? (() => {});
    this.#debugLogEnabled = options.debugLogEnabled ?? (() => false);
    this.#http = options.http ?? { fetch: (input, init) => fetch(input, init) };
    this.#browserSession = options.browserSession;
    this.#pluginTransfer = new PluginArtifactTransferManager(this.#dataRoot);
    this.#pluginIcons = new PluginIconResources(this.#dataRoot);
  }

  /** Scans pending/current pointers exactly once before Runtime readiness. */
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
    if (this.#resources.size >= 1024) {
      const oldest = this.#resources.keys().next().value;
      if (typeof oldest === "string") this.#resources.delete(oldest);
    }
    const token = randomBytes(32).toString("base64url");
    this.#resources.set(token, { pluginId, request });
    if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy", logLevel: "debug", logMessage: `资源代理已创建：参数=${JSON.stringify(request)}`, outcome: "success", pluginId });
    return `${this.#resourceOrigin}/v1/source-resource/${token}`;
  }

  openMediaResource(token: string, requestHeaders: Readonly<Record<string, string>>, signal: AbortSignal) {
    const entry = this.#resources.get(token);
    return openMediaProxyResource(entry === undefined ? undefined : { fetch: this.#http.fetch.bind(this.#http), proxy: (next) => this.createResourceUrl(entry.pluginId, next), request: entry.request }, requestHeaders, signal);
  }

  async consumeResource(token: string, signal: AbortSignal): Promise<PluginResourceResponse> {
    const entry = this.#resources.get(token); if (entry === undefined || signal.aborted) throw new PluginManagerError("invalid_request");
    await this.initialize(); await this.#refreshDevelopmentPlugins();
    const loaded = this.#developmentLoaded.get(entry.pluginId)?.loaded ?? this.#installedLoaded.get(entry.pluginId); if (loaded === undefined) throw new PluginManagerError("plugin_not_found");
    const startedAt = performance.now();
    if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy", logLevel: "debug", logMessage: `资源代理请求开始：参数=${JSON.stringify(entry.request)}`, outcome: "success", pluginId: entry.pluginId });
    const result = await loaded.module.resource(entry.request);
    if (typeof result !== "object" || result === null) throw new PluginManagerError("invalid_request");
    const value = result as Record<string, unknown>;
    const status = value.status === undefined ? 200 : value.status; const bodyValue = value.body; const body = typeof bodyValue === "string" ? Buffer.from(bodyValue, "utf8") : bodyValue instanceof Uint8Array ? Buffer.from(bodyValue) : undefined;
    if (typeof status !== "number" || !Number.isInteger(status) || status < 100 || status > 599 || body === undefined || body.byteLength > 8 * 1024 * 1024) throw new PluginManagerError("invalid_request");
    const headers: Record<string, string> = {};
    if (value.headers !== undefined) {
      if (typeof value.headers !== "object" || value.headers === null) throw new PluginManagerError("invalid_request");
      for (const [key, header] of Object.entries(value.headers as Record<string, unknown>)) {
        if (!/^(content-type|cache-control|content-disposition|etag|expires|last-modified)$/i.test(key) || typeof header !== "string" || header.length > 1024) throw new PluginManagerError("invalid_request");
        headers[key] = header;
      }
    }
    if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy", logLevel: "debug", logMessage: `资源代理请求完成：状态=${status}，字节=${body.byteLength}，耗时毫秒=${Math.round(performance.now() - startedAt)}`, outcome: "success", pluginId: entry.pluginId });
    return { status, headers, body };
  }


  /** Returns the immutable cold-start installation projection. */
  async listInstalled(): Promise<readonly InstalledPluginSnapshot[]> {
    await this.initialize(); await this.#refreshDevelopmentPlugins();
    return Object.freeze(await Promise.all(this.#combinedSnapshots().map((snapshot) =>
      this.#pluginIcons.project(snapshot, this.#developmentLoaded, this.#resourceOrigin))));
  }

  /** Lists retained artifacts plus explicit, temporary development exports. */
  async listExportableArtifacts(): Promise<readonly PluginTransferArtifact[]> {
    await this.initialize();
    await this.#refreshDevelopmentPlugins();
    return listExportablePluginArtifacts(this.#pluginTransfer, this.#installedSnapshots, this.#developmentLoaded.values());
  }

  async close(): Promise<void> {
    await this.#pluginTransfer.dispose();
  }

  /** Compares sender SemVer against this Runtime's installed versions. */
  async planPluginTransfer(incoming: readonly PluginTransferArtifact[]): Promise<readonly PluginTransferPlanItem[]> { await this.initialize(); return this.#pluginTransfer.plan(incoming, this.#installedSnapshots); }

  /** Creates a one-shot Runtime-private resource for bounded artifact streaming. */
  async createPluginTransferResource(id: string, version: string): Promise<{ readonly token: string; readonly artifact: PluginTransferArtifact }> { await this.initialize(); return this.#pluginTransfer.createResource(id, version); }

  /** Packages one loaded Windows Debug development source without exposing its path. */
  async createDevelopmentPackageResource(pluginId: string): Promise<{ readonly artifact: PluginTransferArtifact; readonly fileName: string; readonly token: string }> {
    await this.initialize();
    await this.#refreshDevelopmentPlugins();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const development = this.#developmentLoaded.get(pluginId);
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
    await this.#refreshDevelopmentPlugins();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const development = this.#developmentLoaded.get(pluginId);
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
    if (pluginId === undefined) await this.#refreshDevelopmentPlugins();
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
    await this.#refreshDevelopmentPlugins();
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
  async clearPluginCache(pluginId: string): Promise<PluginCacheClearResult> {
    await this.initialize();
    await this.#refreshDevelopmentPlugins();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    if (!this.#combinedSnapshots().some((item) => item.id === pluginId)) {
      throw new PluginManagerError("plugin_not_found");
    }
    return Object.freeze({
      items: Object.freeze([await this.#clearCache(pluginId)]),
    } satisfies PluginCacheClearResult);
  }

  /** Clears every currently installed plugin cache, preserving per-plugin status. */
  async clearAllPluginCaches(): Promise<PluginCacheClearResult> {
    await this.initialize();
    await this.#refreshDevelopmentPlugins();
    const pluginIds = this.#combinedSnapshots().map((item) => item.id);
    return Object.freeze({
      items: Object.freeze(await Promise.all(pluginIds.map((pluginId) =>
        this.#clearCache(pluginId)
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
    await this.#refreshDevelopmentPlugins();
    if (this.#developmentLoaded.has(pluginId)) {
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
    return this.#pluginIcons.project(updated, this.#developmentLoaded, this.#resourceOrigin);
  }

  /** Schedules removal of one installed source for the next Runtime cold start. */
  async scheduleUninstall(pluginId: string): Promise<void> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    await this.#refreshDevelopmentPlugins();
    if (this.#developmentLoaded.has(pluginId)) {
      throw new PluginManagerError("invalid_request");
    }
    if (!this.#installedSnapshots.some((item) => item.id === pluginId)) {
      throw new PluginManagerError("plugin_not_found");
    }
    await new PluginInstaller(this.#dataRoot).scheduleUninstall(pluginId);
    this.#events({
      code: "plugin_uninstall_scheduled",
      outcome: "success",
      pluginId,
    });
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
    await this.#refreshDevelopmentPlugins();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const queuedAt = performance.now();
    const releaseCacheOperation = await this.#acquireCacheOperation(pluginId);
    if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "debug", logMessage: `插件调用取得队列：操作=${operation}，等待毫秒=${Math.round(performance.now() - queuedAt)}`, outcome: "success", pluginId });
    const releaseDevelopmentInvocation = this.#developmentLoaded.has(pluginId) ? await this.#acquireDevelopmentInvocation(pluginId) : undefined;
    try {
      if (releaseDevelopmentInvocation !== undefined) await this.#refreshDevelopmentPlugins();
      return await this.#invokeLoadedContent(
        pluginId,
        operation,
        request,
        signal,
        deadlineUnixMs,
        validate,
        trace,
        validateCorrelation,
      );
    } finally {
      releaseDevelopmentInvocation?.();
      releaseCacheOperation();
    }
  }

  async #invokeLoadedContent<TResult extends JsonObject>(
    pluginId: string,
    operation: PluginContentOperation,
    request: JsonObject,
    signal: AbortSignal,
    deadlineUnixMs: string,
    validate: (pluginId: string, sourceName: string, value: unknown) => TResult,
    trace?: PluginRuntimeTraceContext,
    validateCorrelation?: (result: TResult) => boolean,
  ): Promise<TResult> {
    const snapshot = this.#combinedSnapshots().find((item) => item.id === pluginId);
    if (snapshot?.enabled != true) throw new PluginManagerError(snapshot === undefined ? "plugin_not_found" : "plugin_disabled");
    const plugin = this.#developmentLoaded.get(pluginId)?.loaded ?? this.#installedLoaded.get(pluginId);
    if (plugin === undefined) throw new PluginManagerError(snapshot?.status === "disabled" ? "plugin_disabled" : "plugin_not_found");

    const startedAt = performance.now();
    this.#events({
      code: "plugin_invocation_started",
      operation,
      outcome: "started",
      pluginId,
    });
    if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "info", logMessage: `能力请求：操作=${operation}，参数=${JSON.stringify(request)}`, outcome: "success", pluginId });
    try {
      this.#throwIfCancelled(signal, deadlineUnixMs);
      const value = await this.#invocationScope.run(
        Object.freeze({
          deadlineUnixMs,
          signal,
          ...(trace === undefined ? {} : { trace }),
        }),
        () => plugin.module[operation](request),
      );
      this.#throwIfCancelled(signal, deadlineUnixMs);
      const result = validate(
        pluginId,
        plugin.descriptor.displayName,
        value,
      );
      if (validateCorrelation !== undefined && !validateCorrelation(result)) {
        throw new PluginContentValidationError();
      }
      this.#events({
        code: "plugin_invocation_completed",
        durationMs: performance.now() - startedAt,
        operation,
        outcome: "success",
        pluginId,
      });
      if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "info", logMessage: `能力响应：操作=${operation}，耗时毫秒=${Math.round(performance.now() - startedAt)}，结果=${JSON.stringify(result).slice(0, 2000)}`, outcome: "success", pluginId });
      return result;
    } catch (error) {
      this.#events({
        code: "plugin_invocation_failed",
        durationMs: performance.now() - startedAt,
        operation,
        outcome: "error",
        pluginId,
      });
      if (this.#debugLogEnabled()) this.#events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "error", logMessage: `能力调用出错：操作=${operation}，耗时毫秒=${Math.round(performance.now() - startedAt)}，错误=${error instanceof PluginManagerError ? error.code : error instanceof Error ? error.name : "unknown"}`, outcome: "error", pluginId });
      if (isPluginManagerError(error)) throw new PluginManagerError(error.code);
      this.#throwIfCancelled(signal, deadlineUnixMs);
      if (error instanceof PluginContentValidationError) {
        throw new PluginManagerError("plugin_invalid_response");
      }
      // Plugin code rejection is recoverable but never retains error text, stacks, request data, or response content.
      throw new PluginManagerError("plugin_execution_failed");
    }
  }

  async #initialize(): Promise<void> {
    const pluginsRoot = resolve(this.#dataRoot, "plugins");
    await mkdir(pluginsRoot, { recursive: true });
    await this.#refreshDevelopmentPlugins();
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
      if (this.#developmentLoaded.has(entry.name)) continue;
      snapshots.push(await this.#initializePlugin(entry.name, pluginRoot));
    }
    this.#installedSnapshots = Object.freeze(snapshots);
  }

  #refreshDevelopmentPlugins(): Promise<void> {
    if (this.#developmentPluginRoot === undefined) return Promise.resolve();
    const refresh = this.#developmentRefreshTail.then(() =>
      this.#refreshDevelopmentPluginsNow()
    );
    this.#developmentRefreshTail = refresh.catch(() => {});
    return refresh;
  }

  async #refreshDevelopmentPluginsNow(): Promise<void> {
    const developmentRoot = this.#developmentPluginRoot;
    if (developmentRoot === undefined) return;
    const nextLoaded = new Map<string, DevelopmentPlugin>();
    const nextSnapshots: InstalledPluginSnapshot[] = [];
    const entries = await readdir(developmentRoot, { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      if (!entry.isDirectory()) continue;
      const projectRoot = resolve(developmentRoot, entry.name);
      const previousByPath = [...this.#developmentLoaded.values()].find(
        (candidate) => candidate.projectRoot === projectRoot,
      );
      try {
        const project = await readPluginProject(projectRoot);
        if (nextLoaded.has(project.descriptor.id)) continue;
        const fingerprint = await developmentProjectFingerprint(projectRoot);
        const previous = this.#developmentLoaded.get(project.descriptor.id);
        const loaded = previous?.projectRoot === projectRoot
          ? previous.loaded
          : await this.#loadDevelopmentProject(projectRoot, project.descriptor);
        nextLoaded.set(project.descriptor.id, Object.freeze({
          fingerprint: previous?.projectRoot === projectRoot
            ? previous.fingerprint
            : fingerprint,
          loaded,
          projectRoot,
        }));
        nextSnapshots.push(snapshotFrom(
          loaded.descriptor,
          loaded.descriptor.id,
          loaded.descriptor.version,
          null,
          true,
          "development",
        ));
      } catch {
        if (previousByPath === undefined || nextLoaded.has(previousByPath.loaded.descriptor.id)) {
          continue;
        }
        nextLoaded.set(previousByPath.loaded.descriptor.id, previousByPath);
        nextSnapshots.push(snapshotFrom(
          previousByPath.loaded.descriptor,
          previousByPath.loaded.descriptor.id,
          previousByPath.loaded.descriptor.version,
          null,
          true,
          "development",
        ));
      }
    }
    this.#developmentLoaded.clear();
    for (const [pluginId, development] of nextLoaded) {
      this.#developmentLoaded.set(pluginId, development);
    }
    this.#developmentSnapshots = Object.freeze(nextSnapshots);
  }

  async #loadDevelopmentProject(
    projectRoot: string,
    descriptor: PluginPackageDescriptor,
  ): Promise<LoadedPlugin> {
    const startedAt = performance.now();
    this.#events({
      code: "plugin_load_started",
      outcome: "started",
      pluginId: descriptor.id,
    });
    try {
      const entryPath = resolveInside(projectRoot, descriptor.entry);
      const imported = await this.#loadModule(entryPath);
      const candidate = normalizePluginModule(imported);
      if (candidate === undefined) throw new PluginManagerError("plugin_load_failed");
      await candidate.activate(await this.#createContext(descriptor));
      const loaded = Object.freeze({ descriptor, module: candidate });
      this.#events({
        code: "plugin_load_completed",
        durationMs: performance.now() - startedAt,
        outcome: "success",
        pluginId: descriptor.id,
      });
      return loaded;
    } catch {
      this.#events({
        code: "plugin_load_failed",
        durationMs: performance.now() - startedAt,
        outcome: "error",
        pluginId: descriptor.id,
      });
      throw new PluginManagerError("plugin_load_failed");
    }
  }

  #combinedSnapshots(): readonly InstalledPluginSnapshot[] {
    const combined = new Map<string, InstalledPluginSnapshot>();
    for (const snapshot of this.#installedSnapshots) combined.set(snapshot.id, snapshot);
    for (const snapshot of this.#developmentSnapshots) combined.set(snapshot.id, snapshot);
    return Object.freeze(
      [...combined.values()].sort((left, right) => left.id.localeCompare(right.id)),
    );
  }

  async #acquireDevelopmentInvocation(pluginId: string): Promise<() => void> {
    const previous = this.#developmentInvocationTails.get(pluginId) ?? Promise.resolve();
    let releaseGate!: () => void;
    const gate = new Promise<void>((resolveGate) => {
      releaseGate = resolveGate;
    });
    const tail = previous.then(() => gate);
    this.#developmentInvocationTails.set(pluginId, tail);
    await previous;
    return () => {
      releaseGate();
      if (this.#developmentInvocationTails.get(pluginId) === tail) {
        this.#developmentInvocationTails.delete(pluginId);
      }
    };
  }

  /** Serializes cache cleanup with plugin code that may be using that cache. */
  async #acquireCacheOperation(pluginId: string): Promise<() => void> {
    const previous = this.#cacheOperationTails.get(pluginId) ?? Promise.resolve();
    let releaseGate!: () => void;
    const gate = new Promise<void>((resolveGate) => {
      releaseGate = resolveGate;
    });
    const tail = previous.then(() => gate);
    this.#cacheOperationTails.set(pluginId, tail);
    await previous;
    return () => {
      releaseGate();
      if (this.#cacheOperationTails.get(pluginId) === tail) {
        this.#cacheOperationTails.delete(pluginId);
      }
    };
  }

  async #clearCache(pluginId: string): Promise<PluginCacheClearItem> {
    const release = await this.#acquireCacheOperation(pluginId);
    let bytesBefore = 0;
    try {
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
      release();
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
      try {
        const loaded = await this.#loadVersion(pluginId, pluginRoot, current);
        this.#installedLoaded.set(pluginId, loaded);
        return snapshotFrom(loaded.descriptor, pluginId, current, null, true, "active");
      } catch {
        await this.#quarantine(pluginId, pluginRoot, current);
        return snapshotFrom(descriptor, pluginId, current, null, false, "quarantined");
      }
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
  ): Promise<void> {
    const marker = resolve(pluginRoot, "quarantined");
    const alreadyQuarantined = await readVersionPointer(marker);
    if (alreadyQuarantined === version) return;
    await atomicWrite(marker, `${version}\n`);
    this.#startupQuarantinedCount += 1;
    this.#events({
      code: "plugin_quarantined",
      outcome: "error",
      pluginId,
    });
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
      await candidate.activate?.(context);
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

  #throwIfCancelled(signal: AbortSignal, deadlineUnixMs: string): void {
    if (signal.aborted) throw new PluginManagerError("cancelled");
    if (Number(deadlineUnixMs) <= Date.now()) {
      throw new PluginManagerError("timeout");
    }
  }
}
