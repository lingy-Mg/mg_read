import { randomUUID } from "node:crypto";
import {
  access,
  chmod,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { dirname, resolve } from "node:path";

import {
  DependencyStore,
  DependencyStoreError,
  type DependencyMaterializationResult,
} from "./dependency-store.js";
import {
  createPluginArchive,
  extractPluginArchive,
} from "./plugin-archive.js";
import {
  dependencyObjectName,
  type LockedPluginDependency,
  type PluginPackageDescriptor,
  PluginPackageError,
  readPluginProject,
  resolveInside,
} from "./plugin-package.js";

/** Stable event names for installer ownership and exactly-one terminal checks. */
export type PluginInstallerEventCode =
  | "plugin_dependency_gc_completed"
  | "plugin_install_completed"
  | "plugin_install_failed"
  | "plugin_install_started"
  | "plugin_uninstall_scheduled";

export interface PluginInstallerEvent {
  readonly code: PluginInstallerEventCode;
  readonly copiedFiles?: number;
  readonly durationMs?: number;
  readonly hardlinkedFiles?: number;
  readonly outcome: "error" | "started" | "success";
  readonly pluginId?: string;
  readonly removedObjects?: number;
}

export type PluginInstallerEventSink = (event: PluginInstallerEvent) => void;

/** Result of a complete immutable-version install transaction. */
export interface PluginInstallResult {
  readonly copiedFiles: number;
  readonly descriptor: PluginPackageDescriptor;
  readonly hardlinkedFiles: number;
  readonly pendingActivation: true;
  readonly reusedVersion: boolean;
  readonly skippedOptionalDependencies: number;
}

/** Runtime-owned standard-project installer and dependency mark/sweep owner. */
export class PluginInstaller {
  readonly #dataRoot: string;
  readonly #dependencyStore: DependencyStore;
  readonly #events: PluginInstallerEventSink;

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly dependencyStore?: DependencyStore;
      readonly events?: PluginInstallerEventSink;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#dependencyStore =
      options.dependencyStore ?? new DependencyStore(this.#dataRoot);
    this.#events = options.events ?? (() => {});
  }

  /** Installs a `.mgplugin` as an immutable version and writes `pending`. */
  async installArchive(archiveFile: string): Promise<PluginInstallResult> {
    const startedAt = performance.now();
    this.#events({ code: "plugin_install_started", outcome: "started" });
    const stagingRoot = resolve(
      this.#dataRoot,
      "staging",
      `plugin-install-${randomUUID()}`,
    );
    try {
      await mkdir(stagingRoot, { recursive: true });
      await extractPluginArchive(archiveFile, stagingRoot);
      const project = await readPluginProject(stagingRoot);
      const result = await this.#commitProject(stagingRoot, project.descriptor, project.dependencies);
      this.#events({
        code: "plugin_install_completed",
        copiedFiles: result.copiedFiles,
        durationMs: performance.now() - startedAt,
        hardlinkedFiles: result.hardlinkedFiles,
        outcome: "success",
        pluginId: result.descriptor.id,
      });
      return result;
    } catch (error) {
      this.#events({
        code: "plugin_install_failed",
        durationMs: performance.now() - startedAt,
        outcome: "error",
      });
      throw error;
    } finally {
      await rm(stagingRoot, { force: true, recursive: true }).catch(() => {});
    }
  }

  /** Test/tooling helper that packs first so directory installs use production parsing. */
  async installProject(projectRoot: string): Promise<PluginInstallResult> {
    const stagingDirectory = resolve(
      this.#dataRoot,
      "staging",
      `plugin-pack-${randomUUID()}`,
    );
    const archive = resolve(stagingDirectory, "plugin.mgplugin");
    await mkdir(stagingDirectory, { recursive: true });
    try {
      await createPluginArchive(projectRoot, archive);
      return await this.installArchive(archive);
    } finally {
      await rm(stagingDirectory, { force: true, recursive: true }).catch(() => {});
    }
  }

  /** Defers deletion to the next Runtime cold start. */
  async scheduleUninstall(pluginId: string): Promise<void> {
    assertPluginId(pluginId);
    const pluginRoot = resolve(this.#dataRoot, "plugins", pluginId);
    await access(pluginRoot);
    await atomicWrite(resolve(pluginRoot, "uninstall-pending"), "1\n");
    this.#events({
      code: "plugin_uninstall_scheduled",
      outcome: "success",
      pluginId,
    });
  }

  /** Enables/disables future dispatch without hot-unloading imported modules. */
  async setEnabled(pluginId: string, enabled: boolean): Promise<void> {
    assertPluginId(pluginId);
    const marker = resolve(this.#dataRoot, "plugins", pluginId, "disabled");
    if (enabled) {
      await rm(marker, { force: true });
      return;
    }
    await atomicWrite(marker, "1\n");
  }

  /** Mark-and-sweep GC derived only from retained package-lock files. */
  async collectUnusedDependencies(): Promise<{ readonly removedObjects: number }> {
    const marked = new Set<string>();
    const pluginsRoot = resolve(this.#dataRoot, "plugins");
    try {
      for (const plugin of await readdir(pluginsRoot, { withFileTypes: true })) {
        if (!plugin.isDirectory()) continue;
        const versionsRoot = resolve(pluginsRoot, plugin.name, "versions");
        let versions;
        try {
          versions = await readdir(versionsRoot, { withFileTypes: true });
        } catch {
          continue;
        }
        for (const version of versions) {
          if (!version.isDirectory()) continue;
          try {
            const project = await readPluginProject(resolve(versionsRoot, version.name));
            for (const dependency of project.dependencies) {
              if (dependency.kind === "registry" && dependency.integrity !== undefined) {
                marked.add(dependencyObjectName(dependency.integrity));
              }
            }
          } catch {
            // A damaged version does not keep an object alive; current/pending
            // activation will surface the package damage separately.
          }
        }
      }
    } catch (error) {
      if (!isNodeError(error, "ENOENT")) throw error;
    }

    let removedObjects = 0;
    for (const objectName of await this.#dependencyStore.listObjectNames()) {
      if (!marked.has(objectName)) {
        await this.#dependencyStore.removeObject(objectName);
        removedObjects += 1;
      }
    }
    this.#events({
      code: "plugin_dependency_gc_completed",
      outcome: "success",
      removedObjects,
    });
    return Object.freeze({ removedObjects });
  }

  async #commitProject(
    stagingRoot: string,
    descriptor: PluginPackageDescriptor,
    dependencies: readonly LockedPluginDependency[],
  ): Promise<PluginInstallResult> {
    const pluginRoot = resolve(this.#dataRoot, "plugins", descriptor.id);
    const versionsRoot = resolve(pluginRoot, "versions");
    const finalVersionRoot = resolve(versionsRoot, descriptor.version);
    try {
      await stat(finalVersionRoot);
      await atomicWrite(resolve(pluginRoot, "pending"), `${descriptor.version}\n`);
      return Object.freeze({
        copiedFiles: 0,
        descriptor,
        hardlinkedFiles: 0,
        pendingActivation: true,
        reusedVersion: true,
        skippedOptionalDependencies: 0,
      });
    } catch (error) {
      if (!isNodeError(error, "ENOENT")) throw error;
    }

    let copiedFiles = 0;
    let hardlinkedFiles = 0;
    let skippedOptionalDependencies = 0;
    for (const dependency of dependencies) {
      const destination = resolveInside(stagingRoot, dependency.installPath);
      try {
        let source: string;
        if (dependency.kind === "registry") {
          source = await this.#dependencyStore.ensureRegistryPackage(dependency);
        } else {
          source = resolveInside(stagingRoot, dependency.sourcePath!);
          await rejectLocalNativeFiles(source);
        }
        const materialized = await this.#dependencyStore.materializePackage(
          source,
          destination,
        );
        copiedFiles += materialized.copiedFiles;
        hardlinkedFiles += materialized.hardlinkedFiles;
      } catch (error) {
        if (
          dependency.optional &&
          (error instanceof DependencyStoreError ||
            error instanceof PluginPackageError ||
            isNodeError(error, "ENOENT"))
        ) {
          skippedOptionalDependencies += 1;
          continue;
        }
        throw error;
      }
    }

    await mkdir(versionsRoot, { recursive: true });
    await rename(stagingRoot, finalVersionRoot);
    // Android's app sandbox can reject renaming a directory whose root was
    // chmod-ed read-only while it still lives under the staging tree. Commit
    // the atomic directory move first, then enforce immutability at its final
    // location before publishing the pending pointer.
    await makeVersionTreeReadOnly(finalVersionRoot);
    await atomicWrite(resolve(pluginRoot, "pending"), `${descriptor.version}\n`);
    return Object.freeze({
      copiedFiles,
      descriptor,
      hardlinkedFiles,
      pendingActivation: true,
      reusedVersion: false,
      skippedOptionalDependencies,
    });
  }
}

async function rejectLocalNativeFiles(root: string): Promise<void> {
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) {
      throw new PluginPackageError("plugin_package_invalid");
    }
    const path = resolve(root, entry.name);
    if (entry.isDirectory()) {
      await rejectLocalNativeFiles(path);
      continue;
    }
    if (!entry.isFile()) {
      throw new PluginPackageError("plugin_package_invalid");
    }
    const lower = entry.name.toLowerCase();
    if (
      lower.endsWith(".node") ||
      lower.endsWith(".dll") ||
      lower.endsWith(".so") ||
      lower === "binding.gyp"
    ) {
      throw new PluginPackageError("plugin_native_dependency_unsupported");
    }
  }
}

async function makeVersionTreeReadOnly(root: string): Promise<void> {
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = resolve(root, entry.name);
    if (entry.isDirectory()) {
      await makeVersionTreeReadOnly(path);
      await chmod(path, 0o555).catch(() => {});
    } else if (entry.isFile()) {
      await chmod(path, 0o444).catch(() => {});
    }
  }
  await chmod(root, 0o555).catch(() => {});
}

async function atomicWrite(path: string, value: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.next-${randomUUID()}`;
  await writeFile(temporary, value, { flag: "wx", mode: 0o600 });
  try {
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true }).catch(() => {});
  }
}

function assertPluginId(pluginId: string): void {
  if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)+$/.test(pluginId)) {
    throw new PluginPackageError("plugin_package_invalid");
  }
}

function isNodeError(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === code
  );
}
