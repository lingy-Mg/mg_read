/**
 * Runtime 桌面进程入口。
 *
 * 职责：
 * - 解析平台适配器提供的最小启动参数；
 * - 启动单个 Runtime Core 并输出受限 ready/progress 记录。
 *
 * 注意：
 * - Debug HTTP 只接受 Debug 平台适配器显式传入的开关；
 * - 不接收主应用路径、凭据、数据库或任意控制参数。
 */
import {
  DesktopRuntime,
  type DesktopRuntimeOptions,
  type DesktopRuntimeProgress,
} from "./desktop-runtime.js";
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

/** Writes only reviewed progress fields to stderr for the Windows supervisor. */
function emitProgress(progress: DesktopRuntimeProgress): void {
  process.stderr.write(`${JSON.stringify({ type: "progress", ...progress })}\n`);
}

/**
 * Parses the CLI's intentionally tiny Runtime-owned launch contract.
 *
 * Values are resolved only by this Runtime's platform adapter: its writable
 * data root, optional immutable bundled-plugin assets, and the Windows
 * debug adapter's source-project root. They are
 * not host callbacks, databases, Cookies, file services or app settings.
 */
function parseLaunchOptions(arguments_: readonly string[]): DesktopRuntimeOptions {
  const values = new Map<string, string>();
  for (const argument of arguments_) {
    const separator = argument.indexOf("=");
    if (separator <= 2) {
      throw new Error("The desktop Runtime received invalid launch options.");
    }
    const name = argument.slice(0, separator);
    const value = argument.slice(separator + 1);
    if (values.has(name) || value.length === 0 || value.includes("\0")) {
      throw new Error("The desktop Runtime received invalid launch options.");
    }
    values.set(name, value);
  }
  const dataRoot = values.get("--data-root");
  const bundledPluginRoot = values.get("--bundled-plugin-root");
  const developmentPluginRoot = values.get("--development-plugin-root");
  const debugHttpEnabled = values.get("--debug-http-enabled");
  const expectedValueCount = 1 +
    (bundledPluginRoot === undefined ? 0 : 1) +
    (developmentPluginRoot === undefined ? 0 : 1) +
    (debugHttpEnabled === undefined ? 0 : 1);
  if (
    dataRoot === undefined ||
    (debugHttpEnabled !== undefined && debugHttpEnabled !== "1") ||
    values.size !== expectedValueCount
  ) {
    throw new Error("The desktop Runtime requires its platform-owned data root.");
  }
  return {
    dataRoot,
    ...(bundledPluginRoot === undefined ? {} : { bundledPluginRoot }),
    ...(developmentPluginRoot === undefined ? {} : { developmentPluginRoot }),
    ...(debugHttpEnabled === undefined ? {} : { debugHttpAllowed: true }),
    onProgress: emitProgress,
  };
}

/**
 * Consumes a testkit-only crash trigger before parsing the production launch
 * contract. It is accepted exclusively by the package-owned Dart test bundle
 * and is never supplied by application code or the public Facade.
 */
function takeTestExitAfterReadyMillis(arguments_: readonly string[]): {
  readonly launchArguments: readonly string[];
  readonly testExitAfterReadyMillis: number | undefined;
} {
  let testExitAfterReadyMillis: number | undefined;
  const launchArguments: string[] = [];
  for (const argument of arguments_) {
    if (!argument.startsWith("--test-exit-after-ready-millis=")) {
      launchArguments.push(argument);
      continue;
    }
    if (testExitAfterReadyMillis !== undefined) {
      throw new Error("The desktop Runtime received invalid launch options.");
    }
    const value = Number(argument.slice("--test-exit-after-ready-millis=".length));
    if (!Number.isSafeInteger(value) || value <= 0 || value > 60_000) {
      throw new Error("The desktop Runtime received invalid launch options.");
    }
    testExitAfterReadyMillis = value;
  }
  return { launchArguments, testExitAfterReadyMillis };
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
  const { launchArguments, testExitAfterReadyMillis } = takeTestExitAfterReadyMillis(
    process.argv.slice(2),
  );
  runtime = new DesktopRuntime(parseLaunchOptions(launchArguments));
  const ready = await runtime.start();
  process.stdout.write(`${JSON.stringify(ready)}\n`);
  if (testExitAfterReadyMillis !== undefined) {
    setTimeout(() => process.exit(86), testExitAfterReadyMillis).unref();
  }
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
