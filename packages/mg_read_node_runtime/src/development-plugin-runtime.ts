/**
 * Development generation activation and lifetime helpers.
 *
 * Candidate activation finishes before callers replace the active map. Retired
 * generations stay on disk only while a request still owns them.
 */
import { readFile, rm } from "node:fs/promises";
import { resolve } from "node:path";

import { resolveDevelopmentSyncRevision } from "./development-sync-revision.js";
import { stageDevelopmentGeneration } from "./development-plugin-generation.js";
import { activatePlugin } from "./plugin-activation.js";
import {
  type DevelopmentPlugin,
  type MgReadPluginContext,
  PluginManagerError,
  type PluginManagerEventSink,
} from "./plugin-manager-contract.js";
import {
  developmentProjectFingerprint,
  normalizePluginModule,
} from "./plugin-manager-files.js";
import { parsePluginPackageDescriptor, type PluginPackageDescriptor, resolveInside } from "./plugin-package.js";

export interface LoadDevelopmentPluginOptions {
  readonly activationTimeoutMs: number;
  readonly createContext: (descriptor: PluginPackageDescriptor) => Promise<MgReadPluginContext>;
  readonly dataRoot: string;
  readonly descriptor: PluginPackageDescriptor;
  readonly events: PluginManagerEventSink;
  readonly loadModule: (entryPath: string) => Promise<Record<string, unknown>>;
  readonly projectRoot: string;
}

/** Stages and activates one candidate without mutating the active registry. */
export async function loadDevelopmentPlugin(
  options: LoadDevelopmentPluginOptions,
): Promise<DevelopmentPlugin> {
  const startedAt = performance.now();
  options.events({
    code: "plugin_load_started",
    outcome: "started",
    pluginId: options.descriptor.id,
  });
  let generationRoot: string | undefined;
  try {
    const generation = await stageDevelopmentGeneration(
      options.dataRoot,
      options.projectRoot,
      options.descriptor,
    );
    generationRoot = generation.generationRoot;
    const imported = await options.loadModule(
      resolveInside(generation.generationRoot, generation.descriptor.entry),
    );
    const candidate = normalizePluginModule(imported);
    if (candidate === undefined) throw new PluginManagerError("plugin_load_failed");
    await activatePlugin(
      candidate,
      await options.createContext(generation.descriptor),
      options.activationTimeoutMs,
    );
    const fingerprint = await developmentProjectFingerprint(options.projectRoot);
    const syncRevision = await resolveDevelopmentSyncRevision(
      options.dataRoot,
      generation.descriptor.id,
      fingerprint,
    );
    const loaded = Object.freeze({
      descriptor: generation.descriptor,
      module: candidate,
    });
    options.events({
      code: "plugin_load_completed",
      durationMs: performance.now() - startedAt,
      outcome: "success",
      pluginId: options.descriptor.id,
    });
    return Object.freeze({
      fingerprint,
      generationRoot: generation.generationRoot,
      loaded,
      projectRoot: options.projectRoot,
      syncRevision,
    });
  } catch {
    if (generationRoot !== undefined) {
      await rm(generationRoot, { force: true, recursive: true }).catch(() => {});
    }
    options.events({
      code: "plugin_load_failed",
      durationMs: performance.now() - startedAt,
      outcome: "error",
      pluginId: options.descriptor.id,
    });
    throw new PluginManagerError("plugin_load_failed");
  }
}

/** Reads identity without requiring the build output entry to exist. */
export async function developmentPluginProjectIdentity(
  loaded: ReadonlyMap<string, DevelopmentPlugin>,
  projectRoot: string,
): Promise<{ readonly pluginId?: string; readonly pluginName?: string }> {
  const active = [...loaded.values()].find(
    (candidate) => candidate.projectRoot === projectRoot,
  )?.loaded.descriptor;
  if (active !== undefined) {
    return { pluginId: active.id, pluginName: active.displayName };
  }
  try {
    const packageJson = JSON.parse(
      await readFile(resolve(projectRoot, "package.json"), "utf8"),
    ) as Record<string, unknown>;
    const descriptor = parsePluginPackageDescriptor(packageJson, resolve(projectRoot));
    return { pluginId: descriptor.id, pluginName: descriptor.displayName };
  } catch {
    return {};
  }
}

/** Tracks request ownership so generation cleanup cannot race plugin code. */
export class DevelopmentGenerationLifetime {
  readonly #active = new Map<DevelopmentPlugin, number>();
  readonly #retired = new Set<DevelopmentPlugin>();

  retain(plugin: DevelopmentPlugin): void {
    this.#active.set(plugin, (this.#active.get(plugin) ?? 0) + 1);
  }

  async release(plugin: DevelopmentPlugin): Promise<void> {
    const remaining = (this.#active.get(plugin) ?? 1) - 1;
    if (remaining > 0) {
      this.#active.set(plugin, remaining);
      return;
    }
    this.#active.delete(plugin);
    if (!this.#retired.delete(plugin)) return;
    await removeGeneration(plugin);
  }

  retire(plugin: DevelopmentPlugin): void {
    if ((this.#active.get(plugin) ?? 0) > 0) {
      this.#retired.add(plugin);
      return;
    }
    void removeGeneration(plugin);
  }

  async close(current: Iterable<DevelopmentPlugin>): Promise<void> {
    await Promise.allSettled(
      [...current, ...this.#retired].map(removeGeneration),
    );
    this.#active.clear();
    this.#retired.clear();
  }
}

function removeGeneration(plugin: DevelopmentPlugin): Promise<void> {
  return rm(plugin.generationRoot, { force: true, recursive: true }).then(
    () => undefined,
    () => undefined,
  );
}
