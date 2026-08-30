/**
 * Runtime 已安装插件 artifact/data/npm 用量统计。
 * 职责：解析兼容双格式的原始 artifact 路径并递归计算受控字节与文件数。
 * 注意：结果仅为 path-free 数值投影，data 统计排除 node_modules。
 */
import { lstat, readdir } from "node:fs/promises";
import { resolve } from "node:path";

import { PluginManagerError } from "./plugin-manager-contract.js";

export type PluginInstallationUsageScope = "archive" | "data" | "npm";

export async function retainedArtifactPath(dataRoot: string, pluginId: string, version: string): Promise<string> {
  const root = resolve(dataRoot, "plugin-archives", pluginId);
  const singleFile = resolve(root, `${version}.mgplugin.js`);
  try { await lstat(singleFile); return singleFile; }
  catch (error) { if (!isMissing(error)) throw error; }
  return resolve(root, `${version}.mgplugin`);
}

export async function measureInstallationTree(
  path: string,
  scope: PluginInstallationUsageScope,
): Promise<{ readonly bytes: number; readonly fileCount: number }> {
  let metadata;
  try { metadata = await lstat(path); }
  catch (error) { if (isMissing(error)) return { bytes: 0, fileCount: 0 }; throw error; }
  if (!metadata.isDirectory()) return { bytes: metadata.size, fileCount: 1 };
  let bytes = 0;
  let fileCount = 0;
  for (const entry of await readdir(path, { withFileTypes: true })) {
    if (scope === "data" && entry.name === "node_modules") continue;
    const child = await measureInstallationTree(resolve(path, entry.name), scope);
    bytes += child.bytes;
    fileCount += child.fileCount;
    if (!Number.isSafeInteger(bytes) || !Number.isSafeInteger(fileCount)) throw new PluginManagerError("plugin_load_failed");
  }
  return { bytes, fileCount };
}

function isMissing(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT";
}
