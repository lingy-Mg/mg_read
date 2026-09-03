/**
 * Runtime 冷启动 artifact inbox 与内置种子协调器。
 *
 * 职责：
 * - 从 Runtime 私有 inbox 安装 `.mgplugin.js` 和兼容 `.mgplugin`。
 * - 按已安装 marker 对内置 artifact 执行幂等冷启动协调。
 *
 * 注意：
 * - 输入数量和单 artifact 大小有界，处理后一次性清理 inbox 文件。
 * - 处理结果由 Runtime 统一返回。
 *
 */
import { mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import { resolve } from "node:path";

import type { DesktopRuntimeProgressSink } from "./desktop-runtime.js";
import { PluginInstaller } from "./plugin-installer.js";
import { MAX_PLUGIN_ARTIFACT_BYTES } from "./plugin-single-file.js";

interface BundledPluginArtifact {
  readonly path: string;
  readonly pluginId: string;
  readonly version: string;
}

interface BundledPluginMarkers {
  readonly currentVersion: string | null;
  readonly disabled: boolean;
  readonly pendingVersion: string | null;
  readonly uninstallPending: boolean;
}

/** Installs new immutable bundled artifacts without overriding user markers. */
export async function seedBundledPluginArtifacts(
  dataRoot: string,
  bundledPluginRoot: string | undefined,
  onProgress: DesktopRuntimeProgressSink,
): Promise<void> {
  if (bundledPluginRoot === undefined) return;
  const pluginsRoot = resolve(dataRoot, "plugins");
  await mkdir(pluginsRoot, { recursive: true });
  const artifacts = (await readdir(bundledPluginRoot, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && isArtifactFileName(entry.name))
    .map((entry) => parseBundledPluginArtifact(entry.name, bundledPluginRoot))
    .sort((left, right) => left.path.localeCompare(right.path));
  if (artifacts.length === 0) throw new Error("Runtime bundled plugin assets are unavailable.");
  const installer = new PluginInstaller(dataRoot, { onProgress });
  for (const artifact of artifacts) {
    const markers = await readBundledPluginMarkers(resolve(pluginsRoot, artifact.pluginId));
    if (markers.disabled || markers.uninstallPending ||
        markers.currentVersion === artifact.version || markers.pendingVersion === artifact.version) continue;
    await installer.installArtifact(artifact.path);
  }
}

/** Installs and consumes every bounded artifact handed off by a platform adapter. */
export async function installPluginArtifactInbox(
  dataRoot: string,
  inboxRoot: string | undefined,
  onProgress: DesktopRuntimeProgressSink,
): Promise<void> {
  if (inboxRoot === undefined) return;
  await mkdir(inboxRoot, { recursive: true });
  const artifacts = (await readdir(inboxRoot, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && /^[a-zA-Z0-9._-]+\.mgplugin(?:\.js)?$/.test(entry.name))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (artifacts.length > 32) throw new Error("Runtime plugin import inbox is over budget.");
  const installer = new PluginInstaller(dataRoot, { onProgress });
  for (const artifact of artifacts) {
    const path = resolve(inboxRoot, artifact.name);
    const metadata = await stat(path);
    if (!metadata.isFile() || metadata.size <= 0 || metadata.size > MAX_PLUGIN_ARTIFACT_BYTES) {
      throw new Error("Runtime plugin import artifact is over budget.");
    }
    try {
      await installer.installArtifact(path);
      await rm(path, { force: true });
    } catch (error) {
      await rm(path, { force: true }).catch(() => {});
      throw error;
    }
  }
}

function parseBundledPluginArtifact(name: string, root: string): BundledPluginArtifact {
  const match = /^([a-z0-9][a-z0-9.-]*)-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\.mgplugin(?:\.js)?$/.exec(name);
  if (match === null) throw new Error("Runtime bundled plugin artifact name is invalid.");
  return Object.freeze({ path: resolve(root, name), pluginId: match[1]!, version: match[2]! });
}

async function readBundledPluginMarkers(pluginRoot: string): Promise<BundledPluginMarkers> {
  let names: ReadonlySet<string>;
  try {
    names = new Set((await readdir(pluginRoot, { withFileTypes: true })).map((entry) => entry.name));
  } catch (error) {
    if (isMissingFile(error)) return Object.freeze({
      currentVersion: null,
      disabled: false,
      pendingVersion: null,
      uninstallPending: false,
    });
    throw error;
  }
  return Object.freeze({
    currentVersion: await readVersionMarker(pluginRoot, "current", names),
    disabled: names.has("disabled"),
    pendingVersion: await readVersionMarker(pluginRoot, "pending", names),
    uninstallPending: names.has("uninstall-pending"),
  });
}

async function readVersionMarker(pluginRoot: string, name: string, names: ReadonlySet<string>): Promise<string | null> {
  if (!names.has(name)) return null;
  const value = (await readFile(resolve(pluginRoot, name), "utf8")).trim();
  return value.length === 0 ? null : value;
}

function isArtifactFileName(name: string): boolean {
  return name.endsWith(".mgplugin") || name.endsWith(".mgplugin.js");
}

function isMissingFile(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === "object" && error !== null && "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT";
}
