/**
 * 标准插件项目元数据与 archive lockfile 校验。
 *
 * 职责：解析 package.json.mgread v1，并为 archive 校验可恢复的 lockfile v3 依赖图。
 * 注意：single-file 的开发依赖只由 Node.js 解析，发布时已全部 bundle，不属于 Runtime 安装契约。
 */
import { access, lstat, readFile } from "node:fs/promises";
import { isAbsolute, resolve, sep } from "node:path";

import { expectedNodeVersion } from "./runtime-version.js";

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
      | "plugin_lock_invalid"
      | "plugin_native_dependency_unsupported"
      | "plugin_package_invalid"
      | "plugin_package_legacy_unsupported"
      | "plugin_package_unsupported_dependency",
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

/** One production package location already solved by npm lockfile v3. */
export interface LockedPluginDependency {
  readonly installPath: string;
  readonly integrity?: string;
  readonly kind: "local" | "registry";
  readonly optional: boolean;
  readonly resolved: string;
  readonly sourcePath?: string;
  readonly version: string;
}

/** Validated project input; single-file projects always expose an empty dependency graph. */
export interface ValidatedPluginProject {
  readonly dependencies: readonly LockedPluginDependency[];
  readonly descriptor: PluginPackageDescriptor;
  readonly lock: Readonly<Record<string, unknown>>;
  readonly packageJson: Readonly<Record<string, unknown>>;
}

/** Reads package metadata and validates a lockfile only when archive restoration needs it. */
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

  const lock = descriptor.packageMode === "archive"
    ? await readJsonObject(
        resolve(normalizedRoot, "package-lock.json"),
        "plugin_lock_invalid",
      )
    : {};
  const dependencies = descriptor.packageMode === "archive"
    ? parseArchiveLockfile(lock, descriptor, packageJson)
    : [];
  return Object.freeze({
    dependencies: Object.freeze(dependencies),
    descriptor,
    lock: Object.freeze(lock),
    packageJson: Object.freeze(packageJson),
  });
}

/** Converts an integrity string to a stable filesystem-safe object identity. */
export function dependencyObjectName(integrity: string): string {
  const digest = parseSha512Integrity(integrity);
  return `sha512-${digest.toString("base64url")}`;
}

/** Parses the only integrity algorithm accepted by the v1 dependency store. */
export function parseSha512Integrity(integrity: string): Buffer {
  const match = /^sha512-([A-Za-z0-9+/]+={0,2})$/.exec(integrity);
  if (match === null) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
  const digest = Buffer.from(match[1]!, "base64");
  if (digest.length !== 64) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
  return digest;
}

/** Validates one archive/lock relative path and returns normalized `/` form. */
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

function parseArchiveLockfile(
  lock: Record<string, unknown>,
  descriptor: PluginPackageDescriptor,
  packageJson: Record<string, unknown>,
): LockedPluginDependency[] {
  if (lock.lockfileVersion !== 3 || !isRecord(lock.packages)) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
  const root = lock.packages[""];
  if (
    !isRecord(root) ||
    root.name !== descriptor.name ||
    root.version !== descriptor.version
  ) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
  assertDependencyProjectionMatches(packageJson.dependencies, root.dependencies);
  assertDependencyProjectionMatches(
    packageJson.optionalDependencies,
    root.optionalDependencies,
  );

  const dependencies: LockedPluginDependency[] = [];
  for (const [lockPath, rawPackage] of Object.entries(lock.packages)) {
    if (lockPath === "" || !lockPath.includes("node_modules/")) {
      continue;
    }
    if (!isRecord(rawPackage)) {
      throw new PluginPackageError("plugin_lock_invalid");
    }
    if (rawPackage.dev === true && rawPackage.optional !== true) {
      continue;
    }
    const installPath = normalizeLockInstallPath(lockPath);
    const optional = rawPackage.optional === true;
    const resolved = rawPackage.resolved;
    if (typeof resolved !== "string") {
      throw new PluginPackageError("plugin_lock_invalid");
    }

    if (rawPackage.link === true) {
      const sourcePath = normalizeLocalDependencyPath(resolved);
      const sourceRecord = lock.packages[sourcePath];
      const sourceVersion = isRecord(sourceRecord) ? sourceRecord.version : undefined;
      if (typeof sourceVersion !== "string") {
        throw new PluginPackageError("plugin_lock_invalid");
      }
      dependencies.push(
        Object.freeze({
          installPath,
          kind: "local",
          optional,
          resolved,
          sourcePath,
          version: sourceVersion,
        }),
      );
      continue;
    }

    const version = rawPackage.version;
    const integrity = rawPackage.integrity;
    if (
      typeof version !== "string" ||
      typeof integrity !== "string" ||
      !isRegistryTarballUrl(resolved)
    ) {
      throw new PluginPackageError("plugin_package_unsupported_dependency");
    }
    parseSha512Integrity(integrity);
    dependencies.push(
      Object.freeze({
        installPath,
        integrity,
        kind: "registry",
        optional,
        resolved,
        version,
      }),
    );
  }
  dependencies.sort((left, right) => left.installPath.localeCompare(right.installPath));
  return dependencies;
}

function normalizeLockInstallPath(value: string): string {
  const normalized = normalizePluginRelativePath(value);
  const parts = normalized.split("/");
  const nodeModulesIndexes = parts
    .map((part, index) => (part === "node_modules" ? index : -1))
    .filter((index) => index >= 0);
  if (
    nodeModulesIndexes.length === 0 ||
    parts.at(-1) === "node_modules" ||
    parts.some((part, index) => part.startsWith("@") && parts[index - 1] !== "node_modules")
  ) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
  return normalized;
}

function normalizeLocalDependencyPath(value: string): string {
  const withoutPrefix = value.startsWith("file:") ? value.slice(5) : value;
  let normalized: string;
  try {
    normalized = normalizePluginRelativePath(withoutPrefix.replace(/^\.\//, ""));
  } catch {
    throw new PluginPackageError("plugin_package_unsupported_dependency");
  }
  if (!normalized.startsWith("packages/")) {
    throw new PluginPackageError("plugin_package_unsupported_dependency");
  }
  return normalized;
}

function assertDependencyProjectionMatches(
  packageValue: unknown,
  lockValue: unknown,
): void {
  const left = packageValue === undefined ? {} : packageValue;
  const right = lockValue === undefined ? {} : lockValue;
  if (!isRecord(left) || !isRecord(right)) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
  if (JSON.stringify(sortedRecord(left)) !== JSON.stringify(sortedRecord(right))) {
    throw new PluginPackageError("plugin_lock_invalid");
  }
}

function sortedRecord(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).sort(([left], [right]) => left.localeCompare(right)));
}

function isRegistryTarballUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}

function isSupportedNodeRange(value: unknown): boolean {
  return (
    value === expectedNodeVersion ||
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
