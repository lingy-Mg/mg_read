/**
 * Executes one loaded source capability and owns its diagnostic terminal event.
 *
 * Caller cancellation may finish before this function settles; this function
 * continues observing the real plugin Promise so validation, generation safety
 * and exactly one execution terminal remain intact.
 */
import type { AsyncLocalStorage } from "node:async_hooks";

import type { JsonObject } from "./protocol.js";
import {
  PluginContentValidationError,
  type PluginContentOperation,
} from "./plugin-content.js";
import {
  isPluginManagerError,
  type InstalledPluginSnapshot,
  type LoadedPlugin,
  pluginManagerErrorDetail,
  type PluginInvocationScope,
  PluginManagerError,
  type PluginManagerEventSink,
  type PluginRuntimeTraceContext,
} from "./plugin-manager-contract.js";
import { throwIfPluginOperationUnavailable } from "./plugin-operation-wait.js";

export async function invokeLoadedPluginContent<TResult extends JsonObject>(options: {
  readonly debugLogEnabled: () => boolean;
  readonly developmentIsCurrent?: () => boolean;
  readonly deadlineUnixMs: string;
  readonly events: PluginManagerEventSink;
  readonly invocationScope: AsyncLocalStorage<PluginInvocationScope>;
  readonly operation: PluginContentOperation;
  readonly plugin: LoadedPlugin | undefined;
  readonly pluginId: string;
  readonly request: JsonObject;
  readonly signal: AbortSignal;
  readonly snapshot: InstalledPluginSnapshot | undefined;
  readonly trace?: PluginRuntimeTraceContext;
  readonly validate: (pluginId: string, sourceName: string, value: unknown) => TResult;
  readonly validateCorrelation?: (result: TResult) => boolean;
}): Promise<TResult> {
  const {
    debugLogEnabled,
    deadlineUnixMs,
    developmentIsCurrent,
    events,
    invocationScope,
    operation,
    plugin,
    pluginId,
    request,
    signal,
    snapshot,
    trace,
    validate,
    validateCorrelation,
  } = options;
  if (plugin === undefined) {
    throw new PluginManagerError(snapshot?.status === "disabled" ? "plugin_disabled" : "plugin_not_found");
  }
  if (developmentIsCurrent === undefined && snapshot?.enabled !== true) {
    throw new PluginManagerError(snapshot === undefined ? "plugin_not_found" : "plugin_disabled");
  }

  const startedAt = performance.now();
  events({ code: "plugin_invocation_started", operation, outcome: "started", pluginId });
  if (debugLogEnabled()) events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "info", logMessage: `能力请求：操作=${operation}，参数=${JSON.stringify(request)}`, outcome: "success", pluginId });
  try {
    throwIfPluginOperationUnavailable(signal, deadlineUnixMs);
    const value = await invocationScope.run(
      Object.freeze({ deadlineUnixMs, signal, ...(trace === undefined ? {} : { trace }) }),
      () => plugin.module[operation](request),
    );
    if (developmentIsCurrent?.() === false) throw new PluginManagerError("plugin_execution_failed");
    throwIfPluginOperationUnavailable(signal, deadlineUnixMs);
    const result = validate(pluginId, plugin.descriptor.displayName, value);
    if (validateCorrelation !== undefined && !validateCorrelation(result)) {
      throw new PluginContentValidationError("Response validation failed at request correlation: the returned identifiers do not match the request.");
    }
    if (developmentIsCurrent?.() === false) throw new PluginManagerError("plugin_execution_failed");
    events({ code: "plugin_invocation_completed", durationMs: performance.now() - startedAt, operation, outcome: "success", pluginId });
    if (debugLogEnabled()) events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "info", logMessage: `能力响应：操作=${operation}，耗时毫秒=${Math.round(performance.now() - startedAt)}，结果=${JSON.stringify(result).slice(0, 2000)}`, outcome: "success", pluginId });
    return result;
  } catch (error) {
    events({ code: "plugin_invocation_failed", durationMs: performance.now() - startedAt, operation, outcome: "error", pluginId });
    if (debugLogEnabled()) events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.invocation", logLevel: "error", logMessage: `能力调用出错：操作=${operation}，耗时毫秒=${Math.round(performance.now() - startedAt)}，错误=${error instanceof PluginContentValidationError ? error.message : error instanceof PluginManagerError ? error.code : error instanceof Error ? error.name : "unknown"}`, outcome: "error", pluginId });
    // Content invocations are initiated by a visible shelf/discovery action.
    // Keep the exact capability, source and causal Error chain on the wire so
    // the Flutter host never reduces a source failure to a generic message.
    // Source-authored public errors retain their separately reviewed detail.
    if (error instanceof PluginManagerError) {
      throw new PluginManagerError(
        error.code,
        error.code === "plugin_execution_failed"
          ? invocationFailureDetail(pluginId, operation, error)
          : error.detail,
      );
    }
    if (isPluginManagerError(error)) {
      const detail = pluginManagerErrorDetail(error);
      throw new PluginManagerError(
        error.code,
        error.code === "plugin_execution_failed"
          ? invocationFailureDetail(pluginId, operation, error)
          : detail,
      );
    }
    throwIfPluginOperationUnavailable(signal, deadlineUnixMs);
    if (error instanceof PluginContentValidationError) {
      throw new PluginManagerError("plugin_invalid_response", error.message);
    }
    throw new PluginManagerError("plugin_execution_failed", invocationFailureDetail(pluginId, operation, error));
  }
}

/**
 * Makes an ordinary source exception actionable without serializing a stack or
 * arbitrary object graph.  Fetch and WebView errors commonly put the useful
 * network errno in `cause`, so retain a short bounded causal chain as well.
 */
function invocationFailureDetail(pluginId: string, operation: PluginContentOperation, error: unknown): string {
  const causes: string[] = [];
  let current: unknown = error;
  for (let index = 0; index < 4 && current !== undefined && current !== null; index += 1) {
    const text = errorText(current);
    if (text !== "") causes.push(text);
    current = current instanceof Error ? current.cause : undefined;
  }
  const cause = causes.length === 0 ? "No Error message or cause was supplied by the source." : causes.join(" <- ");
  return boundFailureDetail(`pluginId=${pluginId}; operation=${operation}; cause=${cause}`);
}

function errorText(error: unknown): string {
  if (error instanceof Error) {
    const name = error.name.trim() || "Error";
    const message = error.message.replaceAll("\u0000", " ").trim();
    const errorWithCode = error as Error & { readonly code?: unknown };
    const code = typeof errorWithCode.code === "string"
      ? ` [code=${errorWithCode.code}]`
      : "";
    return message === "" ? `${name}${code}` : `${name}${code}: ${message}`;
  }
  if (typeof error === "string") return error.replaceAll("\u0000", " ").trim();
  if (error !== null && typeof error === "object") {
    const value = error as {
      readonly code?: unknown;
      readonly detail?: unknown;
      readonly message?: unknown;
      readonly name?: unknown;
    };
    const name = typeof value.name === "string" && value.name.trim() !== ""
      ? value.name.trim()
      : "Error";
    const message = typeof value.detail === "string" && value.detail.trim() !== ""
      ? value.detail
      : typeof value.message === "string"
        ? value.message
        : undefined;
    const code = typeof value.code === "string" ? ` [code=${value.code}]` : "";
    if (message !== undefined) {
      const normalizedMessage = message.replaceAll("\u0000", " ").trim();
      return normalizedMessage === "" ? `${name}${code}` : `${name}${code}: ${normalizedMessage}`;
    }
  }
  try {
    return String(error).replaceAll("\u0000", " ").trim();
  } catch {
    return "Unstringifiable source failure.";
  }
}

function boundFailureDetail(value: string): string {
  const maximumCharacters = 2048;
  return value.length <= maximumCharacters ? value : `${value.slice(0, maximumCharacters - 1)}…`;
}
