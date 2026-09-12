/**
 * Construction-only types for the Runtime Core.
 *
 * Platform adapters may supply the browser provider and progress sink here;
 * application code and plugins never receive this construction boundary.
 */
import type { PluginBrowserSessionProvider } from "./plugin-browser-session.js";

/** Safe, bounded progress emitted while Runtime-owned work is running. */
export interface DesktopRuntimeProgress {
  readonly catalogState?: "hit" | "rebuilt";
  readonly completedBytes: number;
  readonly detail?: string;
  readonly durationMicros?: number;
  readonly itemCount?: number;
  readonly stage:
    | "assets_copying"
    | "assets_copied"
    | "assets_reused"
    | "node_starting"
    | "plugin_copying"
    | "plugin_copied"
    | "plugin_inbox_scanned"
    | "plugin_installing"
    | "plugin_uninstalling"
    | "plugin_uninstalled"
    | "development_plugins_scanned"
    | "installed_plugins_snapshotted"
    | "pending_plugins_activated"
    | "service_ready"
    | "ready";
  readonly totalBytes: number;
}

export type DesktopRuntimeProgressSink = (
  progress: DesktopRuntimeProgress,
) => void;

/** Construction-only options for the Node Runtime Core. */
export interface DesktopRuntimeOptions {
  readonly port?: number;
  readonly dataRoot?: string;
  readonly developmentPluginRoot?: string;
  readonly developmentNpmCli?: string;
  readonly pluginImportInboxRoot?: string;
  readonly bundledPluginRoot?: string;
  readonly embedded?: boolean;
  readonly debugHttpAllowed?: boolean;
  readonly onProgress?: DesktopRuntimeProgressSink;
  /** Runtime-package platform adapter; never supplied by application code or plugins. */
  readonly browserSession?: PluginBrowserSessionProvider;
}
