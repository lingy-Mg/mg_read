/**
 * Runtime 双 artifact 安装器。
 * 职责：将 archive/single-file 归一化为同一不可变版本树并维护 pending/依赖事务。
 * 注意：安装不执行插件代码、npm 或 lifecycle script，原始 artifact 仅保存在 Runtime 私有目录。
 * TODO: - 无。
 */
import { randomUUID } from "node:crypto";
import {
  access,
  chmod,
  copyFile,
  constants as fsConstants,
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
import type {
  DesktopRuntimeProgress,
  DesktopRuntimeProgressSink,
} from "./desktop-runtime.js";
import {
  createPluginArchive,
  extractPluginArchive,
} from "./plugin-archive.js";
import {
  createPluginSingleFile,
  materializePluginSingleFile,
  type PluginArtifactFormat,
} from "./plugin-single-file.js";
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
      readonly onProgress?: DesktopRuntimeProgressSink;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#dependencyStore =
      options.dependencyStore ?? new DependencyStore(this.#dataRoot);
    this.#events = options.events ?? (() => {});
    this.#onProgress = options.onProgress ?? (() => {});
  }

  readonly #onProgress: DesktopRuntimeProgressSink;

  async #preserveOriginalArtifact(
    artifactFile: string,
    descriptor: PluginPackageDescriptor,
    format: PluginArtifactFormat,
  ): Promise<void> {
    const archiveRoot = resolve(
      this.#dataRoot,
      "plugin-archives",
      descriptor.id,
    );
    const extension = format === "singleFile" ? ".mgplugin.js" : ".mgplugin";
    const target = resolve(archiveRoot, `${descriptor.version}${extension}`);
    try {
      await access(target);
      return;
    } catch (error) {
      if (!isNodeError(error, "ENOENT")) throw error;
    }

    await mkdir(archiveRoot, { recursive: true });
    const temporary = resolve(
      archiveRoot,
      `.${descriptor.version}-${randomUUID()}${extension}.part`,
    );
    try {
      await copyFile(artifactFile, temporary, fsConstants.COPYFILE_EXCL);
      try {
        await rename(temporary, target);
      } catch (error) {
        if (!isNodeError(error, "EEXIST")) throw error;
        // Another serialized install already preserved this immutable version.
      }
    } finally {
      await rm(temporary, { force: true }).catch(() => {});
    }
  }

  async installArtifact(artifactFile: string): Promise<PluginInstallResult> {
    if (artifactFile.endsWith(".mgplugin.js")) return this.#installArtifact(artifactFile, "singleFile");
    if (artifactFile.endsWith(".mgplugin")) return this.#installArtifact(artifactFile, "archive");
    throw new PluginPackageError("plugin_package_invalid");
  }

  /** Installs a `.mgplugin` as an immutable version and writes `pending`. */
  async installArchive(archiveFile: string): Promise<PluginInstallResult> {
    return this.#installArtifact(archiveFile, "archive");
  }

  async installSingleFile(artifactFile: string): Promise<PluginInstallResult> {
    return this.#installArtifact(artifactFile, "singleFile");
  }

  async #installArtifact(artifactFile: string, format: PluginArtifactFormat): Promise<PluginInstallResult> {
    const startedAt = performance.now();
    this.#events({ code: "plugin_install_started", outcome: "started" });
    const stagingRoot = resolve(
      this.#dataRoot,
      "staging",
      `plugin-install-${randomUUID()}`,
    );
    try {
      await mkdir(stagingRoot, { recursive: true });
      this.#reportProgress({
        completedBytes: 0,
        detail: "正在解压并校验数据来源包",
        stage: "plugin_installing",
        totalBytes: 0,
      });
      if (format === "singleFile") await materializePluginSingleFile(artifactFile, stagingRoot);
      else await extractPluginArchive(artifactFile, stagingRoot);
      const project = await readPluginProject(stagingRoot);
      const requiresNpmDependencies = format !== "singleFile";
      // A single-file artifact materializes into an empty dependency graph.
      // Local install and LAN-sync therefore share the same npm-free behavior.
      if (!requiresNpmDependencies && project.dependencies.length !== 0) {
        throw new PluginPackageError("plugin_lock_invalid");
      }
      this.#reportProgress({
        completedBytes: 0,
        detail: requiresNpmDependencies
          ? `已读取 package.json 和 package-lock.json，共 ${project.dependencies.length} 个 npm 依赖`
          : "已验证单文件数据来源，npm 依赖已打包，无需安装",
        stage: "plugin_installing",
        totalBytes: requiresNpmDependencies ? Math.max(project.dependencies.length, 1) : 1,
      });
      // The platform inbox is only a hand-off queue and is deleted after the
      // install completes. Keep the validated input archive in Runtime-owned
      // storage for later recovery/export without crossing the Facade.
      await this.#preserveOriginalArtifact(artifactFile, project.descriptor, format);
      const result = await this.#commitProject(
        stagingRoot,
        project.descriptor,
        project.dependencies,
        requiresNpmDependencies,
      );
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
    await mkdir(stagingDirectory, { recursive: true });
    try {
      const project = await readPluginProject(projectRoot);
      if (project.descriptor.packageMode === "single-file") {
        const artifact = resolve(stagingDirectory, "plugin.mgplugin.js");
        await createPluginSingleFile(projectRoot, artifact);
        return await this.installSingleFile(artifact);
      }
      const artifact = resolve(stagingDirectory, "plugin.mgplugin");
      await createPluginArchive(projectRoot, artifact);
      return await this.installArchive(artifact);
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
    const quarantine = resolve(this.#dataRoot, "plugins", pluginId, "quarantined");
    if (enabled) {
      await rm(marker, { force: true });
      // Explicit user re-enable is also an explicit retry request. A later
      // valid cold-activated update clears this marker on its own.
      await rm(quarantine, { force: true });
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
    requiresNpmDependencies: boolean,
  ): Promise<PluginInstallResult> {
    const pluginRoot = resolve(this.#dataRoot, "plugins", descriptor.id);
    const versionsRoot = resolve(pluginRoot, "versions");
    const finalVersionRoot = resolve(versionsRoot, descriptor.version);
    try {
      await stat(finalVersionRoot);
      this.#reportProgress({
        completedBytes: 1,
        detail: requiresNpmDependencies
          ? "数据来源版本已存在，复用已安装的 npm 依赖"
          : "单文件数据来源版本已存在，无需安装 npm 依赖",
        stage: "plugin_installing",
        totalBytes: 1,
      });
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
    const dependencyTotal = Math.max(dependencies.length, 1);
    let dependencyIndex = 0;
    for (const dependency of requiresNpmDependencies ? dependencies : []) {
      dependencyIndex += 1;
      const destination = resolveInside(stagingRoot, dependency.installPath);
      try {
        let source: string;
        if (dependency.kind === "registry") {
          const reused = await this.#dependencyStore.hasRegistryPackage(dependency);
          this.#reportProgress({
            completedBytes: dependencyIndex - 1,
            detail: `${reused ? "正在复用" : "正在下载并校验"} npm 依赖 ${dependencyLabel(dependency)}（${dependencyIndex}/${dependencies.length}）`,
            stage: "plugin_installing",
            totalBytes: dependencyTotal,
          });
          source = await this.#dependencyStore.ensureRegistryPackage(dependency);
        } else {
          this.#reportProgress({
            completedBytes: dependencyIndex - 1,
            detail: `正在准备本地 npm 依赖 ${dependencyLabel(dependency)}（${dependencyIndex}/${dependencies.length}）`,
            stage: "plugin_installing",
            totalBytes: dependencyTotal,
          });
          source = resolveInside(stagingRoot, dependency.sourcePath!);
          await rejectLocalNativeFiles(source);
        }
        const materialized = await this.#dependencyStore.materializePackage(
          source,
          destination,
        );
        copiedFiles += materialized.copiedFiles;
        hardlinkedFiles += materialized.hardlinkedFiles;
        this.#reportProgress({
          completedBytes: dependencyIndex,
          detail: `npm 依赖已就绪 ${dependencyLabel(dependency)}（${dependencyIndex}/${dependencies.length}）`,
          stage: "plugin_installing",
          totalBytes: dependencyTotal,
        });
      } catch (error) {
        if (
          dependency.optional &&
          (error instanceof DependencyStoreError ||
            error instanceof PluginPackageError ||
            isNodeError(error, "ENOENT"))
        ) {
          skippedOptionalDependencies += 1;
          this.#reportProgress({
            completedBytes: dependencyIndex,
            detail: `可选 npm 依赖跳过 ${dependencyLabel(dependency)}（${dependencyIndex}/${dependencies.length}）`,
            stage: "plugin_installing",
            totalBytes: dependencyTotal,
          });
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
    this.#reportProgress({
      completedBytes: dependencyTotal,
      detail: requiresNpmDependencies
        ? "npm 依赖恢复完成，正在完成数据来源安装"
        : "单文件数据来源安装完成，无需安装 npm 依赖",
      stage: "plugin_installing",
      totalBytes: dependencyTotal,
    });
    return Object.freeze({
      copiedFiles,
      descriptor,
      hardlinkedFiles,
      pendingActivation: true,
      reusedVersion: false,
      skippedOptionalDependencies,
    });
  }

  #reportProgress(progress: DesktopRuntimeProgress): void {
    try {
      this.#onProgress(progress);
    } catch {
      // Progress reporting is observational and must never change install results.
    }
  }
}

function dependencyLabel(dependency: LockedPluginDependency): string {
  const label = dependency.installPath.replace(/^node_modules[\\/]/, "");
  return `${label.slice(0, 96)}@${dependency.version.slice(0, 64)}`;
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
