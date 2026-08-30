/**
 * Development generation activation, lifetime and snapshot helpers.
 *
 * Candidate activation finishes before callers replace the active map. Retired
 * generations stay on disk only while a request still owns them.
 */
import { randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";

import { stageDevelopmentGeneration } from "./development-plugin-generation.js";
import { activatePlugin } from "./plugin-activation.js";
import {
  type DevelopmentPlugin,
  type InstalledPluginSnapshot,
  type MgReadPluginContext,
  PluginManagerError,
  type PluginManagerEventSink,
} from "./plugin-manager-contract.js";
import { normalizePluginModule, snapshotFrom } from "./plugin-manager-files.js";
import { type PluginPackageDescriptor, resolveInside } from "./plugin-package.js";
import { readPluginProject } from "./plugin-package.js";

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
      fingerprint: randomUUID(),
      generationRoot: generation.generationRoot,
      loaded,
      projectRoot: options.projectRoot,
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

export function developmentPluginIdentity(
  loaded: ReadonlyMap<string, DevelopmentPlugin>,
  projectRoot: string,
): { readonly pluginId?: string } {
  const pluginId = [...loaded.values()].find(
    (candidate) => candidate.projectRoot === projectRoot,
  )?.loaded.descriptor.id;
  return pluginId === undefined ? {} : { pluginId };
}

export function developmentSnapshots(
  loaded: ReadonlyMap<string, DevelopmentPlugin>,
): readonly InstalledPluginSnapshot[] {
  return Object.freeze(
    [...loaded.values()]
      .sort((left, right) => left.loaded.descriptor.id.localeCompare(right.loaded.descriptor.id))
      .map((development) => snapshotFrom(
        development.loaded.descriptor,
        development.loaded.descriptor.id,
        development.loaded.descriptor.version,
        null,
        true,
        "development",
      )),
  );
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

export interface DevelopmentRegistryMutationOptions {
  readonly events: PluginManagerEventSink;
  readonly lifetime: DevelopmentGenerationLifetime;
  readonly load: (
    projectRoot: string,
    descriptor: PluginPackageDescriptor,
  ) => Promise<DevelopmentPlugin>;
  readonly loaded: Map<string, DevelopmentPlugin>;
  readonly onSnapshots: (snapshots: readonly InstalledPluginSnapshot[]) => void;
}

export async function reloadDevelopmentPlugin(
  projectRoot: string,
  options: DevelopmentRegistryMutationOptions,
): Promise<void> {
  const previous = [...options.loaded.values()].find(
    (candidate) => candidate.projectRoot === projectRoot,
  );
  let project: Awaited<ReturnType<typeof readPluginProject>> | undefined;
  try {
    project = await readPluginProject(projectRoot);
    const conflict = options.loaded.get(project.descriptor.id);
    if (conflict !== undefined && conflict.projectRoot !== projectRoot) {
      throw new PluginManagerError("plugin_load_failed");
    }
    const candidate = await options.load(projectRoot, project.descriptor);
    if (previous !== undefined && previous.loaded.descriptor.id !== project.descriptor.id) {
      options.loaded.delete(previous.loaded.descriptor.id);
      options.lifetime.retire(previous);
      options.events({
        code: "development_plugin_removed",
        outcome: "success",
        pluginId: previous.loaded.descriptor.id,
      });
    } else if (previous !== undefined) {
      options.lifetime.retire(previous);
    }
    options.loaded.set(project.descriptor.id, candidate);
    options.onSnapshots(developmentSnapshots(options.loaded));
    options.events({
      code: previous === undefined
        ? "development_plugin_added"
        : "development_plugin_updated",
      outcome: "success",
      pluginId: project.descriptor.id,
    });
  } catch {
    options.events({
      code: "development_plugin_activation_failed",
      outcome: "error",
      ...(project?.descriptor.id === undefined
        ? developmentPluginIdentity(options.loaded, projectRoot)
        : { pluginId: project.descriptor.id }),
    });
  }
}

export function removeDevelopmentPlugin(
  projectRoot: string,
  options: DevelopmentRegistryMutationOptions,
): void {
  const previous = [...options.loaded.values()].find(
    (candidate) => candidate.projectRoot === projectRoot,
  );
  if (previous === undefined) return;
  const pluginId = previous.loaded.descriptor.id;
  options.loaded.delete(pluginId);
  options.lifetime.retire(previous);
  options.onSnapshots(developmentSnapshots(options.loaded));
  options.events({
    code: "development_plugin_removed",
    outcome: "success",
    pluginId,
  });
}

function removeGeneration(plugin: DevelopmentPlugin): Promise<void> {
  return rm(plugin.generationRoot, { force: true, recursive: true }).then(
    () => undefined,
    () => undefined,
  );
}
