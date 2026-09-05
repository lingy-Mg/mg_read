/**
 * Path-free projections of PluginManager lifecycle events.
 *
 * This module owns reviewed diagnostic copy and the public development-change
 * mapping. It never projects project roots or plugin data. A failed
 * development build may carry bounded raw output for the Debug Console only.
 */
import type { PluginManagerEvent } from "./plugin-manager.js";
import type { RuntimeDevelopmentPluginChange } from "./protocol.js";
import type { RuntimeDebugLogInput } from "./debug-http.js";
import { emitRuntimeDiagnostic } from "./runtime-diagnostics.js";

/** Emits only stable plugin lifecycle diagnostics; Debug logs stay separate. */
export function emitPluginManagerDiagnostic(event: PluginManagerEvent): void {
  if (event.code === "plugin_log_emitted") return;
  const code = event.code;
  const messages: Record<Exclude<PluginManagerEvent["code"], "plugin_log_emitted">, string> = {
    development_plugin_activation_failed: "开发数据源的新构建无法激活。",
    development_plugin_added: "开发数据源已加入。",
    development_plugin_build_failed: "开发数据源构建失败。",
    development_plugin_removed: "开发数据源已移除。",
    development_plugin_updated: "开发数据源已热重载。",
    plugin_disabled: "插件数据源已停用。",
    plugin_enabled: "插件数据源已启用。",
    plugin_invocation_completed: "插件能力调用已成功完成。",
    plugin_invocation_failed: "插件能力调用失败。",
    plugin_invocation_started: "插件能力调用已开始。",
    plugin_load_completed: "标准 Node 插件已成功加载。",
    plugin_load_failed: "无法加载标准 Node 插件。",
    plugin_load_started: "标准 Node 插件开始加载。",
    plugin_quarantined: "异常插件数据源已隔离。",
    plugin_uninstall_scheduled: "插件数据源已标记为在下次冷启动时移除。",
    plugin_uninstall_completed: "待卸载的插件已完成卸载。",
  };
  emitRuntimeDiagnostic({
    code,
    component: "runtime.plugin",
    ...(event.durationMs === undefined
      ? {}
      : { durationMicros: Math.max(0, Math.round(event.durationMs * 1_000)) }),
    level: event.outcome === "error" ? "error" : "info",
    message: messages[code],
    outcome: event.outcome,
    type: "diagnostic",
  });
}

export function developmentPluginChangeFromManagerEvent(
  event: PluginManagerEvent,
): RuntimeDevelopmentPluginChange | undefined {
  const kind = switchDevelopmentEventKind(event.code);
  if (kind === undefined) return undefined;
  return Object.freeze({
    kind,
    ...(event.buildOutput === undefined ? {} : { buildOutput: event.buildOutput }),
    ...(event.pluginId === undefined ? {} : { pluginId: event.pluginId }),
    ...(event.pluginName === undefined ? {} : { pluginName: event.pluginName }),
  });
}

/** Projects one failed development build to the transient Runtime Debug log. */
export function developmentPluginBuildFailureDebugLog(
  event: PluginManagerEvent,
): RuntimeDebugLogInput | undefined {
  if (event.code !== "development_plugin_build_failed") return undefined;
  const identity = event.pluginName === undefined
    ? event.pluginId ?? "未命名数据源"
    : `${event.pluginName}${event.pluginId === undefined ? "" : ` (${event.pluginId})`}`;
  return {
    category: "runtime.diagnostic",
    code: event.code,
    level: "error",
    message: `开发数据源构建失败：${identity}\n${event.buildOutput ?? "构建器未返回原始输出。"}`,
    source: "runtime",
    ...(event.pluginId === undefined ? {} : { pluginId: event.pluginId }),
  };
}

function switchDevelopmentEventKind(
  code: PluginManagerEvent["code"],
): RuntimeDevelopmentPluginChange["kind"] | undefined {
  switch (code) {
    case "development_plugin_activation_failed": return "activation_failed";
    case "development_plugin_added": return "added";
    case "development_plugin_build_failed": return "build_failed";
    case "development_plugin_removed": return "removed";
    case "development_plugin_updated": return "updated";
    default: return undefined;
  }
}
