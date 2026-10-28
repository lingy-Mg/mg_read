/**
 * Runtime 来源能力调用分发器。
 *
 * 职责：
 * - 将发现、搜索、详情、目录和正文请求映射到统一的插件调用协议。
 * - 协调每来源调用容量、开发 generation 租约、取消/超时和结果关联校验。
 *
 * 注意：
 * - 插件加载和快照所有权仍属于 PluginManager；本类只通过显式回调读取当前状态。
 * - 客户端终态可以早于插件真实结束，租约必须在真实执行结束后才释放。
 */
import type { AsyncLocalStorage } from "node:async_hooks";

import type { JsonObject } from "./protocol.js";
import type { DevelopmentPluginRegistry } from "./development-plugin-registry.js";
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
  type DevelopmentPlugin,
  type InstalledPluginSnapshot,
  type LoadedPlugin,
  type PluginInvocationScope,
  type PluginManagerEventSink,
  type PluginRuntimeTraceContext,
} from "./plugin-manager-contract.js";
import { isPluginId } from "./plugin-manager-files.js";
import type { PluginOperationCoordinator } from "./plugin-operation-coordinator.js";
import { settlePluginOperation, waitForPluginOperation } from "./plugin-operation-wait.js";

interface PluginContentDispatcherOptions {
  readonly debugLogEnabled: () => boolean;
  readonly development: DevelopmentPluginRegistry;
  readonly ensureInstalledLoaded: (pluginId: string) => Promise<LoadedPlugin | undefined>;
  readonly events: PluginManagerEventSink;
  readonly initialize: () => Promise<void>;
  readonly invocationScope: AsyncLocalStorage<PluginInvocationScope>;
  readonly operations: PluginOperationCoordinator;
  readonly snapshots: () => readonly InstalledPluginSnapshot[];
}

/** Stable Source capability facade over the Runtime's mutable plugin generations. */
export class PluginContentDispatcher {
  readonly #debugLogEnabled: () => boolean;
  readonly #development: DevelopmentPluginRegistry;
  readonly #ensureInstalledLoaded: (pluginId: string) => Promise<LoadedPlugin | undefined>;
  readonly #events: PluginManagerEventSink;
  readonly #initialize: () => Promise<void>;
  readonly #invocationScope: AsyncLocalStorage<PluginInvocationScope>;
  readonly #operations: PluginOperationCoordinator;
  readonly #snapshots: () => readonly InstalledPluginSnapshot[];

  constructor(options: PluginContentDispatcherOptions) {
    this.#debugLogEnabled = options.debugLogEnabled;
    this.#development = options.development;
    this.#ensureInstalledLoaded = options.ensureInstalledLoaded;
    this.#events = options.events;
    this.#initialize = options.initialize;
    this.#invocationScope = options.invocationScope;
    this.#operations = options.operations;
    this.#snapshots = options.snapshots;
  }

  async discover(
    pluginId: string,
    request: PluginDiscoverRequest,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginDiscoverResult> {
    return this.#invoke(
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
    return this.#invoke(
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
    return this.#invoke(
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
    return this.#invoke(
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
    return this.#invoke(
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
    return this.#invoke(
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

  async #invoke<TResult extends JsonObject>(
    pluginId: string,
    operation: PluginContentOperation,
    request: JsonObject,
    signal: AbortSignal,
    deadlineUnixMs: string,
    validate: (pluginId: string, sourceName: string, value: unknown) => TResult,
    trace?: PluginRuntimeTraceContext,
    validateCorrelation?: (result: TResult) => boolean,
  ): Promise<TResult> {
    await this.#initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    const queuedAt = performance.now();
    const releaseOperation = await this.#operations.acquireInvocation(
      pluginId,
      signal,
      deadlineUnixMs,
    );
    let development: DevelopmentPlugin | undefined;
    let operationStarted = false;
    try {
      if (this.#debugLogEnabled()) {
        this.#events({
          code: "plugin_log_emitted",
          logCategory: "runtime.plugin.invocation",
          logLevel: "debug",
          logMessage: `插件调用取得队列：操作=${operation}，等待毫秒=${Math.round(performance.now() - queuedAt)}`,
          outcome: "success",
          pluginId,
        });
      }
      const execution = (async () => {
        try {
          const snapshot = this.#snapshots().find((item) => item.id === pluginId);
          if ((operation === "discover" || operation === "search" || operation === "searchSuggestions") &&
              snapshot !== undefined && snapshot.sourceState !== "available") {
            throw new PluginManagerError("plugin_disabled");
          }
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
            snapshot: this.#snapshots().find((item) => item.id === pluginId),
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
}
