/**
 * Runtime Core source capability control dispatch.
 *
 * Responsibilities:
 * - parse and invoke bounded source discovery/content requests;
 * - decode Runtime-owned source-resource URLs for trusted Facade callers;
 * - preserve cancellation, deadline and PluginManager error projection.
 *
 * Transport framing and PluginManager lifecycle remain owned by DesktopRuntime.
 */
import type {
  RuntimeDispatchResult,
  RuntimeRequestErrorFactory,
} from "./desktop-runtime-types.js";
import {
  isPluginManagerError,
  type PluginManager,
  PluginManagerError,
  pluginManagerErrorDetail,
} from "./plugin-manager.js";
import { pluginManagerErrorMessage } from "./plugin-manager-error-message.js";
import {
  parseChaptersParams,
  parseContentParams,
  parseDetailParams,
  parseDiscoverParams,
  parseSearchParams,
  parseSearchSuggestionsParams,
  PluginContentValidationError,
  type PluginContentOperation,
} from "./plugin-content.js";
import type { JsonObject, RuntimeRequest } from "./protocol.js";
import { decodeSourceResourceUrl } from "./source-resource-token.js";

/** Invokes one standard Node source capability through a bounded v1 schema. */
export async function dispatchSourceContent(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RuntimeRequestErrorFactory,
  cancellation: AbortSignal,
  operation: PluginContentOperation = request.method.slice(7, -3) as PluginContentOperation,
): Promise<RuntimeDispatchResult> {
  try {
    if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
    let result: JsonObject;
    switch (operation) {
      case "discover": {
        const parsed = parseDiscoverParams(request.params);
        result = await manager.discover(
          parsed.pluginId,
          parsed.request,
          cancellation,
          request.deadlineUnixMs,
        );
        break;
      }
      case "search": {
        const parsed = parseSearchParams(request.params);
        result = await manager.search(
          parsed.pluginId,
          parsed.request,
          cancellation,
          request.deadlineUnixMs,
        );
        break;
      }
      case "searchSuggestions": {
        const parsed = parseSearchSuggestionsParams(request.params);
        result = await manager.searchSuggestions(
          parsed.pluginId,
          parsed.request,
          cancellation,
          request.deadlineUnixMs,
        );
        break;
      }
      case "getDetail": {
        const parsed = parseDetailParams(request.params);
        result = await manager.getDetail(
          parsed.pluginId,
          parsed.request,
          cancellation,
          request.deadlineUnixMs,
        );
        break;
      }
      case "getChapters": {
        const parsed = parseChaptersParams(request.params);
        result = await manager.getChapters(
          parsed.pluginId,
          parsed.request,
          cancellation,
          request.deadlineUnixMs,
        );
        break;
      }
      case "getContent": {
        const parsed = parseContentParams(request.params);
        result = await manager.getContent(
          parsed.pluginId,
          parsed.request,
          cancellation,
          request.deadlineUnixMs,
        );
        break;
      }
    }
    return { result };
  } catch (error) {
    if (error instanceof PluginContentValidationError) {
      return {
        error: requestError(
          request,
          "invalid_request",
          "The source capability request is invalid.",
        ),
      };
    }
    if (isPluginManagerError(error)) {
      return {
        error: requestError(
          request,
          error.code,
          pluginManagerErrorMessage(error.code, pluginManagerErrorDetail(error)),
        ),
      };
    }
    if (cancellation.aborted) {
      return {
        error: requestError(
          request,
          "cancelled",
          "The plugin request was cancelled.",
        ),
      };
    }
    if (Number(request.deadlineUnixMs) <= Date.now()) {
      return {
        error: requestError(
          request,
          "timeout",
          "The plugin request deadline has elapsed.",
        ),
      };
    }
    return {
      error: requestError(
        request,
        "internal",
        "The plugin request could not be completed.",
      ),
    };
  }
}

/** Decodes a bounded Runtime resource URL without exposing transport state. */
export function dispatchSourceResourceDecode(
  request: RuntimeRequest,
  requestError: RuntimeRequestErrorFactory,
): RuntimeDispatchResult {
  if (
    Object.keys(request.params).length !== 1 ||
    typeof request.params.url !== "string" ||
    request.params.url.length > 32 * 1024
  ) {
    return {
      error: requestError(
        request,
        "invalid_request",
        "The source-resource URL decode request is invalid.",
      ),
    };
  }
  const decoded = decodeSourceResourceUrl(request.params.url);
  if (decoded === undefined) {
    return {
      error: requestError(
        request,
        "invalid_request",
        "The URL is not a valid Runtime source-resource URL.",
      ),
    };
  }
  return { result: { pluginId: decoded.pluginId, request: decoded.request } };
}

/** Rebuilds the same self-contained descriptor at the current listener. */
export async function dispatchSourceResourceResolve(request: RuntimeRequest, manager: PluginManager | undefined, requestError: RuntimeRequestErrorFactory): Promise<RuntimeDispatchResult> {
  const parsed = dispatchSourceResourceDecode(request, requestError);
  if ("error" in parsed) return parsed;
  const decoded = decodeSourceResourceUrl(request.params.url as string)!;
  if (manager === undefined || !(await manager.listInstalled()).some(plugin => plugin.id === decoded.pluginId && plugin.enabled)) {
    return { error: requestError(request, "plugin_disabled", "Resource owner is unavailable or disabled.") };
  }
  try { return { result: {url: manager.createResourceUrl(decoded.pluginId, decoded.request)} }; }
  catch { return { error: requestError(request, "invalid_request", "Resource descriptor is invalid.") }; }
}
