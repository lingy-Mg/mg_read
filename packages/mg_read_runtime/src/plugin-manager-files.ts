/**
 * 插件管理器的文件与模块校验工具。
 *
 * 职责：
 * - 归一化插件导出、生成开发目录指纹并执行受控原子文件操作。
 *
 * 注意：
 * - 不启动第二个 VM 或执行安装脚本。
 *
 */
import { createHash, randomUUID } from "node:crypto";
import { access, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

import type { PluginPackageDescriptor } from "./plugin-package.js";
import {
  PluginManagerError,
  type InstalledPluginSnapshot,
  type LoadedPluginModule,
  type PluginContentFunction,
} from "./plugin-manager-contract.js";

export function normalizePluginModule(imported: Record<string, unknown>): LoadedPluginModule | undefined {
  const activate = imported.activate;
  const discover = imported.discover;
  const search = imported.search;
  const searchSuggestions = imported.searchSuggestions;
  const resource = imported.resource;
  const getDetail = imported.getDetail;
  const getChapters = imported.getChapters;
  const getContent = imported.getContent;
  if (
    typeof activate !== "function" ||
    typeof discover !== "function" ||
    typeof search !== "function" ||
    typeof getDetail !== "function" ||
    typeof getChapters !== "function" ||
    typeof getContent !== "function"
  ) {
    return undefined;
  }
  return Object.freeze({
    activate: activate as LoadedPluginModule["activate"],
    discover: discover as PluginContentFunction,
    getChapters: getChapters as PluginContentFunction,
    getContent: getContent as PluginContentFunction,
    getDetail: getDetail as PluginContentFunction,
    search: search as PluginContentFunction,
    // Popular search is an opt-in v1 extension. Older source packages remain
    // valid and project an empty source-owned list rather than local defaults.
    searchSuggestions: typeof searchSuggestions === "function"
      ? searchSuggestions as PluginContentFunction
      : () => ({ items: [], nextCursor: null }),
    resource: typeof resource === "function" ? resource as PluginContentFunction : async () => ({ status: 404, body: "" }),
  });
}

export function snapshotFrom(
  descriptor: PluginPackageDescriptor | undefined,
  pluginId: string,
  activeVersion: string | null,
  pendingVersion: string | null,
  enabled: boolean,
  status: InstalledPluginSnapshot["status"],
): InstalledPluginSnapshot {
  return Object.freeze({
    activeVersion,
    contentKinds: Object.freeze(descriptor?.contentKinds ?? []),
    description: descriptor?.description ?? null,
    displayName: descriptor?.displayName ?? pluginId,
    enabled,
    id: pluginId,
    iconUrl: null,
    name: descriptor?.name ?? pluginId,
    pendingVersion,
    status,
  });
}

export function enabledStatus(
  snapshot: InstalledPluginSnapshot,
): InstalledPluginSnapshot["status"] {
  if (snapshot.activeVersion !== null) return "active";
  if (snapshot.pendingVersion !== null) return "pending";
  return "damaged";
}

/** Replaces one installed snapshot after a persisted enable/disable operation. */
export function withEnabledPluginSnapshot(
  snapshots: readonly InstalledPluginSnapshot[],
  index: number,
  enabled: boolean,
): { readonly snapshots: readonly InstalledPluginSnapshot[]; readonly updated: InstalledPluginSnapshot } {
  const current = snapshots[index]!;
  const updated = Object.freeze({
    activeVersion: current.activeVersion, contentKinds: current.contentKinds,
    description: current.description, displayName: current.displayName, enabled,
    id: current.id, iconUrl: current.iconUrl, name: current.name,
    pendingVersion: current.pendingVersion, status: enabled ? enabledStatus(current) : "disabled",
  } satisfies InstalledPluginSnapshot);
  return Object.freeze({
    snapshots: Object.freeze([...snapshots.slice(0, index), updated, ...snapshots.slice(index + 1)]),
    updated,
  });
}

/** Removes every Runtime-owned storage root belonging to one uninstalled source. */
export function removePluginStorage(dataRoot: string, pluginId: string): Promise<unknown[]> {
  return Promise.all(["plugins", "plugin-archives", "plugin-cache", "plugin-data"].map((root) =>
    rm(resolve(dataRoot, root, pluginId), { force: true, recursive: true })
  ));
}

export async function developmentProjectFingerprint(projectRoot: string): Promise<string> {
  const paths = ["package.json"];
  if (await exists(resolve(projectRoot, "package-lock.json"))) {
    paths.push("package-lock.json");
  }
  for (const directory of ["dist", "assets", "packages", "tools"]) {
    await collectDevelopmentFiles(projectRoot, directory, paths);
  }
  paths.sort((left, right) => left.localeCompare(right));
  if (paths.length > 4_096) throw new PluginManagerError("plugin_load_failed");
  const hash = createHash("sha256");
  let totalBytes = 0;
  for (const path of paths) {
    const bytes = await readFile(resolve(projectRoot, path));
    totalBytes += bytes.byteLength;
    if (totalBytes > 32 * 1024 * 1024) {
      throw new PluginManagerError("plugin_load_failed");
    }
    hash.update(path.replaceAll("\\", "/"));
    hash.update("\0");
    hash.update(bytes);
    hash.update("\0");
  }
  return hash.digest("hex");
}

export async function collectDevelopmentFiles(
  projectRoot: string,
  relativeDirectory: string,
  paths: string[],
): Promise<void> {
  const directory = resolve(projectRoot, relativeDirectory);
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (isMissingPath(error) && relativeDirectory !== "dist") return;
    throw error;
  }
  for (const entry of entries) {
    const child = `${relativeDirectory}/${entry.name}`;
    if (entry.isDirectory()) {
      await collectDevelopmentFiles(projectRoot, child, paths);
    } else if (entry.isFile()) {
      paths.push(child);
    } else {
      throw new PluginManagerError("plugin_load_failed");
    }
  }
}

export function isMissingPath(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === "object" && error !== null && "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT";
}

export async function readVersionPointer(path: string): Promise<string | null> {
  try {
    const value = (await readFile(path, "utf8")).trim();
    return /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/.test(value)
      ? value
      : null;
  } catch {
    return null;
  }
}

export async function atomicWrite(path: string, value: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.next-${randomUUID()}`;
  await writeFile(temporary, value, { flag: "wx", mode: 0o600 });
  try {
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true }).catch(() => {});
  }
}

export async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

export function isPluginId(value: string): boolean {
  return /^[a-z0-9]+(?:[.-][a-z0-9]+)+$/.test(value);
}
