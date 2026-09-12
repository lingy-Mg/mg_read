/**
 * Desktop Runtime startup helpers.
 *
 * Responsibilities:
 * - time and project plugin-artifact inbox work into diagnostics/progress;
 * - translate PluginManager startup phases into the private progress contract;
 * - own the bounded loopback-listen handshake and final service-ready signal.
 *
 * Boundaries:
 * - plugin lifecycle state remains owned by InstalledPluginCatalog/PluginManager;
 * - these helpers project observations only and never mutate plugin state.
 */
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { Duplex } from "node:stream";

import type { DesktopRuntimeProgress, DesktopRuntimeProgressSink } from "./desktop-runtime-options.js";
import { installPluginArtifactInbox, seedBundledPluginArtifacts } from "./plugin-artifact-inbox.js";
import { InstalledPluginCatalog } from "./plugin-catalog.js";
import { PluginManager, type PluginManagerEvent } from "./plugin-manager.js";
import { emitRuntimeDiagnostic } from "./runtime-diagnostics.js";

async function initializePluginArtifactSources(options: {
  readonly bundledPluginRoot?: string | undefined;
  readonly catalog: InstalledPluginCatalog;
  readonly dataRoot: string;
  readonly onProgress: DesktopRuntimeProgressSink;
  readonly pluginImportInboxRoot?: string | undefined;
}): Promise<void> {
  const startedAt = performance.now();
  const inbox = await installPluginArtifactInbox(
    options.dataRoot,
    options.pluginImportInboxRoot,
    options.onProgress,
    options.catalog,
  );
  const bundled = await seedBundledPluginArtifacts(
    options.dataRoot,
    options.bundledPluginRoot,
    options.onProgress,
    options.catalog,
  );
  const itemCount = inbox.discoveredCount + bundled.discoveredCount;
  const durationMicros = Math.round((performance.now() - startedAt) * 1_000);
  emitRuntimeDiagnostic({
    code: "plugin_startup_phase_completed",
    component: "runtime.plugin",
    durationMicros,
    itemCount,
    level: "info",
    message: `数据源启动阶段已完成：inbox，数量=${itemCount}。`,
    outcome: "success",
    startupPhase: "inbox",
    type: "diagnostic",
  });
  options.onProgress({
    completedBytes: itemCount,
    detail: `数据源收件箱扫描完成，共 ${itemCount} 项`,
    durationMicros,
    itemCount,
    stage: "plugin_inbox_scanned",
    totalBytes: itemCount,
  });
}

export async function createInitializedPluginManager(
  dataRoot: string,
  options: NonNullable<ConstructorParameters<typeof PluginManager>[1]> & {
    readonly bundledPluginRoot?: string | undefined;
    readonly onProgress: DesktopRuntimeProgressSink;
    readonly pluginImportInboxRoot?: string | undefined;
  },
): Promise<PluginManager> {
  const {
    bundledPluginRoot,
    onProgress,
    pluginImportInboxRoot,
    ...managerOptions
  } = options;
  const catalog = new InstalledPluginCatalog(dataRoot);
  const manager = new PluginManager(dataRoot, { ...managerOptions, catalog });
  try {
    await initializePluginArtifactSources({
      bundledPluginRoot,
      catalog,
      dataRoot,
      onProgress,
      pluginImportInboxRoot,
    });
    await manager.initialize();
    return manager;
  } catch (error) {
    await manager.close().catch(() => {});
    throw error;
  }
}

export function startupProgressFromManagerEvent(
  event: PluginManagerEvent,
): DesktopRuntimeProgress | undefined {
  if (
    (event.code === "plugin_uninstall_started" || event.code === "plugin_uninstall_completed") &&
    event.pluginName !== undefined &&
    event.itemCount !== undefined &&
    event.totalItemCount !== undefined
  ) {
    return {
      completedBytes: event.itemCount,
      detail: event.code === "plugin_uninstall_started"
        ? `正在删除 ${event.pluginName}（${event.itemCount}/${event.totalItemCount}）`
        : `已删除 ${event.pluginName}（${event.itemCount}/${event.totalItemCount}）`,
      itemCount: event.itemCount,
      stage: event.code === "plugin_uninstall_started" ? "plugin_uninstalling" : "plugin_uninstalled",
      totalBytes: event.totalItemCount,
    };
  }
  if (event.code !== "plugin_startup_phase_completed" || event.startupPhase === undefined) {
    return undefined;
  }
  const stage = event.startupPhase === "development_scan"
    ? "development_plugins_scanned"
    : event.startupPhase === "installed_snapshot"
      ? "installed_plugins_snapshotted"
      : "pending_plugins_activated";
  const itemCount = event.itemCount ?? 0;
  return {
    ...(event.catalogState === undefined ? {} : { catalogState: event.catalogState }),
    completedBytes: itemCount,
    detail: event.startupPhase === "installed_snapshot"
      ? `稳定数据源快照完成，共 ${itemCount} 项，目录索引=${event.catalogState ?? "rebuilt"}`
      : `数据源启动阶段完成：${event.startupPhase}，数量=${itemCount}`,
    ...(event.durationMs === undefined ? {} : { durationMicros: Math.round(event.durationMs * 1_000) }),
    itemCount,
    stage,
    totalBytes: itemCount,
  };
}

async function listenOnLoopback(server: Server, host: string, port: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = (): void => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen({ host, port });
  });
}

export async function startLoopbackServer(options: {
  readonly host: string;
  readonly onHttp: (request: IncomingMessage, response: ServerResponse) => void;
  readonly onUpgrade: (request: IncomingMessage, socket: Duplex, head: Buffer) => void;
  readonly port: number;
}): Promise<{ readonly port: number; readonly server: Server }> {
  const server = createServer({ maxHeaderSize: 32 * 1024 }, options.onHttp);
  server.on("upgrade", options.onUpgrade);
  try {
    await listenOnLoopback(server, options.host, options.port);
  } catch (error) {
    server.close();
    throw error;
  }
  const address = server.address();
  if (address === null || typeof address === "string") {
    server.close();
    throw new Error("Runtime did not expose a TCP loopback address.");
  }
  return Object.freeze({ port: address.port, server });
}

export function reportRuntimeServiceReady(
  runtimeStartedAt: number,
  onProgress: DesktopRuntimeProgressSink,
): void {
  const durationMicros = Math.round((performance.now() - runtimeStartedAt) * 1_000);
  emitRuntimeDiagnostic({
    code: "plugin_startup_phase_completed",
    component: "runtime.plugin",
    durationMicros,
    itemCount: 1,
    level: "info",
    message: "数据源启动阶段已完成：service_ready，数量=1。",
    outcome: "success",
    startupPhase: "service_ready",
    type: "diagnostic",
  });
  onProgress({
    completedBytes: 1,
    detail: "数据源 Runtime 服务已就绪",
    durationMicros,
    itemCount: 1,
    stage: "service_ready",
    totalBytes: 1,
  });
}
