/** Severities permitted in the structured, Flutter-safe diagnostic stream. */
export type RuntimeDiagnosticLevel = "error" | "info" | "warning";

/** Fixed lifecycle diagnostic identifiers emitted by the desktop executable. */
export type RuntimeLifecycleDiagnosticCode =
  | "runtime_loopback_bind_failed"
  | "runtime_diagnostics_store_failed"
  | "runtime_node_version_incompatible"
  | "runtime_shutdown_failed"
  | "runtime_start_failed"
  | "runtime_uncaught_exception"
  | "runtime_unhandled_rejection";

/** Reviewed standard-project lifecycle identifiers; no plugin text is retained. */
export type PluginDiagnosticCode =
  | "plugin_disabled"
  | "plugin_enabled"
  | "plugin_invocation_completed"
  | "plugin_invocation_failed"
  | "plugin_invocation_started"
  | "plugin_load_completed"
  | "plugin_load_failed"
  | "plugin_load_started"
  | "plugin_log_emitted"
  | "plugin_runtime_initialized"
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

/**
 * Writes one reviewed diagnostic record to stderr.
 *
 * Stdio is deliberately limited to startup readiness and structured lifecycle
 * diagnostics. Capability traffic remains on the internal WebSocket, and this
 * function must never receive arbitrary plugin strings, stack traces, paths,
 * environment values, or raw request parameters.
 */
export function emitRuntimeDiagnostic(record: RuntimeDiagnosticRecord): void {
  process.stderr.write(`${JSON.stringify(record)}\n`);
}
