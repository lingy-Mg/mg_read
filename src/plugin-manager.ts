import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
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
import { pluginApiVersion } from "./plugin-package.js";
import { runtimeVersion } from "./runtime-version.js";

const MAX_SEARCH_KEYWORD_CHARACTERS = 4_096;
const MAX_SEARCH_ITEMS = 200;
const MAX_RESULT_STRING_CHARACTERS = 8_192;

export type PluginManagerEventCode =
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
  readonly enabled: boolean;
  readonly id: string;
  readonly name: string;
  readonly pendingVersion: string | null;
  readonly status: "active" | "damaged" | "disabled" | "pending";
}

export interface PluginSearchItem extends JsonObject {
  readonly author?: string;
  readonly id: string;
  readonly title: string;
}

export interface PluginSearchResult extends JsonObject {
  readonly items: readonly PluginSearchItem[];
  readonly pluginId: string;
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

interface LoadedPluginModule {
  activate?: (context: MgReadPluginContext) => Promise<void> | void;
  search?: (keyword: string) => Promise<unknown> | unknown;
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

  /** Invokes a production `search(keyword)` named export with bounded projection. */
  async search(
    pluginId: string,
    keyword: string,
    signal: AbortSignal,
    deadlineUnixMs: string,
    trace?: PluginRuntimeTraceContext,
  ): Promise<PluginSearchResult> {
    await this.initialize();
    if (
      !isPluginId(pluginId) ||
      keyword.length === 0 ||
      keyword.length > MAX_SEARCH_KEYWORD_CHARACTERS
    ) {
      throw new PluginManagerError("invalid_request");
    }
    this.#throwIfCancelled(signal, deadlineUnixMs);
    const plugin = this.#loaded.get(pluginId);
    if (plugin === undefined) {
      const snapshot = this.#snapshots.find((item) => item.id === pluginId);
      throw new PluginManagerError(
        snapshot?.status === "disabled" ? "plugin_disabled" : "plugin_not_found",
      );
    }
    if (typeof plugin.module.search !== "function") {
      throw new PluginManagerError("plugin_load_failed");
    }

    const startedAt = performance.now();
    this.#events({
      code: "plugin_invocation_started",
      outcome: "started",
      pluginId,
    });
    try {
      const value = await this.#invocationScope.run(
        Object.freeze({
          deadlineUnixMs,
          signal,
          ...(trace === undefined ? {} : { trace }),
        }),
        () => plugin.module.search!(keyword),
      );
      this.#throwIfCancelled(signal, deadlineUnixMs);
      const result = validateSearchResult(pluginId, value);
      this.#events({
        code: "plugin_invocation_completed",
        durationMs: performance.now() - startedAt,
        outcome: "success",
        pluginId,
      });
      return result;
    } catch (error) {
      this.#events({
        code: "plugin_invocation_failed",
        durationMs: performance.now() - startedAt,
        outcome: "error",
        pluginId,
      });
      if (error instanceof PluginManagerError) throw error;
      this.#throwIfCancelled(signal, deadlineUnixMs);
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
      const imported = (await import(
        pathToFileURL(resolveInside(versionRoot, project.descriptor.entry)).href
      )) as Record<string, unknown>;
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
  const defaultExport = isRecord(imported.default) ? imported.default : undefined;
  const activate = imported.activate ?? defaultExport?.activate;
  const search = imported.search ?? defaultExport?.search;
  if (
    (activate !== undefined && typeof activate !== "function") ||
    (search !== undefined && typeof search !== "function") ||
    typeof search !== "function"
  ) {
    return undefined;
  }
  const searchFunction = search as NonNullable<LoadedPluginModule["search"]>;
  if (typeof activate === "function") {
    return Object.freeze({
      activate: activate as NonNullable<LoadedPluginModule["activate"]>,
      search: searchFunction,
    });
  }
  return Object.freeze({ search: searchFunction });
}

function validateSearchResult(pluginId: string, value: unknown): PluginSearchResult {
  const rawItems = Array.isArray(value)
    ? value
    : isRecord(value) && Array.isArray(value.items)
      ? value.items
      : undefined;
  if (rawItems === undefined || rawItems.length > MAX_SEARCH_ITEMS) {
    throw new PluginManagerError("plugin_invalid_response");
  }
  const items: PluginSearchItem[] = rawItems.map((raw): PluginSearchItem => {
    if (!isRecord(raw)) throw new PluginManagerError("plugin_invalid_response");
    const id = raw.id;
    const title = raw.title;
    const author = raw.author;
    if (
      typeof id !== "string" ||
      id.length === 0 ||
      id.length > MAX_RESULT_STRING_CHARACTERS ||
      typeof title !== "string" ||
      title.length === 0 ||
      title.length > MAX_RESULT_STRING_CHARACTERS ||
      (author !== undefined &&
        (typeof author !== "string" || author.length > MAX_RESULT_STRING_CHARACTERS))
    ) {
      throw new PluginManagerError("plugin_invalid_response");
    }
    return Object.freeze({ ...(author === undefined ? {} : { author }), id, title });
  });
  return Object.freeze({ items: Object.freeze(items), pluginId });
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
    enabled,
    id: pluginId,
    name: descriptor?.name ?? pluginId,
    pendingVersion,
    status,
  });
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
