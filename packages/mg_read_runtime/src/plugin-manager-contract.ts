/**
 * 插件管理器的内部契约。
 *
 * 职责：
 * - 定义 Runtime dispatch、插件加载和资源调用之间的强类型数据。
 *
 * 注意：
 * - 这些类型不构成 Flutter Facade，也不得包含主应用路径或 transport。
 *
 * TODO:
 * - 无。
 */
import type { JsonObject } from "./protocol.js";
import type { PluginPackageDescriptor } from "./plugin-package.js";
import type { PluginContentOperation } from "./plugin-content.js";
import type { PluginWebViewApi } from "./plugin-webview-page.js";

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
  | "plugin_quarantined"
  | "plugin_uninstall_scheduled"
  | "plugin_uninstall_completed";

export interface PluginManagerEvent {
  readonly code: PluginManagerEventCode;
  readonly durationMs?: number;
  /** Present only for a Debug-only in-memory ctx.log projection. */
  readonly logLevel?: "debug" | "error" | "info" | "warn";
  /** Plugin-authored text; the Runtime Debug buffer redacts and bounds it. */
  readonly logMessage?: string;
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
      | "interaction_required"
      | "invalid_request"
      | "overloaded"
      | "plugin_disabled"
      | "plugin_execution_failed"
      | "plugin_invalid_response"
      | "plugin_load_failed"
      | "plugin_not_found"
      | "timeout"
      | "unsupported",
  ) {
    super("The Runtime plugin capability could not be completed.");
    this.name = "PluginManagerError";
  }
}

const pluginManagerErrorCodes = new Set<PluginManagerError["code"]>([
  "cancelled",
  "interaction_required",
  "invalid_request",
  "overloaded",
  "plugin_disabled",
  "plugin_execution_failed",
  "plugin_invalid_response",
  "plugin_load_failed",
  "plugin_not_found",
  "timeout",
  "unsupported",
]);

/** Preserves stable Runtime errors when embedded module realms duplicate classes. */
export function isPluginManagerError(error: unknown): error is { readonly code: PluginManagerError["code"] } {
  if (error instanceof PluginManagerError) return true;
  if (error === null || typeof error !== "object") return false;
  if ("name" in error && error.name !== "PluginManagerError") return false;
  const code = (error as { readonly code?: unknown }).code;
  return typeof code === "string" && pluginManagerErrorCodes.has(code as PluginManagerError["code"]);
}

export interface InstalledPluginSnapshot extends JsonObject {
  readonly activeVersion: string | null;
  readonly contentKinds: readonly string[];
  readonly description: string | null;
  readonly displayName: string;
  readonly enabled: boolean;
  readonly id: string;
  readonly iconUrl: string | null;
  readonly name: string;
  readonly pendingVersion: string | null;
  readonly status: "active" | "damaged" | "development" | "disabled" | "pending" | "quarantined";
}

export interface PluginIconResource {
  readonly body: Uint8Array;
  readonly mediaType: "image/jpeg" | "image/png" | "image/webp";
}

/** One-shot, path-free summary of sources isolated during this cold start. */
export interface PluginStartupRecoverySummary extends JsonObject {
  readonly quarantinedCount: number;
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

export interface MgReadPluginContext {
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
  readonly browser: {
    readonly sessionV1: {
      request(request: unknown): Promise<unknown>;
      requestCoordinates(request: unknown): Promise<unknown>;
      nativeInput(request: unknown): Promise<unknown>;
      controlClick(request: unknown): Promise<unknown>;
    };
  };
  readonly webview: PluginWebViewApi;
  readonly resource: { proxy(request: JsonObject): string };
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

export type PluginContentFunction = (
  request: JsonObject,
) => Promise<unknown> | unknown;

export interface LoadedPluginModule {
  activate: (context: MgReadPluginContext) => Promise<void> | void;
  discover: PluginContentFunction;
  getChapters: PluginContentFunction;
  getContent: PluginContentFunction;
  getDetail: PluginContentFunction;
  search: PluginContentFunction;
  searchSuggestions: PluginContentFunction;
  resource: PluginContentFunction;
}

export interface LoadedPlugin {
  readonly descriptor: PluginPackageDescriptor;
  readonly module: LoadedPluginModule;
}

export interface DevelopmentPlugin {
  readonly fingerprint: string;
  readonly loaded: LoadedPlugin;
  readonly projectRoot: string;
}

export interface PluginInvocationScope {
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

export interface PluginResourceResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: Uint8Array;
}
