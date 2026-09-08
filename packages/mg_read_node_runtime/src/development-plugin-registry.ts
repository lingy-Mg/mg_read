/**
 * Metadata-first development plugin registry.
 *
 * Responsibilities:
 * - expose validated project snapshots without importing plugin modules at startup;
 * - single-flight the first generation load and retain generations during calls;
 * - serialize watcher builds so only an activated candidate replaces current code.
 *
 * Boundaries:
 * - artifact creation stays in PluginManager's transfer owner;
 * - this registry never exposes project paths across the Runtime Facade.
 */
import { readdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

import { DevelopmentPluginMonitor, type DevelopmentBuildResult } from "./development-plugin-monitor.js";
import {
  commitDevelopmentSourceFingerprint,
  inspectDevelopmentSourceState,
} from "./development-build-state.js";
import {
  DevelopmentGenerationLifetime,
  developmentPluginProjectIdentity,
} from "./development-plugin-runtime.js";
import type {
  DevelopmentPlugin,
  DevelopmentPluginCandidate,
  InstalledPluginSnapshot,
  PluginManagerEventSink,
} from "./plugin-manager-contract.js";
import { PluginManagerError } from "./plugin-manager-contract.js";
import {
  readPluginProject,
  type PluginPackageDescriptor,
} from "./plugin-package.js";
import { snapshotFrom } from "./plugin-manager-files.js";

const MAX_DEVELOPMENT_BUILD_OUTPUT_BYTES = 64 * 1024;

function formatDevelopmentBuildOutput(result: DevelopmentBuildResult): string {
  const sections: string[] = [];
  if (result.stdout.length > 0) sections.push(`[stdout]\n${result.stdout}`);
  if (result.stderr.length > 0) sections.push(`[stderr]\n${result.stderr}`);
  sections.push(
    `[exit] code=${result.exitCode ?? "null"} signal=${result.signal ?? "null"}`,
  );
  return Buffer.from(sections.join("\n"), "utf8")
    .subarray(0, MAX_DEVELOPMENT_BUILD_OUTPUT_BYTES)
    .toString("utf8");
}

export type DevelopmentPluginLoader = (
  projectRoot: string,
  descriptor: PluginPackageDescriptor,
) => Promise<DevelopmentPlugin>;

export class DevelopmentPluginRegistry {
  readonly #candidates = new Map<string, DevelopmentPluginCandidate>();
  readonly #dataRoot: string;
  readonly #events: PluginManagerEventSink;
  readonly #lifetime = new DevelopmentGenerationLifetime();
  readonly #load: DevelopmentPluginLoader;
  readonly #loaded = new Map<string, DevelopmentPlugin>();
  readonly #loadPromises = new Map<string, Promise<DevelopmentPlugin>>();
  readonly #npmCli: string | undefined;
  readonly #root: string | undefined;
  #monitor: DevelopmentPluginMonitor | undefined;
  #mutationTail: Promise<void> = Promise.resolve();
  #snapshots: readonly InstalledPluginSnapshot[] = Object.freeze([]);

  constructor(options: {
    readonly dataRoot: string;
    readonly events: PluginManagerEventSink;
    readonly load: DevelopmentPluginLoader;
    readonly npmCli?: string;
    readonly root?: string;
  }) {
    this.#dataRoot = resolve(options.dataRoot);
    this.#events = options.events;
    this.#load = options.load;
    this.#npmCli = options.npmCli === undefined ? undefined : resolve(options.npmCli);
    this.#root = options.root === undefined ? undefined : resolve(options.root);
  }

  get snapshots(): readonly InstalledPluginSnapshot[] { return this.#snapshots; }

  has(pluginId: string): boolean {
    return this.#candidates.has(pluginId) || this.#loaded.has(pluginId);
  }

  getLoaded(pluginId: string): DevelopmentPlugin | undefined {
    return this.#loaded.get(pluginId);
  }

  loadedValues(): IterableIterator<DevelopmentPlugin> {
    return this.#loaded.values();
  }

  project(pluginId: string): DevelopmentPlugin | DevelopmentPluginCandidate | undefined {
    return this.#loaded.get(pluginId) ?? this.#candidates.get(pluginId);
  }

  projects(): ReadonlyMap<string, DevelopmentPlugin | DevelopmentPluginCandidate> {
    return new Map<string, DevelopmentPlugin | DevelopmentPluginCandidate>([
      ...this.#candidates,
      ...this.#loaded,
    ]);
  }

  retain(plugin: DevelopmentPlugin): void { this.#lifetime.retain(plugin); }

  release(plugin: DevelopmentPlugin): Promise<void> { return this.#lifetime.release(plugin); }

  async initialize(): Promise<void> {
    const root = this.#root;
    if (root === undefined) return;
    if (this.#npmCli !== undefined) {
      this.#monitor = new DevelopmentPluginMonitor({
        developmentRoot: root,
        npmCliPath: this.#npmCli,
        onBuildFailed: (projectRoot, result) => this.#queue(async () => {
          this.#events({
            code: "development_plugin_build_failed",
            outcome: "error",
            ...await developmentPluginProjectIdentity(this.#loaded, projectRoot),
            buildOutput: formatDevelopmentBuildOutput(result),
          });
        }),
        onBuilt: (projectRoot) => this.#queue(() => this.#reload(projectRoot)),
        onRemoved: (projectRoot) => this.#queue(async () => this.#remove(projectRoot)),
      });
      await this.#monitor.start();
    }
    const entries = await readdir(root, { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      if (!entry.isDirectory()) continue;
      const projectRoot = resolve(root, entry.name);
      try {
        const project = await readPluginProject(projectRoot);
        if (this.has(project.descriptor.id)) continue;
        const sourceState = await inspectDevelopmentSourceState(
          this.#dataRoot,
          project.descriptor.id,
          projectRoot,
        );
        this.#candidates.set(project.descriptor.id, Object.freeze({
          descriptor: project.descriptor,
          requiresBuild: this.#monitor !== undefined && sourceState.requiresBuild,
          projectRoot,
          sourceFingerprint: sourceState.fingerprint,
        }));
      } catch {
        // One invalid development project must not block unrelated sources.
      }
    }
    this.#rebuildSnapshots();
  }

  async close(): Promise<void> {
    await this.#monitor?.close();
    await this.#mutationTail.catch(() => {});
    await this.#lifetime.close(this.#loaded.values());
    await rm(resolve(this.#dataRoot, "development-generations"), {
      force: true,
      recursive: true,
    }).catch(() => {});
  }

  async ensureAllLoaded(): Promise<void> {
    for (const pluginId of [...this.#candidates.keys()]) {
      await this.ensureLoaded(pluginId).catch(() => undefined);
    }
  }

  async ensureLoaded(pluginId: string): Promise<DevelopmentPlugin | undefined> {
    const loaded = this.#loaded.get(pluginId);
    if (loaded !== undefined) return loaded;
    if (!this.#candidates.has(pluginId)) return undefined;
    const existing = this.#loadPromises.get(pluginId);
    if (existing !== undefined) return existing;

    const loading = this.#queue(async () => {
      const currentLoaded = this.#loaded.get(pluginId);
      if (currentLoaded !== undefined) return currentLoaded;
      const candidate = this.#candidates.get(pluginId);
      if (candidate === undefined) throw new PluginManagerError("plugin_not_found");
      try {
        let descriptor = candidate.descriptor;
        let sourceFingerprint = candidate.sourceFingerprint;
        if (candidate.requiresBuild) {
          const result = await this.#monitor!.buildNow(candidate.projectRoot);
          if (!result.success) {
            await this.#reportBuildFailure(candidate.projectRoot, result);
            throw new PluginManagerError("plugin_load_failed");
          }
          descriptor = (await readPluginProject(candidate.projectRoot)).descriptor;
          sourceFingerprint = (await inspectDevelopmentSourceState(
            this.#dataRoot,
            descriptor.id,
            candidate.projectRoot,
          )).fingerprint;
        }
        const development = await this.#load(candidate.projectRoot, descriptor);
        const finalFingerprint = (await inspectDevelopmentSourceState(
          this.#dataRoot,
          descriptor.id,
          candidate.projectRoot,
        )).fingerprint;
        if (finalFingerprint !== sourceFingerprint) {
          this.#lifetime.retire(development);
          throw new PluginManagerError("plugin_load_failed");
        }
        await commitDevelopmentSourceFingerprint(
          this.#dataRoot,
          descriptor.id,
          finalFingerprint,
        );
        this.#candidates.delete(pluginId);
        this.#loaded.set(descriptor.id, development);
        this.#rebuildSnapshots();
        return development;
      } catch (error) {
        this.#events({
          code: "development_plugin_activation_failed",
          outcome: "error",
          pluginId,
          pluginName: candidate.descriptor.displayName,
        });
        throw error;
      }
    });
    this.#loadPromises.set(pluginId, loading);
    void loading.then(
      () => this.#loadPromises.delete(pluginId),
      () => this.#loadPromises.delete(pluginId),
    );
    return loading;
  }

  #queue<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.#mutationTail.then(operation);
    this.#mutationTail = next.then(() => undefined, () => undefined);
    return next;
  }

  async #reload(projectRoot: string): Promise<void> {
    const previousLoaded = [...this.#loaded.values()].find(
      (candidate) => candidate.projectRoot === projectRoot,
    );
    const previousCandidate = [...this.#candidates.values()].find(
      (candidate) => candidate.projectRoot === projectRoot,
    );
    let descriptor: PluginPackageDescriptor | undefined;
    try {
      descriptor = (await readPluginProject(projectRoot)).descriptor;
      const loadedConflict = this.#loaded.get(descriptor.id);
      const candidateConflict = this.#candidates.get(descriptor.id);
      if (
        (loadedConflict !== undefined && loadedConflict.projectRoot !== projectRoot) ||
        (candidateConflict !== undefined && candidateConflict.projectRoot !== projectRoot)
      ) {
        throw new PluginManagerError("plugin_load_failed");
      }
      const sourceFingerprint = (await inspectDevelopmentSourceState(
        this.#dataRoot,
        descriptor.id,
        projectRoot,
      )).fingerprint;
      const development = await this.#load(projectRoot, descriptor);
      const finalFingerprint = (await inspectDevelopmentSourceState(
        this.#dataRoot,
        descriptor.id,
        projectRoot,
      )).fingerprint;
      if (sourceFingerprint !== finalFingerprint) {
        this.#lifetime.retire(development);
        throw new PluginManagerError("plugin_load_failed");
      }
      await commitDevelopmentSourceFingerprint(
        this.#dataRoot,
        descriptor.id,
        finalFingerprint,
      );
      const previousId = previousLoaded?.loaded.descriptor.id ?? previousCandidate?.descriptor.id;
      if (previousLoaded !== undefined) {
        this.#loaded.delete(previousLoaded.loaded.descriptor.id);
        this.#lifetime.retire(previousLoaded);
      }
      if (previousCandidate !== undefined) {
        this.#candidates.delete(previousCandidate.descriptor.id);
      }
      if (previousId !== undefined && previousId !== descriptor.id) {
        this.#events({
          code: "development_plugin_removed",
          outcome: "success",
          pluginId: previousId,
        });
      }
      this.#loaded.set(descriptor.id, development);
      this.#rebuildSnapshots();
      this.#events({
        code: previousId === undefined
          ? "development_plugin_added"
          : "development_plugin_updated",
        outcome: "success",
        pluginId: descriptor.id,
      });
    } catch {
      this.#events({
        code: "development_plugin_activation_failed",
        outcome: "error",
        ...(descriptor === undefined
          ? await developmentPluginProjectIdentity(this.#loaded, projectRoot)
          : { pluginId: descriptor.id, pluginName: descriptor.displayName }),
      });
    }
  }

  async #reportBuildFailure(
    projectRoot: string,
    result: DevelopmentBuildResult,
  ): Promise<void> {
    this.#events({
      code: "development_plugin_build_failed",
      outcome: "error",
      ...await developmentPluginProjectIdentity(this.#loaded, projectRoot),
      buildOutput: formatDevelopmentBuildOutput(result),
    });
  }

  #remove(projectRoot: string): void {
    const loaded = [...this.#loaded.values()].find(
      (candidate) => candidate.projectRoot === projectRoot,
    );
    const candidate = [...this.#candidates.values()].find(
      (item) => item.projectRoot === projectRoot,
    );
    const pluginId = loaded?.loaded.descriptor.id ?? candidate?.descriptor.id;
    if (pluginId === undefined) return;
    if (loaded !== undefined) {
      this.#loaded.delete(pluginId);
      this.#lifetime.retire(loaded);
    }
    if (candidate !== undefined) this.#candidates.delete(pluginId);
    this.#rebuildSnapshots();
    this.#events({
      code: "development_plugin_removed",
      outcome: "success",
      pluginId,
    });
  }

  #rebuildSnapshots(): void {
    const descriptors = new Map<string, PluginPackageDescriptor>();
    for (const [pluginId, candidate] of this.#candidates) {
      descriptors.set(pluginId, candidate.descriptor);
    }
    for (const [pluginId, development] of this.#loaded) {
      descriptors.set(pluginId, development.loaded.descriptor);
    }
    this.#snapshots = Object.freeze(
      [...descriptors]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([pluginId, descriptor]) => snapshotFrom(
          descriptor,
          pluginId,
          descriptor.version,
          null,
          true,
          "development",
        )),
    );
  }
}
