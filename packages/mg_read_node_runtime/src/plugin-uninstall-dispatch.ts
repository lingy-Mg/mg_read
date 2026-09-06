/**
 * Runtime Core 的数据源状态控制处理器。
 *
 * 职责：验证 path-free 启停/删除请求，并协调 Runtime 内已安装数据源的即时移除。
 * 注意：不热卸载 Node ESM；删除后从当前快照和调度入口移除，已导入模块不可再被来源调用。
 */
import { PluginManager, PluginManagerError } from "./plugin-manager.js";
import type {
  JsonValue,
  RuntimeErrorCode,
  RuntimeProtocolError,
  RuntimeRequest,
} from "./protocol.js";

export type PluginUninstallDispatchResult =
  | { readonly error: RuntimeProtocolError }
  | { readonly result: JsonValue };

type RequestError = (
  request: RuntimeRequest,
  code: RuntimeErrorCode,
  message: string,
) => RuntimeProtocolError;

/** Persists an installed source's dispatch state without recreating the current VM. */
export async function dispatchPluginEnabled(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginUninstallDispatchResult> {
  const pluginId = request.params.pluginId;
  const enabled = request.params.enabled;
  if (Object.keys(request.params).length !== 2 || typeof pluginId !== "string" || typeof enabled !== "boolean") {
    return { error: requestError(request, "invalid_request", "The source enable request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
    return { result: await manager.setEnabled(pluginId, enabled) };
  } catch (error) {
    const code = error instanceof PluginManagerError ? error.code : "internal";
    return {
      error: requestError(
        request,
        code as RuntimeErrorCode,
        "The source enable request could not be completed.",
      ),
    };
  }
}

/** Removes one installed source after current source calls finish. */
export async function dispatchPluginUninstall(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginUninstallDispatchResult> {
  const pluginId = request.params.pluginId;
  if (Object.keys(request.params).length !== 1 || typeof pluginId !== "string") {
    return { error: requestError(request, "invalid_request", "The source uninstall request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
    return { result: await manager.uninstall(pluginId) };
  } catch (error) {
    const code = error instanceof PluginManagerError ? error.code : "internal";
    return {
      error: requestError(
        request,
        code as RuntimeErrorCode,
        "The source uninstall request could not be completed.",
      ),
    };
  }
}

/** Removes every installed source while preserving workspace development sources. */
export async function dispatchPluginUninstallAll(
  request: RuntimeRequest,
  manager: PluginManager | undefined,
  requestError: RequestError,
): Promise<PluginUninstallDispatchResult> {
  if (Object.keys(request.params).length !== 0) {
    return { error: requestError(request, "invalid_request", "The all-source uninstall request is invalid.") };
  }
  try {
    if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
    return { result: await manager.uninstallAll() };
  } catch (error) {
    const code = error instanceof PluginManagerError ? error.code : "internal";
    return {
      error: requestError(
        request,
        code as RuntimeErrorCode,
        "The all-source uninstall request could not be completed.",
      ),
    };
  }
}
