import { DesktopRuntime, type DesktopRuntimeOptions } from "./desktop-runtime.js";
import {
  emitRuntimeDiagnostic,
  type RuntimeDiagnosticRecord,
  type RuntimeLifecycleDiagnosticCode,
} from "./runtime-diagnostics.js";

/** Codes that may terminate the executable before or after readiness. */
type RuntimeFatalDiagnosticCode = Exclude<
  RuntimeLifecycleDiagnosticCode,
  "runtime_shutdown_failed"
>;

let runtime: DesktopRuntime | undefined;
let stopping = false;
let fatalReported = false;

/**
 * Emits only reviewed, structured text. Raw exceptions must remain private to
 * the Node process so paths, environment values, stack traces, and protocol
 * data never cross into the Flutter-facing diagnostic stream.
 */
function emitDiagnostic(record: RuntimeDiagnosticRecord): void {
  emitRuntimeDiagnostic(record);
}

/**
 * Parses the CLI's intentionally tiny Runtime-owned launch contract.
 *
 * The only value is the data root resolved by this Runtime's platform adapter.
 * It is not a plugin path, host callback, database, Cookie, file service or
 * application-provided setting.
 */
function parseLaunchOptions(arguments_: readonly string[]): DesktopRuntimeOptions {
  if (arguments_.length !== 1 || !arguments_[0]?.startsWith("--data-root=")) {
    throw new Error("The desktop Runtime requires its platform-owned data root.");
  }
  const dataRoot = arguments_[0].slice("--data-root=".length);
  if (dataRoot.length === 0 || dataRoot.includes("\0")) {
    throw new Error("The desktop Runtime received an invalid data root.");
  }
  return { dataRoot };
}

/** Idempotently stops the one Core owned by this executable process. */
async function stopRuntime(): Promise<void> {
  if (stopping) {
    return;
  }
  stopping = true;
  try {
    await runtime?.stop();
  } catch {
    emitDiagnostic({
      code: "runtime_shutdown_failed",
      message: "The desktop Runtime could not complete its shutdown.",
      type: "diagnostic",
      level: "error",
    });
    process.exitCode = 1;
  }
}

/** Emits one fatal record, sets a failing exit code, then attempts cleanup. */
async function failRuntime(
  code: RuntimeFatalDiagnosticCode,
  message: string,
  failure?: unknown,
): Promise<void> {
  if (!fatalReported) {
    fatalReported = true;
    await runtime?.recordFatal(code, failure).catch(() => undefined);
    emitDiagnostic({ code, message, type: "fatal" });
  }
  process.exitCode = 1;
  await stopRuntime();
}

/** Maps known startup failures to the safe diagnostics consumed by Flutter. */
function startupFailureCode(error: unknown): RuntimeFatalDiagnosticCode {
  if (error instanceof Error && error.message.startsWith("Runtime requires Node")) {
    return "runtime_node_version_incompatible";
  }
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "EADDRINUSE"
  ) {
    return "runtime_loopback_bind_failed";
  }
  return "runtime_start_failed";
}

/** Starts the Core and writes its sole stdout readiness record. */
async function main(): Promise<void> {
  runtime = new DesktopRuntime(parseLaunchOptions(process.argv.slice(2)));
  const ready = await runtime.start();
  process.stdout.write(`${JSON.stringify(ready)}\n`);
}

// Signal, exception, and rejection handlers intentionally route through the
// same cleanup path. They never serialize the original unknown error object.
process.once("SIGINT", () => {
  void stopRuntime();
});
process.once("SIGTERM", () => {
  void stopRuntime();
});
process.on("uncaughtException", (error: unknown) => {
  void failRuntime(
    "runtime_uncaught_exception",
    "The desktop Runtime stopped after an unexpected internal failure.",
    error,
  );
});
process.on("unhandledRejection", (reason: unknown) => {
  void failRuntime(
    "runtime_unhandled_rejection",
    "The desktop Runtime stopped after an unhandled internal rejection.",
    reason,
  );
});

void main().catch((error: unknown) => {
  void failRuntime(
    startupFailureCode(error),
    "The desktop Runtime failed before it became ready.",
    error,
  );
});
