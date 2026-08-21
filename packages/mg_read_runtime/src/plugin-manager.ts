import { randomUUID } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { createRequire } from "node:module";
import {
  access,
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
  readonly status: "active" | "damaged" | "disabled" | "pending";
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
  readonly #events: PluginManagerEventSink;
  readonly #http: PluginRuntimeHttpClient;
  readonly #invocationScope = new AsyncLocalStorage<PluginInvocationScope>();
  readonly #loaded = new Map<string, LoadedPlugin>();
  #initializePromise: Promise<void> | undefined;
  #snapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly events?: PluginManagerEventSink;
      readonly http?: PluginRuntimeHttpClient;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
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
    return this.#snapshots;
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
    const index = this.#snapshots.findIndex((item) => item.id === pluginId);
    if (index < 0) throw new PluginManagerError("plugin_not_found");

    await new PluginInstaller(this.#dataRoot).setEnabled(pluginId, enabled);
    const current = this.#snapshots[index]!;
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
    this.#snapshots = Object.freeze([
      ...this.#snapshots.slice(0, index),
      updated,
      ...this.#snapshots.slice(index + 1),
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
    if (!isPluginId(pluginId)) {
      throw new PluginManagerError("invalid_request");
    }
    const snapshot = this.#snapshots.find((item) => item.id === pluginId);
    if (snapshot?.enabled != true) {
      throw new PluginManagerError(
        snapshot === undefined ? "plugin_not_found" : "plugin_disabled",
      );
    }
    const plugin = this.#loaded.get(pluginId);
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
    this.#snapshots = Object.freeze(snapshots);
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
        this.#loaded.set(pluginId, loaded);
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
        this.#loaded.set(pluginId, loaded);
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
