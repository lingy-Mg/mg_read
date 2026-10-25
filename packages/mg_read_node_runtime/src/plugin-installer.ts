/**
 * Runtime 双 artifact 安装器。
 * 职责：将 archive/single-file 归一化为同一不可变版本树并维护 pending 事务。
 * 注意：安装不执行插件代码、npm 或 lifecycle script，原始 artifact 仅保存在 Runtime 私有目录。
 */
import { randomUUID } from "node:crypto";
import {
  access,
  chmod,
  copyFile,
  constants as fsConstants,
  mkdir,
  readdir,
  rename,
  rm,
  stat,
} from "node:fs/promises";
import { resolve } from "node:path";

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
  type PluginPackageDescriptor,
  PluginPackageError,
  readPluginProject,
} from "./plugin-package.js";
import { InstalledPluginCatalog } from "./plugin-catalog.js";

/** Stable event names for installer ownership and exactly-one terminal checks. */
export type PluginInstallerEventCode =
  | "plugin_install_completed"
  | "plugin_install_failed"
  | "plugin_install_started"
  | "plugin_uninstall_scheduled";

export interface PluginInstallerEvent {
  readonly code: PluginInstallerEventCode;
  readonly durationMs?: number;
  readonly outcome: "error" | "started" | "success";
  readonly pluginId?: string;
}

export type PluginInstallerEventSink = (event: PluginInstallerEvent) => void;

/** Result of a complete immutable-version install transaction. */
export interface PluginInstallResult {
  readonly descriptor: PluginPackageDescriptor;
  readonly pendingActivation: true;
  readonly reusedVersion: boolean;
}

/** Runtime-owned standard-project installer. */
export class PluginInstaller {
  readonly #catalog: InstalledPluginCatalog;
  readonly #dataRoot: string;
  readonly #events: PluginInstallerEventSink;

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly events?: PluginInstallerEventSink;
      readonly onProgress?: DesktopRuntimeProgressSink;
      readonly catalog?: InstalledPluginCatalog;
    } = {},
  ) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#catalog = options.catalog ?? new InstalledPluginCatalog(this.#dataRoot);
    this.#events = options.events ?? (() => {});
    this.#onProgress = options.onProgress ?? (() => {});
  }

  readonly #onProgress: DesktopRuntimeProgressSink;

  async #preserveOriginalArtifact(
    artifactFile: string,
    descriptor: PluginPackageDescriptor,
    format: PluginArtifactFormat,
    replaceExistingVersion: boolean,
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
      if (!replaceExistingVersion) return;
      // Windows cannot replace a read-only destination through rename.
      await chmod(target, 0o644);
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
        if (replaceExistingVersion || !isNodeError(error, "EEXIST")) throw error;
        // Another serialized install already preserved this immutable version.
      }
    } finally {
      await rm(temporary, { force: true }).catch(() => {});
    }
  }

  async installArtifact(artifactFile: string, options: { readonly replaceExistingVersion?: boolean } = {}): Promise<PluginInstallResult> {
    const replaceExistingVersion = options.replaceExistingVersion ?? false;
    if (artifactFile.endsWith(".mgplugin.js")) return this.#installArtifact(artifactFile, "singleFile", replaceExistingVersion);
    if (artifactFile.endsWith(".mgplugin")) return this.#installArtifact(artifactFile, "archive", replaceExistingVersion);
    throw new PluginPackageError("plugin_package_invalid");
  }

  /** Installs a `.mgplugin` as an immutable version and writes `pending`. */
  async installArchive(archiveFile: string): Promise<PluginInstallResult> {
    return this.#installArtifact(archiveFile, "archive", false);
  }

  async installSingleFile(artifactFile: string): Promise<PluginInstallResult> {
    return this.#installArtifact(artifactFile, "singleFile", false);
  }

  async #installArtifact(artifactFile: string, format: PluginArtifactFormat, replaceExistingVersion: boolean): Promise<PluginInstallResult> {
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
        detail: "正在解压并校验数据源插件包",
        stage: "plugin_installing",
        totalBytes: 0,
      });
      if (format === "singleFile") await materializePluginSingleFile(artifactFile, stagingRoot);
      else await extractPluginArchive(artifactFile, stagingRoot);
      const project = await readPluginProject(stagingRoot);
      const descriptor = project.descriptor;
      this.#reportProgress({
        completedBytes: 0,
        detail: "已验证数据源插件包",
        stage: "plugin_installing",
        totalBytes: 1,
      });
      // The platform inbox is only a hand-off queue and is deleted after the
      // install completes. Keep the validated input archive in Runtime-owned
      // storage for later recovery/export without crossing the Facade.
      const result = await this.#commitProject(
        stagingRoot,
        descriptor,
        replaceExistingVersion,
        () => this.#preserveOriginalArtifact(artifactFile, descriptor, format, replaceExistingVersion),
      );
      this.#events({
        code: "plugin_install_completed",
        durationMs: performance.now() - startedAt,
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
      const descriptor = (await readPluginProject(projectRoot)).descriptor;
      if (descriptor.packageMode === "single-file") {
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
    await this.#catalog.load();
    await this.#catalog.scheduleRemoval(pluginId);
    this.#events({
      code: "plugin_uninstall_scheduled",
      outcome: "success",
      pluginId,
    });
  }

  /** Enables/disables future dispatch without hot-unloading imported modules. */
  async setEnabled(pluginId: string, enabled: boolean): Promise<void> {
    assertPluginId(pluginId);
    await this.#catalog.load();
    await this.#catalog.setEnabled(pluginId, enabled);
  }

  async #commitProject(
    stagingRoot: string,
    descriptor: PluginPackageDescriptor,
    replaceExistingVersion: boolean,
    preserveArtifact: () => Promise<void>,
  ): Promise<PluginInstallResult> {
    const pluginRoot = resolve(this.#dataRoot, "plugins", descriptor.id);
    const versionsRoot = resolve(pluginRoot, "versions");
    const finalVersionRoot = resolve(versionsRoot, descriptor.version);
    let existingVersion = false;
    try {
      await stat(finalVersionRoot);
      existingVersion = true;
    } catch (error) {
      if (!isNodeError(error, "ENOENT")) throw error;
    }
    if (existingVersion && !replaceExistingVersion) {
      this.#reportProgress({
        completedBytes: 1,
        detail: "数据源插件版本已存在，复用已安装版本",
        stage: "plugin_installing",
        totalBytes: 1,
      });
      await preserveArtifact();
      await this.#catalog.load();
      await this.#catalog.installPending(descriptor, async () => {});
      return Object.freeze({
        descriptor,
        pendingActivation: true,
        reusedVersion: true,
      });
    }

    await this.#catalog.load();
    await this.#catalog.installPending(descriptor, async () => {
      await mkdir(versionsRoot, { recursive: true });
      let previousVersionRoot: string | undefined;
      let previousVersionMoved = false;
      let newVersionMoved = false;
      try {
        if (existingVersion) {
          previousVersionRoot = resolve(versionsRoot, `.${descriptor.version}.replaced-${randomUUID()}`);
          await rename(finalVersionRoot, previousVersionRoot);
          previousVersionMoved = true;
        }
        await rename(stagingRoot, finalVersionRoot);
        newVersionMoved = true;
        // Android requires the directory move before enforcing immutability.
        // Keep the previous tree until both the code and export artifact commit.
        await makeVersionTreeReadOnly(finalVersionRoot);
        await preserveArtifact();
      } catch (error) {
        if (newVersionMoved) await rm(finalVersionRoot, {force: true, recursive: true}).catch(() => {});
        if (previousVersionMoved && previousVersionRoot !== undefined) {
          await rename(previousVersionRoot, finalVersionRoot).catch(() => {});
        }
        throw error;
      }
      if (previousVersionRoot !== undefined) {
        await rm(previousVersionRoot, { force: true, recursive: true }).catch(() => {});
      }
    });
    this.#reportProgress({
      completedBytes: 1,
      detail: "自包含数据源插件安装完成",
      stage: "plugin_installing",
      totalBytes: 1,
    });
    return Object.freeze({
      descriptor,
      pendingActivation: true,
      reusedVersion: false,
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

async function makeVersionTreeReadOnly(root: string): Promise<void> {
  // POSIX removal requires write permission on each parent directory. Keep
  // installed files immutable while allowing the Runtime owner to replace or
  // uninstall directory entries; Windows does not use POSIX mode enforcement.
  const directoryMode = process.platform === "win32" ? 0o555 : 0o755;
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = resolve(root, entry.name);
    if (entry.isDirectory()) {
      await makeVersionTreeReadOnly(path);
      await chmod(path, directoryMode).catch(() => {});
    } else if (entry.isFile()) {
      await chmod(path, 0o444).catch(() => {});
    }
  }
  await chmod(root, directoryMode).catch(() => {});
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
