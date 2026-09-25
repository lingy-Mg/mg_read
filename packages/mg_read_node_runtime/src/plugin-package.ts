/**
 * 标准插件项目元数据校验。
 *
 * 职责：解析 package.json.mgread v1。发布 artifact 已在构建期内联外部依赖，
 * Runtime 安装契约只包含自包含的插件文件与 descriptor。
 */
import { access, lstat, readFile } from "node:fs/promises";
import { isAbsolute, resolve, sep } from "node:path";

import { nodeVersionByBackend, supportedPluginNodeRange } from "./runtime-version.js";

/** MgRead metadata schema supported by this Runtime release. */
export const pluginPackageSchemaVersion = 1;

/** MgRead plugin API major supported by this Runtime release. */
export const pluginApiVersion = 1;

/** Content kinds accepted in package.json.mgread v1. */
export type PluginContentKind = "audio" | "manga" | "novel" | "video";
export type PluginPackageMode = "archive" | "single-file";

/** Stable failure raised while validating a standard Node plugin project. */
export class PluginPackageError extends Error {
  constructor(
    readonly code:
      | "plugin_entry_missing"
      | "plugin_package_invalid"
      | "plugin_package_legacy_unsupported",
  ) {
    super("The MgRead plugin package is invalid or unsupported.");
    this.name = "PluginPackageError";
  }
}

/** Validated public metadata read only from package.json. */
export interface PluginPackageDescriptor {
  readonly contentKinds: readonly PluginContentKind[];
  readonly description?: string;
  readonly displayName: string;
  readonly entry: string;
  readonly id: string;
  readonly icon?: string;
  readonly name: string;
  readonly packageMode: PluginPackageMode;
  readonly pluginApi: typeof pluginApiVersion;
  readonly projectRoot: string;
  readonly version: string;
}

/** Reads and validates package metadata for a standard plugin project. */
export interface ValidatedPluginProject {
  readonly descriptor: PluginPackageDescriptor;
  readonly packageJson: Readonly<Record<string, unknown>>;
}

export async function readPluginProject(
  projectRoot: string,
): Promise<ValidatedPluginProject> {
  const normalizedRoot = resolve(projectRoot);
  const packagePath = resolve(normalizedRoot, "package.json");
  try {
    await access(packagePath);
  } catch {
    try {
      await access(resolve(normalizedRoot, "manifest.json"));
      throw new PluginPackageError("plugin_package_legacy_unsupported");
    } catch (error) {
      if (error instanceof PluginPackageError) {
        throw error;
      }
      throw new PluginPackageError("plugin_package_invalid");
    }
  }

  const packageJson = await readJsonObject(
    packagePath,
    "plugin_package_invalid",
  );
  const descriptor = parsePluginPackageDescriptor(packageJson, normalizedRoot);
  try {
    await access(resolve(normalizedRoot, ...descriptor.entry.split("/")));
  } catch {
    throw new PluginPackageError("plugin_entry_missing");
  }
  if (descriptor.icon !== undefined) {
    try {
      const icon = await lstat(resolveInside(normalizedRoot, descriptor.icon));
      if (!icon.isFile() || icon.isSymbolicLink() || icon.size <= 0 || icon.size > 256 * 1024) throw new Error("invalid icon");
    } catch {
      throw new PluginPackageError("plugin_package_invalid");
    }
  }

  return Object.freeze({
    descriptor,
    packageJson: Object.freeze(packageJson),
  });
}

/** Validates one plugin relative path and returns normalized `/` form. */
export function normalizePluginRelativePath(value: string): string {
  if (
    value.length === 0 ||
    value.includes("\\") ||
    value.includes("\0") ||
    value.startsWith("/") ||
    /^[A-Za-z]:/.test(value) ||
    isAbsolute(value)
  ) {
    throw new PluginPackageError("plugin_package_invalid");
  }
  const parts = value.split("/");
  if (parts.some((part) => part.length === 0 || part === "." || part === "..")) {
    throw new PluginPackageError("plugin_package_invalid");
  }
  return parts.join("/");
}

/** Resolves a previously validated relative path and proves containment. */
export function resolveInside(root: string, relativePath: string): string {
  const normalized = normalizePluginRelativePath(relativePath);
  const absolute = resolve(root, ...normalized.split("/"));
  const prefix = `${resolve(root)}${sep}`;
  if (!absolute.startsWith(prefix)) {
    throw new PluginPackageError("plugin_package_invalid");
  }
  return absolute;
}

async function readJsonObject(
  path: string,
  code: PluginPackageError["code"],
): Promise<Record<string, unknown>> {
  try {
    const value = JSON.parse(await readFile(path, "utf8")) as unknown;
    if (!isRecord(value)) {
      throw new Error("JSON root must be an object.");
    }
    return value;
  } catch (error) {
    if (error instanceof PluginPackageError) {
      throw error;
    }
    throw new PluginPackageError(code);
  }
}

export function parsePluginPackageDescriptor(
  packageJson: Record<string, unknown>,
  projectRoot: string,
): PluginPackageDescriptor {
  const name = packageJson.name;
  const version = packageJson.version;
  const entry = packageJson.main;
  const engines = packageJson.engines;
  const mgread = packageJson.mgread;
  if (
    typeof name !== "string" ||
    !isNpmPackageName(name) ||
    typeof version !== "string" ||
    !isExactSemver(version) ||
    typeof entry !== "string" ||
    packageJson.type !== "module" ||
    !isRecord(engines) ||
    !isSupportedNodeRange(engines.node) ||
    !isRecord(mgread)
  ) {
    throw new PluginPackageError("plugin_package_invalid");
  }
  const id = mgread.id;
  const displayName = mgread.displayName;
  const description = mgread.description;
  const schemaVersion = mgread.schemaVersion;
  const api = mgread.pluginApi;
  const contentKinds = mgread.contentKinds;
  const packageMode = mgread.packageMode ?? "single-file";
  const icon = mgread.icon;
  if (
    schemaVersion !== pluginPackageSchemaVersion ||
    api !== pluginApiVersion ||
    typeof id !== "string" ||
    !/^[a-z0-9]+(?:[.-][a-z0-9]+)+$/.test(id) ||
    typeof displayName !== "string" ||
    displayName.trim().length === 0 ||
    displayName.length > 128 ||
    (description !== undefined &&
      (typeof description !== "string" ||
        description.trim().length === 0 ||
        description.length > 240)) ||
    !Array.isArray(contentKinds) ||
    contentKinds.length === 0 ||
    contentKinds.some((kind) => kind !== "novel" && kind !== "manga" && kind !== "audio" && kind !== "video") ||
    new Set(contentKinds).size !== contentKinds.length ||
    (packageMode !== "single-file" && packageMode !== "archive") ||
    (icon !== undefined && !isSupportedIconPath(icon))
  ) {
    throw new PluginPackageError("plugin_package_invalid");
  }

  const normalizedEntry = normalizePluginRelativePath(entry);
  if (
    !normalizedEntry.startsWith("dist/") ||
    !/\.(?:cjs|js|mjs)$/.test(normalizedEntry)
  ) {
    throw new PluginPackageError("plugin_package_invalid");
  }
  return Object.freeze({
    contentKinds: Object.freeze([...contentKinds] as PluginContentKind[]),
    ...(description === undefined ? {} : { description }),
    displayName,
    entry: normalizedEntry,
    id,
    ...(icon === undefined ? {} : { icon }),
    name,
    packageMode,
    pluginApi: pluginApiVersion,
    projectRoot,
    version,
  });
}

function isSupportedIconPath(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    const normalized = normalizePluginRelativePath(value);
    return normalized.startsWith("assets/") && /\.(?:jpe?g|png|webp)$/i.test(normalized);
  } catch {
    return false;
  }
}

function isSupportedNodeRange(value: unknown): boolean {
  return (
    value === supportedPluginNodeRange ||
    // Preserve installed artifacts created by the previous Node 24 host.
    value === nodeVersionByBackend.macos ||
    value === ">=24 <25" ||
    value === ">=24.0.0 <25.0.0"
  );
}

function isExactSemver(value: string): boolean {
  return /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(value);
}

function isNpmPackageName(value: string): boolean {
  return /^(?:@[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*|[a-z0-9][a-z0-9._-]*)$/.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
