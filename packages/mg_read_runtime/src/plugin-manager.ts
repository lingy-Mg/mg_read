import { createHash, randomUUID } from "node:crypto";
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
import {
  type PluginPackageDescriptor,
  readPluginProject,
  resolveInside,
} from "./plugin-package.js";
import { PluginInstaller } from "./plugin-installer.js";
import { pluginApiVersion } from "./plugin-package.js";
import { runtimeVersion } from "./runtime-version.js";
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
  PluginContentValidationError,
  validateChaptersResult,
  validateContentResult,
  validateDetailResult,
  validateDiscoverResult,
  validateSearchResult,
} from "./plugin-content.js";

export type PluginManagerEventCode =
  | "plugin_disabled"
  | "plugin_enabled"
  | "plugin_invocation_completed"
  | "plugin_invocation_failed"
  | "plugin_invocation_started"
  | "plugin_load_completed"
  | "plugin_load_failed"
  | "plugin_load_started"
  | "plugin_log_emitted"
  | "plugin_uninstall_completed";

export interface PluginManagerEvent {
  readonly code: PluginManagerEventCode;
  readonly durationMs?: number;
  readonly operation?: PluginContentOperation;
  readonly outcome: "error" | "started" | "success";
  readonly pluginId?: string;
}

export type PluginManagerEventSink = (event: PluginManagerEvent) => void;

/** Stable plugin capability failure consumed by the Runtime dispatch owner. */
export class PluginManagerError extends Error {
  constructor(
    readonly code:
      | "cancelled"
      | "invalid_request"
      | "plugin_disabled"
      | "plugin_invalid_response"
      | "plugin_load_failed"
      | "plugin_not_found"
      | "timeout",
  ) {
    super("The Runtime plugin capability could not be completed.");
    this.name = "PluginManagerError";
  }
}

export interface InstalledPluginSnapshot extends JsonObject {
  readonly activeVersion: string | null;
  readonly contentKinds: readonly string[];
  readonly displayName: string;
  readonly enabled: boolean;
  readonly id: string;
  readonly name: string;
  readonly pendingVersion: string | null;
  readonly status: "active" | "damaged" | "development" | "disabled" | "pending";
}

/** A path-free projection of cache bytes owned by one Runtime plugin. */
export interface PluginCacheUsage extends JsonObject {
  readonly bytes: number;
  readonly pluginId: string;
}

/** Path-free size projection for one immutable installed source version. */
export interface PluginInstallationUsage extends JsonObject {
  readonly bytes: number;
  readonly fileCount: number;
  readonly pluginId: string;
  readonly scope: "archive" | "data" | "npm";
  readonly version: string;
}

/** Runtime-internal code directory selected without exposing it to Flutter. */
export interface PluginCodeDirectory {
  readonly directory: string;
  readonly kind: "development" | "installed";
}

/** A stable terminal result for one Runtime-owned cache clear attempt. */
export interface PluginCacheClearItem extends JsonObject {
  readonly bytesBefore: number;
  readonly bytesRemaining: number;
  readonly pluginId: string;
  readonly status: "cleared" | "failed";
}

/** Bounded batch result for one or all plugin cache clear requests. */
export interface PluginCacheClearResult extends JsonObject {
  readonly items: readonly PluginCacheClearItem[];
}

interface MgReadPluginContext {
  readonly app: {
    readonly nodeVersion: string;
    readonly pluginApi: number;
    readonly runtimeVersion: string;
  };
  readonly cacheDir: string;
  readonly dataDir: string;
  readonly http: {
    fetch(input: string | URL, init?: RequestInit): Promise<Response>;
  };
  readonly log: {
    debug(event: string): void;
    error(event: string): void;
    info(event: string): void;
    warn(event: string): void;
  };
  readonly plugin: {
    readonly id: string;
    readonly version: string;
  };
}

type PluginContentFunction = (
  request: JsonObject,
) => Promise<unknown> | unknown;

interface LoadedPluginModule {
  activate: (context: MgReadPluginContext) => Promise<void> | void;
  discover: PluginContentFunction;
  getChapters: PluginContentFunction;
  getContent: PluginContentFunction;
  getDetail: PluginContentFunction;
  search: PluginContentFunction;
}

interface LoadedPlugin {
  readonly descriptor: PluginPackageDescriptor;
  readonly module: LoadedPluginModule;
}

interface DevelopmentPlugin {
  readonly fingerprint: string;
  readonly loaded: LoadedPlugin;
  readonly projectRoot: string;
}

interface PluginInvocationScope {
  readonly deadlineUnixMs: string;
  readonly signal: AbortSignal;
  readonly trace?: PluginRuntimeTraceContext;
}

export interface PluginRuntimeTraceContext {
  readonly parentSpanId?: string;
  readonly spanId: string;
  readonly traceId: string;
}

export interface PluginRuntimeHttpClient {
  fetch(
    input: string | URL,
    init: RequestInit,
    trace?: PluginRuntimeTraceContext,
  ): Promise<Response>;
}

/** Cold-start loader for standard Node projects in one shared VM/module cache. */
export class PluginManager {
  readonly #dataRoot: string;
  readonly #developmentPluginRoot: string | undefined;
  readonly #events: PluginManagerEventSink;
  readonly #http: PluginRuntimeHttpClient;
  readonly #invocationScope = new AsyncLocalStorage<PluginInvocationScope>();
  readonly #installedLoaded = new Map<string, LoadedPlugin>();
  readonly #developmentLoaded = new Map<string, DevelopmentPlugin>();
  readonly #cacheOperationTails = new Map<string, Promise<void>>();
  readonly #developmentInvocationTails = new Map<string, Promise<void>>();
  #initializePromise: Promise<void> | undefined;
  #installedSnapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);
  #developmentSnapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);
  #developmentRefreshTail: Promise<void> = Promise.resolve();

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly developmentPluginRoot?: string;
      readonly events?: PluginManagerEventSink;
      readonly http?: PluginRuntimeHttpClient;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#developmentPluginRoot = options.developmentPluginRoot === undefined
      ? undefined
      : resolve(options.developmentPluginRoot);
    this.#events = options.events ?? (() => {});
    this.#http = options.http ?? { fetch: (input, init) => fetch(input, init) };
  }

  /** Scans pending/current pointers exactly once before Runtime readiness. */
  initialize(): Promise<void> {
    return (this.#initializePromise ??= this.#initialize());
  }

  /** Returns the immutable cold-start installation projection. */
  async listInstalled(): Promise<readonly InstalledPluginSnapshot[]> {
    await this.initialize();
    await this.#refreshDevelopmentPlugins();
    return this.#combinedSnapshots();
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
  async listCacheUsage(): Promise<readonly PluginCacheUsage[]> {
    await this.initialize();
    await this.#refreshDevelopmentPlugins();
    const snapshots = this.#combinedSnapshots();
    return Object.freeze(await Promise.all(snapshots.map(async (snapshot) =>
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
   * `.mgplugin`. Only byte/file totals cross the Facade.
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
      ? resolve(
        this.#dataRoot,
        "plugin-archives",
        pluginId,
        `${version}.mgplugin`,
      )
      : scope === "npm"
        ? resolve(versionRoot, "node_modules")
        : versionRoot;
    const result = await this.#installationBytesAt(root, scope);
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
  async setEnabled(
    pluginId: string,
    enabled: boolean,
  ): Promise<InstalledPluginSnapshot> {
    await this.initialize();
    if (!isPluginId(pluginId)) throw new PluginManagerError("invalid_request");
    await this.#refreshDevelopmentPlugins();
    if (this.#developmentLoaded.has(pluginId)) {
      throw new PluginManagerError("invalid_request");
    }
    const index = this.#installedSnapshots.findIndex((item) => item.id === pluginId);
    if (index < 0) throw new PluginManagerError("plugin_not_found");

    await new PluginInstaller(this.#dataRoot).setEnabled(pluginId, enabled);
    const current = this.#installedSnapshots[index]!;
    const updated = Object.freeze({
      activeVersion: current.activeVersion,
      contentKinds: current.contentKinds,
      displayName: current.displayName,
      enabled,
      id: current.id,
      name: current.name,
      pendingVersion: current.pendingVersion,
      status: enabled ? enabledStatus(current) : "disabled",
    } satisfies InstalledPluginSnapshot);
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
    return updated;
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
    if (!isPluginId(pluginId)) {
      throw new PluginManagerError("invalid_request");
    }
    const releaseCacheOperation = await this.#acquireCacheOperation(pluginId);
    const releaseDevelopmentInvocation = this.#developmentLoaded.has(pluginId)
      ? await this.#acquireDevelopmentInvocation(pluginId)
      : undefined;
    try {
      if (releaseDevelopmentInvocation !== undefined) {
        await this.#refreshDevelopmentPlugins();
      }
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
    if (snapshot?.enabled != true) {
      throw new PluginManagerError(
        snapshot === undefined ? "plugin_not_found" : "plugin_disabled",
      );
    }
    const plugin = this.#developmentLoaded.get(pluginId)?.loaded ??
      this.#installedLoaded.get(pluginId);
    if (plugin === undefined) {
      throw new PluginManagerError(
        snapshot?.status === "disabled" ? "plugin_disabled" : "plugin_not_found",
      );
    }

    const startedAt = performance.now();
    this.#events({
      code: "plugin_invocation_started",
      operation,
      outcome: "started",
      pluginId,
    });
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
      return result;
    } catch (error) {
      this.#events({
        code: "plugin_invocation_failed",
        durationMs: performance.now() - startedAt,
        operation,
        outcome: "error",
        pluginId,
      });
      if (error instanceof PluginManagerError) throw error;
      this.#throwIfCancelled(signal, deadlineUnixMs);
      if (error instanceof PluginContentValidationError) {
        throw new PluginManagerError("plugin_invalid_response");
      }
      throw new PluginManagerError("plugin_invalid_response");
    }
  }

  async #initialize(): Promise<void> {
    const pluginsRoot = resolve(this.#dataRoot, "plugins");
    await mkdir(pluginsRoot, { recursive: true });
    const snapshots: InstalledPluginSnapshot[] = [];
    const entries = await readdir(pluginsRoot, { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      if (!entry.isDirectory() || !isPluginId(entry.name)) continue;
      const pluginRoot = resolve(pluginsRoot, entry.name);
      if (await exists(resolve(pluginRoot, "uninstall-pending"))) {
        await rm(pluginRoot, { force: true, recursive: true });
        this.#events({
          code: "plugin_uninstall_completed",
          outcome: "success",
          pluginId: entry.name,
        });
        continue;
      }
      snapshots.push(await this.#initializePlugin(entry.name, pluginRoot));
    }
    this.#installedSnapshots = Object.freeze(snapshots);
    await this.#refreshDevelopmentPlugins();
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
      const requireFromEntry = createRequire(entryPath);
      const imported = requireFromEntry(entryPath) as Record<string, unknown>;
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

  async #installationBytesAt(
    path: string,
    scope: "archive" | "data" | "npm",
  ): Promise<{ readonly bytes: number; readonly fileCount: number }> {
    let metadata;
    try {
      metadata = await lstat(path);
    } catch (error) {
      if (isMissingPath(error)) return { bytes: 0, fileCount: 0 };
      throw error;
    }
    if (!metadata.isDirectory()) {
      return { bytes: metadata.size, fileCount: 1 };
    }
    const entries = await readdir(path, { withFileTypes: true });
    let bytes = 0;
    let fileCount = 0;
    for (const entry of entries) {
      if (scope === "data" && entry.name === "node_modules") continue;
      const child = await this.#installationBytesAt(
        resolve(path, entry.name),
        scope,
      );
      bytes += child.bytes;
      fileCount += child.fileCount;
      if (!Number.isSafeInteger(bytes) || !Number.isSafeInteger(fileCount)) {
        throw new PluginManagerError("plugin_load_failed");
      }
    }
    return { bytes, fileCount };
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
        this.#installedLoaded.set(pluginId, loaded);
        descriptor = loaded.descriptor;
        return snapshotFrom(descriptor, pluginId, pending, null, true, "active");
      } catch {
        await atomicWrite(resolve(pluginRoot, "failed"), `${pending}\n`);
        await rm(resolve(pluginRoot, "pending"), { force: true });
      }
    }

    if (current !== null) {
      try {
        const loaded = await this.#loadVersion(pluginId, pluginRoot, current);
        this.#installedLoaded.set(pluginId, loaded);
        return snapshotFrom(loaded.descriptor, pluginId, current, null, true, "active");
      } catch {
        return snapshotFrom(descriptor, pluginId, current, null, true, "damaged");
      }
    }
    return snapshotFrom(descriptor, pluginId, null, pending, true, pending ? "pending" : "damaged");
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
      const imported = createRequire(entryPath)(entryPath) as Record<string, unknown>;
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
    const dataDir = resolve(this.#dataRoot, "plugin-data", descriptor.id);
    const cacheDir = resolve(this.#dataRoot, "plugin-cache", descriptor.id);
    await Promise.all([
      mkdir(dataDir, { recursive: true }),
      mkdir(cacheDir, { recursive: true }),
    ]);
    const emitLog = (_event: string): void => {
      // Plugin text is intentionally discarded at this boundary. The stable
      // event proves a log occurred without persisting user input or secrets.
      this.#events({
        code: "plugin_log_emitted",
        outcome: "success",
        pluginId: descriptor.id,
      });
    };
    return Object.freeze({
      app: Object.freeze({
        nodeVersion: process.versions.node,
        pluginApi: pluginApiVersion,
        runtimeVersion,
      }),
      cacheDir,
      dataDir,
      http: Object.freeze({
        fetch: (input: string | URL, init: RequestInit = {}) => {
          const scope = this.#invocationScope.getStore();
          const signals: AbortSignal[] = [];
          if (scope !== undefined) {
            signals.push(scope.signal);
            signals.push(
              AbortSignal.timeout(
                Math.max(1, Number(scope.deadlineUnixMs) - Date.now()),
              ),
            );
          }
          if (init.signal != null) signals.push(init.signal);
          return this.#http.fetch(input, {
            ...init,
            redirect: init.redirect ?? "follow",
            ...(signals.length === 0
              ? {}
              : {
                  signal:
                    signals.length === 1
                      ? signals[0]
                      : AbortSignal.any(signals),
                }),
          }, scope?.trace);
        },
      }),
      log: Object.freeze({
        debug: emitLog,
        error: emitLog,
        info: emitLog,
        warn: emitLog,
      }),
      plugin: Object.freeze({ id: descriptor.id, version: descriptor.version }),
    });
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

function normalizePluginModule(imported: Record<string, unknown>): LoadedPluginModule | undefined {
  const activate = imported.activate;
  const discover = imported.discover;
  const search = imported.search;
  const getDetail = imported.getDetail;
  const getChapters = imported.getChapters;
  const getContent = imported.getContent;
  if (
    typeof activate !== "function" ||
    typeof discover !== "function" ||
    typeof search !== "function" ||
    typeof getDetail !== "function" ||
    typeof getChapters !== "function" ||
    typeof getContent !== "function"
  ) {
    return undefined;
  }
  return Object.freeze({
    activate: activate as LoadedPluginModule["activate"],
    discover: discover as PluginContentFunction,
    getChapters: getChapters as PluginContentFunction,
    getContent: getContent as PluginContentFunction,
    getDetail: getDetail as PluginContentFunction,
    search: search as PluginContentFunction,
  });
}

function snapshotFrom(
  descriptor: PluginPackageDescriptor | undefined,
  pluginId: string,
  activeVersion: string | null,
  pendingVersion: string | null,
  enabled: boolean,
  status: InstalledPluginSnapshot["status"],
): InstalledPluginSnapshot {
  return Object.freeze({
    activeVersion,
    contentKinds: Object.freeze(descriptor?.contentKinds ?? []),
    displayName: descriptor?.displayName ?? pluginId,
    enabled,
    id: pluginId,
    name: descriptor?.name ?? pluginId,
    pendingVersion,
    status,
  });
}

function enabledStatus(
  snapshot: InstalledPluginSnapshot,
): InstalledPluginSnapshot["status"] {
  if (snapshot.activeVersion !== null) return "active";
  if (snapshot.pendingVersion !== null) return "pending";
  return "damaged";
}

async function developmentProjectFingerprint(projectRoot: string): Promise<string> {
  const paths = ["package.json", "package-lock.json"];
  for (const directory of ["dist", "assets", "packages"]) {
    await collectDevelopmentFiles(projectRoot, directory, paths);
  }
  paths.sort((left, right) => left.localeCompare(right));
  if (paths.length > 4_096) throw new PluginManagerError("plugin_load_failed");
  const hash = createHash("sha256");
  let totalBytes = 0;
  for (const path of paths) {
    const bytes = await readFile(resolve(projectRoot, path));
    totalBytes += bytes.byteLength;
    if (totalBytes > 32 * 1024 * 1024) {
      throw new PluginManagerError("plugin_load_failed");
    }
    hash.update(path.replaceAll("\\", "/"));
    hash.update("\0");
    hash.update(bytes);
    hash.update("\0");
  }
  return hash.digest("hex");
}

async function collectDevelopmentFiles(
  projectRoot: string,
  relativeDirectory: string,
  paths: string[],
): Promise<void> {
  const directory = resolve(projectRoot, relativeDirectory);
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (isMissingPath(error) && relativeDirectory !== "dist") return;
    throw error;
  }
  for (const entry of entries) {
    const child = `${relativeDirectory}/${entry.name}`;
    if (entry.isDirectory()) {
      await collectDevelopmentFiles(projectRoot, child, paths);
    } else if (entry.isFile()) {
      paths.push(child);
    } else {
      throw new PluginManagerError("plugin_load_failed");
    }
  }
}

function isMissingPath(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === "object" && error !== null && "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT";
}

async function readVersionPointer(path: string): Promise<string | null> {
  try {
    const value = (await readFile(path, "utf8")).trim();
    return /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/.test(value)
      ? value
      : null;
  } catch {
    return null;
  }
}

async function atomicWrite(path: string, value: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.next-${randomUUID()}`;
  await writeFile(temporary, value, { flag: "wx", mode: 0o600 });
  try {
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true }).catch(() => {});
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function isPluginId(value: string): boolean {
  return /^[a-z0-9]+(?:[.-][a-z0-9]+)+$/.test(value);
}
