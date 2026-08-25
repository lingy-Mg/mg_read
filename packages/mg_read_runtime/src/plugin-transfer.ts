import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { resolve } from "node:path";

import { createPluginArchive, PluginArchiveError } from "./plugin-archive.js";
import type { JsonObject } from "./protocol.js";

export const MAX_PLUGIN_TRANSFER_BYTES = 32 * 1024 * 1024;
export const MAX_PLUGIN_TRANSFER_BATCH = 32;
export const MAX_PLUGIN_TRANSFER_BATCH_BYTES = 512 * 1024 * 1024;

export type PluginTransferPlanAction =
  | "missing"
  | "upgrade"
  | "same"
  | "receiverNewer"
  | "unavailable";

export interface PluginTransferArchive extends JsonObject {
  readonly bytes: number;
  readonly id: string;
  readonly sha256: string;
  readonly version: string;
}

export interface PluginTransferPlanItem extends JsonObject {
  readonly action: PluginTransferPlanAction;
  readonly id: string;
  readonly receiverVersion: string | null;
  readonly version: string;
}

export interface PluginTransferResource {
  readonly bytes: number;
  readonly path: string;
  readonly sha256: string;
  readonly stream: ReturnType<typeof createReadStream>;
}

export class PluginTransferError extends Error {
  constructor(
    readonly code:
      | "invalid_request"
      | "plugin_not_found"
      | "plugin_transfer_archive_missing"
      | "plugin_transfer_archive_too_large"
      | "plugin_transfer_batch_too_large"
      | "plugin_transfer_checksum_mismatch"
      | "plugin_transfer_size_mismatch",
  ) {
    super("The Runtime plugin transfer could not be completed.");
    this.name = "PluginTransferError";
  }
}

interface TransferEntry {
  readonly archive: PluginTransferArchive;
  readonly path: string;
  readonly expiresAt: number;
}

export interface DevelopmentTransferProject {
  readonly id: string;
  readonly projectRoot: string;
  readonly version: string;
}

/** Runtime-private archive index and one-shot resource owner. */
export class PluginTransferManager {
  readonly #dataRoot: string;
  readonly #stagingRoot: string;
  readonly #developmentExports = new Map<string, TransferEntry>();
  readonly #resources = new Map<string, TransferEntry>();

  constructor(dataRoot: string) {
    this.#dataRoot = resolve(dataRoot);
    this.#stagingRoot = resolve(
      this.#dataRoot,
      "temporary",
      "plugin-transfer",
      randomUUID(),
    );
  }

  async listExportable(
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
    development: readonly DevelopmentTransferProject[] = [],
  ): Promise<readonly PluginTransferArchive[]> {
    const output: PluginTransferArchive[] = [];
    const developmentIds = new Set(development.map((plugin) => plugin.id));
    for (const plugin of installed) {
      if (developmentIds.has(plugin.id)) continue;
      const version = plugin.activeVersion ?? plugin.pendingVersion;
      if (version === null) continue;
      const path = resolve(this.#dataRoot, "plugin-archives", plugin.id, `${version}.mgplugin`);
      try {
        const metadata = await stat(path);
        if (!metadata.isFile()) continue;
        if (metadata.size > MAX_PLUGIN_TRANSFER_BYTES) continue;
        output.push(Object.freeze({
          bytes: metadata.size,
          id: plugin.id,
          sha256: await hashFile(path),
          version,
        }));
      } catch (error) {
        if (!isMissing(error)) throw error;
      }
    }
    await mkdir(this.#stagingRoot, { recursive: true });
    const generatedAt = Date.now();
    for (let index = 0; index < development.length; index += 1) {
      const plugin = development[index]!;
      const version = developmentTransferVersion(
        plugin.version,
        generatedAt + index,
      );
      const path = resolve(
        this.#stagingRoot,
        `${plugin.id}-${randomUUID()}.mgplugin`,
      );
      try {
        await createPluginArchive(plugin.projectRoot, path, {
          versionOverride: version,
        });
      } catch (error) {
        await rm(path, { force: true });
        if (error instanceof PluginArchiveError || isMissing(error)) continue;
        throw error;
      }
      const metadata = await stat(path);
      if (!metadata.isFile() || metadata.size > MAX_PLUGIN_TRANSFER_BYTES) {
        await rm(path, { force: true });
        continue;
      }
      const archive = Object.freeze({
        bytes: metadata.size,
        id: plugin.id,
        sha256: await hashFile(path),
        version,
      });
      const entry = Object.freeze({
        archive,
        expiresAt: Number.MAX_SAFE_INTEGER,
        path,
      });
      this.#developmentExports.set(transferKey(plugin.id, version), entry);
      output.push(archive);
    }
    output.sort((left, right) => left.id.localeCompare(right.id));
    return Object.freeze(output);
  }

  plan(
    incoming: readonly PluginTransferArchive[],
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
  ): readonly PluginTransferPlanItem[] {
    validateBatch(incoming);
    const receiver = new Map(installed.map((plugin) => [plugin.id, plugin.activeVersion ?? plugin.pendingVersion]));
    return Object.freeze(incoming.map((archive) => {
      const current = receiver.get(archive.id) ?? null;
      let action: PluginTransferPlanAction;
      if (!isPluginTransferArchive(archive)) action = "unavailable";
      else if (current === null) action = "missing";
      else if (compareSemver(archive.version, current) > 0) action = "upgrade";
      else if (compareSemver(archive.version, current) === 0) action = "same";
      else action = "receiverNewer";
      return Object.freeze({
        action,
        id: archive.id,
        receiverVersion: current,
        version: archive.version,
      });
    }));
  }

  async createResource(id: string, version: string): Promise<{ readonly token: string; readonly archive: PluginTransferArchive }> {
    if (!/^[a-z0-9][a-z0-9.-]{0,127}$/.test(id) || parseSemver(version) === null) {
      throw new PluginTransferError("invalid_request");
    }
    const development = this.#developmentExports.get(transferKey(id, version));
    const path = development?.path ??
      resolve(this.#dataRoot, "plugin-archives", id, `${version}.mgplugin`);
    let metadata;
    try {
      metadata = await stat(path);
    } catch (error) {
      if (isMissing(error)) throw new PluginTransferError("plugin_transfer_archive_missing");
      throw error;
    }
    if (!metadata.isFile()) throw new PluginTransferError("plugin_transfer_archive_missing");
    if (metadata.size > MAX_PLUGIN_TRANSFER_BYTES) throw new PluginTransferError("plugin_transfer_archive_too_large");
    const archive = Object.freeze({ bytes: metadata.size, id, sha256: await hashFile(path), version });
    const token = randomUUID().replaceAll("-", "");
    this.#resources.set(token, { archive, expiresAt: Date.now() + 60_000, path });
    return Object.freeze({ archive, token });
  }

  /** Verifies Runtime-private inbox files before the installer consumes them. */
  async verifyInbox(incoming: readonly PluginTransferArchive[]): Promise<void> {
    validateBatch(incoming);
    const inbox = resolve(this.#dataRoot, "import-inbox");
    let names: string[];
    try { names = (await readdir(inbox)).filter((name) => name.endsWith(".mgplugin")); }
    catch (error) { if (isMissing(error)) throw new PluginTransferError("plugin_transfer_archive_missing"); throw error; }
    const candidates = new Set(names.map((name) => resolve(inbox, name)));
    for (const archive of incoming) {
      let matched = false;
      for (const path of candidates) {
        let metadata;
        try { metadata = await stat(path); } catch (error) { if (isMissing(error)) continue; throw error; }
        if (!metadata.isFile() || metadata.size !== archive.bytes) continue;
        if (await hashFile(path) !== archive.sha256) continue;
        matched = true;
        candidates.delete(path);
        break;
      }
      if (!matched) throw new PluginTransferError("plugin_transfer_checksum_mismatch");
    }
  }

  consumeResource(token: string): PluginTransferResource | undefined {
    const entry = this.#resources.get(token);
    this.#resources.delete(token);
    if (entry === undefined || entry.expiresAt < Date.now()) return undefined;
    return {
      bytes: entry.archive.bytes,
      path: entry.path,
      sha256: entry.archive.sha256,
      stream: createReadStream(entry.path, { highWaterMark: 64 * 1024 }),
    };
  }

  async dispose(): Promise<void> {
    this.#resources.clear();
    this.#developmentExports.clear();
    await rm(this.#stagingRoot, { force: true, recursive: true });
  }
}

export function validateBatch(archives: readonly PluginTransferArchive[]): void {
  if (archives.length > MAX_PLUGIN_TRANSFER_BATCH) throw new PluginTransferError("plugin_transfer_batch_too_large");
  let bytes = 0;
  for (const archive of archives) {
    if (!isPluginTransferArchive(archive)) throw new PluginTransferError("invalid_request");
    bytes += archive.bytes;
    if (bytes > MAX_PLUGIN_TRANSFER_BATCH_BYTES) throw new PluginTransferError("plugin_transfer_batch_too_large");
  }
}

export function isPluginTransferArchive(value: unknown): value is PluginTransferArchive {
  if (typeof value !== "object" || value === null) return false;
  const archive = value as Record<string, unknown>;
  return typeof archive.id === "string" && /^[a-z0-9][a-z0-9.-]{0,127}$/.test(archive.id) &&
    typeof archive.version === "string" && parseSemver(archive.version) !== null &&
    typeof archive.bytes === "number" && Number.isSafeInteger(archive.bytes) && archive.bytes > 0 && archive.bytes <= MAX_PLUGIN_TRANSFER_BYTES &&
    typeof archive.sha256 === "string" && /^[a-f0-9]{64}$/.test(archive.sha256);
}

async function hashFile(path: string): Promise<string> {
  const hash = createHash("sha256");
  const stream = createReadStream(path, { highWaterMark: 64 * 1024 });
  for await (const chunk of stream) hash.update(chunk as Uint8Array);
  return hash.digest("hex");
}

interface Semver { major: number; minor: number; patch: number; prerelease: string[] }
function parseSemver(value: string): Semver | null {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(value);
  if (match === null) return null;
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]), prerelease: match[4]?.split(".") ?? [] };
}
function compareSemver(left: string, right: string): number {
  const a = parseSemver(left); const b = parseSemver(right);
  if (a === null || b === null) return 0;
  for (const key of ["major", "minor", "patch"] as const) if (a[key] !== b[key]) return a[key] > b[key] ? 1 : -1;
  if (a.prerelease.length === 0 && b.prerelease.length > 0) return 1;
  if (a.prerelease.length > 0 && b.prerelease.length === 0) return -1;
  return a.prerelease.join(".").localeCompare(b.prerelease.join("."));
}
function developmentTransferVersion(version: string, generatedAt: number): string {
  const parsed = parseSemver(version);
  if (parsed === null || parsed.patch >= Number.MAX_SAFE_INTEGER) {
    throw new PluginTransferError("invalid_request");
  }
  return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}-devsync.${generatedAt}`;
}
function transferKey(id: string, version: string): string { return `${id}\u001f${version}`; }
function isMissing(error: unknown): boolean { return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "ENOENT"; }
