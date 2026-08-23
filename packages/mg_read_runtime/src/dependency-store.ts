import { createHash, randomUUID } from "node:crypto";
import { gunzipSync } from "node:zlib";
import {
  chmod,
  copyFile,
  lstat,
  link,
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
  dependencyObjectName,
  type LockedPluginDependency,
  normalizePluginRelativePath,
  parseSha512Integrity,
  PluginPackageError,
  resolveInside,
} from "./plugin-package.js";

const MAX_TARBALL_BYTES = 64 * 1024 * 1024;
const MAX_UNPACKED_PACKAGE_BYTES = 256 * 1024 * 1024;
const MAX_PACKAGE_ENTRIES = 16_384;

type FetchPackage = (url: string) => Promise<{
  readonly ok: boolean;
  readonly status: number;
  arrayBuffer(): Promise<ArrayBuffer>;
}>;

type HardlinkFile = (source: string, destination: string) => Promise<void>;

/** Stable dependency-store failure without a registry URL, path, or exception. */
export class DependencyStoreError extends Error {
  constructor(
    readonly code:
      | "dependency_download_failed"
      | "dependency_integrity_failed"
      | "dependency_package_invalid"
      | "dependency_store_failed",
  ) {
    super("The Runtime could not restore a plugin dependency.");
    this.name = "DependencyStoreError";
  }
}

/** Materialization statistics used by diagnostics and performance acceptance. */
export interface DependencyMaterializationResult {
  readonly copiedFiles: number;
  readonly hardlinkedFiles: number;
}

/** Runtime-owned content-addressed npm package store. */
export class DependencyStore {
  readonly #fetchPackage: FetchPackage;
  readonly #hardlinkFile: HardlinkFile;
  readonly #inFlight = new Map<string, Promise<string>>();
  readonly #objectsRoot: string;

  constructor(
    runtimeDataRoot: string,
    options: {
      readonly fetchPackage?: FetchPackage;
      readonly hardlinkFile?: HardlinkFile;
    } = {},
  ) {
    this.#objectsRoot = resolve(runtimeDataRoot, "dependencies", "objects");
    this.#fetchPackage = options.fetchPackage ?? defaultFetchPackage;
    this.#hardlinkFile = options.hardlinkFile ?? link;
  }

  /** Checks the immutable cache marker without exposing its filesystem path. */
  async hasRegistryPackage(dependency: LockedPluginDependency): Promise<boolean> {
    if (dependency.kind !== "registry" || dependency.integrity === undefined) {
      return false;
    }
    const objectRoot = resolve(
      this.#objectsRoot,
      dependencyObjectName(dependency.integrity),
    );
    try {
      await stat(resolve(objectRoot, "complete.json"));
      await stat(resolve(objectRoot, "package", "package.json"));
      return true;
    } catch {
      return false;
    }
  }

  /** Ensures one registry package object exists and returns its package root. */
  ensureRegistryPackage(dependency: LockedPluginDependency): Promise<string> {
    if (dependency.kind !== "registry" || dependency.integrity === undefined) {
      return Promise.reject(new DependencyStoreError("dependency_package_invalid"));
    }
    const objectName = dependencyObjectName(dependency.integrity);
    const existing = this.#inFlight.get(objectName);
    if (existing !== undefined) {
      return existing;
    }
    const operation = this.#ensureRegistryPackage(dependency, objectName).finally(() => {
      this.#inFlight.delete(objectName);
    });
    this.#inFlight.set(objectName, operation);
    return operation;
  }

  /** Creates a normal package directory with hardlink-first file materialization. */
  async materializePackage(
    sourceRoot: string,
    destinationRoot: string,
  ): Promise<DependencyMaterializationResult> {
    const counters = { copiedFiles: 0, hardlinkedFiles: 0 };
    await this.#materializeDirectory(sourceRoot, destinationRoot, counters);
    return Object.freeze(counters);
  }

  /** Lists content objects currently present; used by mark-and-sweep GC. */
  async listObjectNames(): Promise<readonly string[]> {
    try {
      const entries = await readdir(this.#objectsRoot, { withFileTypes: true });
      return Object.freeze(
        entries
          .filter((entry) => entry.isDirectory() && entry.name.startsWith("sha512-"))
          .map((entry) => entry.name)
          .sort(),
      );
    } catch (error) {
      if (isNodeError(error, "ENOENT")) {
        return Object.freeze([]);
      }
      throw new DependencyStoreError("dependency_store_failed");
    }
  }

  /** Removes one unreferenced object directory after the caller's mark phase. */
  async removeObject(objectName: string): Promise<void> {
    if (!/^sha512-[A-Za-z0-9_-]{86}$/.test(objectName)) {
      throw new DependencyStoreError("dependency_store_failed");
    }
    await rm(resolve(this.#objectsRoot, objectName), { force: true, recursive: true });
  }

  async #ensureRegistryPackage(
    dependency: LockedPluginDependency,
    objectName: string,
  ): Promise<string> {
    const objectRoot = resolve(this.#objectsRoot, objectName);
    const packageRoot = resolve(objectRoot, "package");
    const completeMarker = resolve(objectRoot, "complete.json");
    try {
      await stat(completeMarker);
      await stat(resolve(packageRoot, "package.json"));
      return packageRoot;
    } catch {
      // Missing or incomplete objects are rebuilt under a fresh staging name.
    }

    const stagingRoot = resolve(this.#objectsRoot, `.staging-${randomUUID()}`);
    const stagingPackage = resolve(stagingRoot, "package");
    try {
      await mkdir(stagingPackage, { recursive: true });
      const response = await this.#fetchPackage(dependency.resolved);
      if (!response.ok) {
        throw new DependencyStoreError("dependency_download_failed");
      }
      const tarball = Buffer.from(await response.arrayBuffer());
      if (tarball.length === 0 || tarball.length > MAX_TARBALL_BYTES) {
        throw new DependencyStoreError("dependency_download_failed");
      }
      const expected = parseSha512Integrity(dependency.integrity!);
      const actual = createHash("sha512").update(tarball).digest();
      if (!actual.equals(expected)) {
        throw new DependencyStoreError("dependency_integrity_failed");
      }
      let tar: Buffer;
      try {
        tar = gunzipSync(tarball, { maxOutputLength: MAX_UNPACKED_PACKAGE_BYTES });
      } catch {
        throw new DependencyStoreError("dependency_package_invalid");
      }
      await extractNpmTar(tar, stagingPackage);
      await rejectNativePackage(stagingPackage);
      await makeTreeReadOnly(stagingPackage);
      await writeFile(
        resolve(stagingRoot, "complete.json"),
        `${JSON.stringify({ integrity: dependency.integrity, version: dependency.version })}\n`,
        { flag: "wx", mode: 0o444 },
      );
      await mkdir(this.#objectsRoot, { recursive: true });
      try {
        await rename(stagingRoot, objectRoot);
      } catch (error) {
        if (!isNodeError(error, "EEXIST") && !isNodeError(error, "ENOTEMPTY")) {
          throw error;
        }
      }
      return packageRoot;
    } catch (error) {
      if (
        error instanceof DependencyStoreError ||
        error instanceof PluginPackageError
      ) {
        throw error;
      }
      throw new DependencyStoreError("dependency_store_failed");
    } finally {
      await rm(stagingRoot, { force: true, recursive: true }).catch(() => {});
    }
  }

  async #materializeDirectory(
    sourceRoot: string,
    destinationRoot: string,
    counters: { copiedFiles: number; hardlinkedFiles: number },
  ): Promise<void> {
    await mkdir(destinationRoot, { recursive: true });
    const entries = await readdir(sourceRoot, { withFileTypes: true });
    for (const entry of entries) {
      const source = resolve(sourceRoot, entry.name);
      const destination = resolve(destinationRoot, entry.name);
      if (entry.isSymbolicLink()) {
        throw new DependencyStoreError("dependency_package_invalid");
      }
      if (entry.isDirectory()) {
        await this.#materializeDirectory(source, destination, counters);
        continue;
      }
      if (!entry.isFile()) {
        throw new DependencyStoreError("dependency_package_invalid");
      }
      await mkdir(dirname(destination), { recursive: true });
      try {
        await this.#hardlinkFile(source, destination);
        counters.hardlinkedFiles += 1;
      } catch {
        await copyFile(source, destination);
        counters.copiedFiles += 1;
      }
      await chmod(destination, 0o444).catch(() => {});
    }
  }
}

async function defaultFetchPackage(url: string) {
  return fetch(url, {
    headers: { accept: "application/octet-stream" },
    redirect: "follow",
    signal: AbortSignal.timeout(30_000),
  });
}

async function extractNpmTar(tar: Buffer, destinationRoot: string): Promise<void> {
  let offset = 0;
  let entries = 0;
  let totalBytes = 0;
  let pendingLongPath: string | undefined;
  let pendingPaxPath: string | undefined;
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512);
    offset += 512;
    if (header.every((byte) => byte === 0)) {
      return;
    }
    if (!hasValidTarChecksum(header)) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    const size = parseTarOctal(header.subarray(124, 136));
    const type = String.fromCharCode(header[156] ?? 0);
    const rawName = readTarString(header.subarray(0, 100));
    const prefix = readTarString(header.subarray(345, 500));
    const headerPath = prefix.length === 0 ? rawName : `${prefix}/${rawName}`;
    const dataEnd = offset + size;
    const paddedEnd = offset + Math.ceil(size / 512) * 512;
    if (dataEnd > tar.length || paddedEnd > tar.length) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    const data = tar.subarray(offset, dataEnd);
    offset = paddedEnd;

    if (type === "L") {
      pendingLongPath = readTarString(data);
      continue;
    }
    if (type === "x") {
      pendingPaxPath = parsePaxPath(data);
      continue;
    }
    if (type === "g") {
      continue;
    }

    const archivePath = pendingPaxPath ?? pendingLongPath ?? headerPath;
    pendingPaxPath = undefined;
    pendingLongPath = undefined;
    const path = stripNpmPackagePrefix(archivePath);
    if (path === undefined) {
      continue;
    }
    entries += 1;
    if (entries > MAX_PACKAGE_ENTRIES) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    if (type === "5") {
      await mkdir(resolveInside(destinationRoot, path), { recursive: true });
      continue;
    }
    if (type !== "0" && type !== "\0" && type !== "") {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    totalBytes += data.length;
    if (totalBytes > MAX_UNPACKED_PACKAGE_BYTES) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    const target = resolveInside(destinationRoot, path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, data, { flag: "wx", mode: 0o444 });
  }
  throw new DependencyStoreError("dependency_package_invalid");
}

function stripNpmPackagePrefix(value: string): string | undefined {
  const normalized = value.replace(/\0+$/, "").replace(/^\.\//, "");
  if (normalized === "package" || normalized === "package/") {
    return undefined;
  }
  if (!normalized.startsWith("package/")) {
    throw new DependencyStoreError("dependency_package_invalid");
  }
  try {
    return normalizePluginRelativePath(normalized.slice("package/".length));
  } catch {
    throw new DependencyStoreError("dependency_package_invalid");
  }
}

function parsePaxPath(data: Buffer): string | undefined {
  let offset = 0;
  let path: string | undefined;
  while (offset < data.length) {
    const space = data.indexOf(0x20, offset);
    if (space < 0) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    const length = Number.parseInt(data.subarray(offset, space).toString("ascii"), 10);
    if (!Number.isSafeInteger(length) || length <= 0 || offset + length > data.length) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    const record = data.subarray(space + 1, offset + length - 1).toString("utf8");
    const equals = record.indexOf("=");
    if (equals > 0 && record.slice(0, equals) === "path") {
      path = record.slice(equals + 1);
    }
    offset += length;
  }
  return path;
}

function hasValidTarChecksum(header: Buffer): boolean {
  const expected = parseTarOctal(header.subarray(148, 156));
  let actual = 0;
  for (let index = 0; index < header.length; index += 1) {
    actual += index >= 148 && index < 156 ? 0x20 : header[index]!;
  }
  return actual === expected;
}

function parseTarOctal(bytes: Buffer): number {
  const text = bytes.toString("ascii").replace(/\0.*$/, "").trim();
  if (!/^[0-7]+$/.test(text)) {
    throw new DependencyStoreError("dependency_package_invalid");
  }
  const value = Number.parseInt(text, 8);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new DependencyStoreError("dependency_package_invalid");
  }
  return value;
}

function readTarString(bytes: Buffer): string {
  const nullIndex = bytes.indexOf(0);
  return bytes.subarray(0, nullIndex < 0 ? bytes.length : nullIndex).toString("utf8");
}

async function rejectNativePackage(packageRoot: string): Promise<void> {
  const entries = await listTree(packageRoot);
  for (const path of entries) {
    const lower = path.toLowerCase();
    if (
      lower.endsWith(".node") ||
      lower.endsWith(".dll") ||
      lower.endsWith(".so") ||
      lower === "binding.gyp" ||
      lower.endsWith("/binding.gyp")
    ) {
      throw new PluginPackageError("plugin_native_dependency_unsupported");
    }
  }
}

async function listTree(root: string, prefix = ""): Promise<string[]> {
  const result: string[] = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = prefix.length === 0 ? entry.name : `${prefix}/${entry.name}`;
    if (entry.isSymbolicLink()) {
      throw new DependencyStoreError("dependency_package_invalid");
    }
    if (entry.isDirectory()) {
      result.push(...(await listTree(resolve(root, entry.name), path)));
    } else if (entry.isFile()) {
      result.push(path);
    } else {
      throw new DependencyStoreError("dependency_package_invalid");
    }
  }
  return result;
}

async function makeTreeReadOnly(root: string): Promise<void> {
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = resolve(root, entry.name);
    if (entry.isDirectory()) {
      await makeTreeReadOnly(path);
      await chmod(path, 0o555).catch(() => {});
    } else if (entry.isFile()) {
      await chmod(path, 0o444).catch(() => {});
    }
  }
  await chmod(root, 0o555).catch(() => {});
}

function isNodeError(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === code
  );
}
