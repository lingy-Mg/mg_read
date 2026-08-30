/**
 * Runtime 轻量生命周期与 Debug 实时日志广播。
 *
 * 职责：
 * - 向 Supervisor stderr 输出受控的启动与生命周期摘要；
 * - 在进程内将同一摘要广播给已启用的 Debug 实时日志缓冲区。
 *
 * 注意：
 * - 不持久化事件、异常原文、插件正文或绝对路径；
 * - 观察者失败不得改变 Runtime 业务结果。
 *
 */

/** Severities permitted in the structured, Flutter-safe diagnostic stream. */
export type RuntimeDiagnosticLevel = "error" | "info" | "warning";

/** Fixed lifecycle diagnostic identifiers emitted by the desktop executable. */
export type RuntimeLifecycleDiagnosticCode =
  | "runtime_loopback_bind_failed"
  | "runtime_node_version_incompatible"
  | "runtime_shutdown_failed"
  | "runtime_debug_http_port_unavailable"
  | "runtime_start_failed"
  | "runtime_uncaught_exception"
  | "runtime_unhandled_rejection";

/** Reviewed standard-project lifecycle identifiers; no plugin text is retained. */
export type PluginDiagnosticCode =
  | "development_plugin_activation_failed"
  | "development_plugin_added"
  | "development_plugin_build_failed"
  | "development_plugin_removed"
  | "development_plugin_updated"
  | "plugin_disabled"
  | "plugin_enabled"
  | "plugin_invocation_completed"
  | "plugin_invocation_failed"
  | "plugin_invocation_started"
  | "plugin_load_completed"
  | "plugin_load_failed"
  | "plugin_load_started"
  | "plugin_quarantined"
  | "plugin_runtime_initialized"
  | "plugin_uninstall_scheduled"
  | "plugin_uninstall_completed";

/** Every diagnostic code accepted by this Runtime-owned stdout/stderr bridge. */
export type RuntimeDiagnosticCode =
  | RuntimeLifecycleDiagnosticCode
  | PluginDiagnosticCode;

/** One newline-delimited lifecycle record written to stderr. */
export interface RuntimeDiagnosticRecord {
  /** Stable, documented identifier that Flutter may safely project. */
  readonly code: RuntimeDiagnosticCode;
  /** Stable component name; never a plugin-controlled value. */
  readonly component?: "runtime.plugin" | "runtime.supervisor";
  /** Terminal duration rounded to microseconds when the owner measured it. */
  readonly durationMicros?: number;
  /** Non-fatal severity; fatal records are always projected as errors. */
  readonly level?: RuntimeDiagnosticLevel;
  /** Reviewed, bounded text that never contains raw exception or plugin data. */
  readonly message: string;
  /** Stable lifecycle outcome; start is not mislabeled as success. */
  readonly outcome?: "error" | "started" | "success";
  /** Distinguishes ordinary lifecycle information from terminal startup errors. */
  readonly type: "diagnostic" | "fatal";
}

/** In-process Debug observers; failures are ignored so logs never affect Runtime work. */
export type RuntimeDiagnosticObserver = (record: RuntimeDiagnosticRecord) => void;
const runtimeDiagnosticObservers = new Set<RuntimeDiagnosticObserver>();

export function observeRuntimeDiagnostics(observer: RuntimeDiagnosticObserver): () => void {
  runtimeDiagnosticObservers.add(observer);
  return () => runtimeDiagnosticObservers.delete(observer);
}

/**
 * Writes one reviewed diagnostic record to stderr.
 *
 * Stdio is deliberately limited to startup readiness and structured lifecycle
 * diagnostics. Capability traffic remains on the internal WebSocket, and this
 * function must never receive arbitrary plugin strings, stack traces, paths,
 * environment values, or raw request parameters.
 */
export function emitRuntimeDiagnostic(record: RuntimeDiagnosticRecord): void {
  for (const observer of runtimeDiagnosticObservers) {
    try {
      observer(record);
    } catch {
      // A Debug listener is never permitted to change the producer outcome.
    }
  }
  process.stderr.write(`${JSON.stringify(record)}\n`);
}
