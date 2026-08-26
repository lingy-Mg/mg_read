/**
 * Runtime 私有插件 artifact v2 传输管理器。
 *
 * 职责：索引双格式原始 artifact、规划版本同步、调用开发项目构建工具并签发一次性资源。
 * - 为局域网临时同步生成 devsync 版本，为用户主动打包保留项目声明版本。
 * 注意：开发构建工具在唯一 Runtime VM 内动态导入；Runtime 信任其 artifact 结果，不重复解析；wire 不暴露路径、代码或图标字节。
 * TODO: - 无。
 */
import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

import {
  MAX_PLUGIN_ARTIFACT_BYTES,
  type PluginArtifactFormat,
} from "./plugin-single-file.js";
import type { JsonObject } from "./protocol.js";

export const MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH = 32;
export const MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH_BYTES = 512 * 1024 * 1024;

export interface PluginTransferArtifact extends JsonObject {
  readonly bytes: number;
  readonly format: PluginArtifactFormat;
  readonly id: string;
  readonly sha256: string;
  readonly version: string;
}

export interface PluginTransferPlanItem extends JsonObject {
  readonly action: "missing" | "upgrade" | "same" | "receiverNewer" | "unavailable";
  readonly id: string;
  readonly receiverVersion: string | null;
  readonly version: string;
}

export interface PluginTransferResource {
  readonly bytes: number;
  readonly format: PluginArtifactFormat;
  readonly path: string;
  readonly sha256: string;
  readonly stream: ReturnType<typeof createReadStream>;
}

export class PluginArtifactTransferError extends Error {
  constructor(readonly code:
    | "invalid_request"
    | "plugin_not_found"
    | "plugin_transfer_artifact_missing"
    | "plugin_transfer_artifact_too_large"
    | "plugin_transfer_batch_too_large"
    | "plugin_transfer_checksum_mismatch"
    | "plugin_transfer_size_mismatch") {
    super("The Runtime plugin artifact transfer could not be completed.");
    this.name = "PluginArtifactTransferError";
  }
}

interface TransferEntry {
  readonly artifact: PluginTransferArtifact;
  readonly expiresAt: number;
  readonly path: string;
}

export interface DevelopmentTransferProject {
  readonly id: string;
  readonly packageMode: "archive" | "single-file";
  readonly projectRoot: string;
  readonly version: string;
}

/** Owns retained/development artifact indexes and one-shot streams. */
export class PluginArtifactTransferManager {
  readonly #dataRoot: string;
  readonly #stagingRoot: string;
  readonly #development = new Map<string, TransferEntry>();
  readonly #resources = new Map<string, TransferEntry>();

  constructor(dataRoot: string) {
    this.#dataRoot = resolve(dataRoot);
    this.#stagingRoot = resolve(this.#dataRoot, "temporary", "plugin-transfer", randomUUID());
  }

  async listExportable(
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
    development: readonly DevelopmentTransferProject[] = [],
  ): Promise<readonly PluginTransferArtifact[]> {
    const output: PluginTransferArtifact[] = [];
    const developmentIds = new Set(development.map((item) => item.id));
    for (const plugin of installed) {
      if (developmentIds.has(plugin.id)) continue;
      const version = plugin.activeVersion ?? plugin.pendingVersion;
      if (version === null) continue;
      const retained = await findRetainedArtifact(this.#dataRoot, plugin.id, version);
      if (retained === undefined || retained.bytes > MAX_PLUGIN_ARTIFACT_BYTES) continue;
      output.push(Object.freeze({
        bytes: retained.bytes, format: retained.format, id: plugin.id,
        sha256: await hashFile(retained.path), version,
      }));
    }
    await mkdir(this.#stagingRoot, { recursive: true });
    const generatedAt = Date.now();
    for (let index = 0; index < development.length; index += 1) {
      const project = development[index]!;
      const version = developmentVersion(project.version, generatedAt + index);
      const entry = await this.#buildDevelopment(project, version);
      if (entry === undefined) continue;
      this.#development.set(key(project.id, version), entry);
      output.push(entry.artifact);
    }
    output.sort((left, right) => left.id.localeCompare(right.id));
    return Object.freeze(output);
  }

  plan(
    incoming: readonly PluginTransferArtifact[],
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
  ): readonly PluginTransferPlanItem[] {
    validateArtifactBatch(incoming);
    const receiver = new Map(installed.map((item) => [item.id, item.activeVersion ?? item.pendingVersion]));
    return Object.freeze(incoming.map((artifact) => {
      const current = receiver.get(artifact.id) ?? null;
      const comparison = current === null ? 1 : compareSemver(artifact.version, current);
      const action = current === null ? "missing" : comparison > 0 ? "upgrade" : comparison === 0 ? "same" : "receiverNewer";
      return Object.freeze({ action, id: artifact.id, receiverVersion: current, version: artifact.version });
    }));
  }

  async createResource(id: string, version: string): Promise<{ readonly artifact: PluginTransferArtifact; readonly token: string }> {
    if (!isPluginId(id) || parseSemver(version) === null) throw new PluginArtifactTransferError("invalid_request");
    let entry = this.#development.get(key(id, version));
    if (entry === undefined) {
      const retained = await findRetainedArtifact(this.#dataRoot, id, version);
      if (retained === undefined) throw new PluginArtifactTransferError("plugin_transfer_artifact_missing");
      if (retained.bytes > MAX_PLUGIN_ARTIFACT_BYTES) throw new PluginArtifactTransferError("plugin_transfer_artifact_too_large");
      entry = Object.freeze({
        artifact: Object.freeze({ bytes: retained.bytes, format: retained.format, id, sha256: await hashFile(retained.path), version }),
        expiresAt: Number.MAX_SAFE_INTEGER,
        path: retained.path,
      });
    }
    const token = randomUUID().replaceAll("-", "");
    this.#resources.set(token, { ...entry, expiresAt: Date.now() + 60_000 });
    return Object.freeze({ artifact: entry.artifact, token });
  }

  /** Builds one current development project at its declared release version. */
  async createDevelopmentPackageResource(
    project: DevelopmentTransferProject,
  ): Promise<{ readonly artifact: PluginTransferArtifact; readonly token: string }> {
    await mkdir(this.#stagingRoot, { recursive: true });
    const entry = await this.#buildDevelopment(project, project.version);
    if (entry === undefined) {
      throw new PluginArtifactTransferError("plugin_transfer_artifact_missing");
    }
    const token = randomUUID().replaceAll("-", "");
    this.#resources.set(token, { ...entry, expiresAt: Date.now() + 60_000 });
    return Object.freeze({ artifact: entry.artifact, token });
  }

  async verifyInbox(incoming: readonly PluginTransferArtifact[]): Promise<void> {
    validateArtifactBatch(incoming);
    const inbox = resolve(this.#dataRoot, "import-inbox");
    let names: string[];
    try { names = (await readdir(inbox)).filter(isArtifactName); }
    catch (error) { if (isMissing(error)) throw new PluginArtifactTransferError("plugin_transfer_artifact_missing"); throw error; }
    const candidates = new Set(names.map((name) => resolve(inbox, name)));
    for (const artifact of incoming) {
      let matched: string | undefined;
      for (const path of candidates) {
        if (formatForPath(path) !== artifact.format) continue;
        const metadata = await stat(path).catch(() => undefined);
        if (metadata?.isFile() && metadata.size === artifact.bytes && await hashFile(path) === artifact.sha256) { matched = path; break; }
      }
      if (matched === undefined) throw new PluginArtifactTransferError("plugin_transfer_checksum_mismatch");
      candidates.delete(matched);
    }
  }

  consumeResource(token: string): PluginTransferResource | undefined {
    const entry = this.#resources.get(token);
    this.#resources.delete(token);
    if (entry === undefined || entry.expiresAt < Date.now()) return undefined;
    return { bytes: entry.artifact.bytes, format: entry.artifact.format, path: entry.path,
      sha256: entry.artifact.sha256, stream: createReadStream(entry.path, { highWaterMark: 64 * 1024 }) };
  }

  async dispose(): Promise<void> {
    this.#resources.clear(); this.#development.clear();
    await rm(this.#stagingRoot, { force: true, recursive: true });
  }

  async #buildDevelopment(project: DevelopmentTransferProject, version: string): Promise<TransferEntry | undefined> {
    const format: PluginArtifactFormat = project.packageMode === "single-file" ? "singleFile" : "archive";
    const extension = format === "singleFile" ? ".mgplugin.js" : ".mgplugin";
    const path = resolve(this.#stagingRoot, `${project.id}-${randomUUID()}${extension}`);
    try {
      const tool = await import(pathToFileURL(resolve(project.projectRoot, "tools", "mgread.mjs")).href) as Record<string, unknown>;
      if (typeof tool.buildPluginArtifact !== "function") return undefined;
      const built = await (tool.buildPluginArtifact as (input: { versionOverride: string }) => unknown)({ versionOverride: version });
      if (!isBuildResult(built) || built.format !== format || !built.fileName.endsWith(extension) || built.bytes.byteLength > MAX_PLUGIN_ARTIFACT_BYTES) return undefined;
      await writeFile(path, built.bytes, { flag: "wx", mode: 0o444 });
      const artifact = Object.freeze({ bytes: built.bytes.byteLength, format, id: project.id, sha256: sha256(built.bytes), version });
      return Object.freeze({ artifact, expiresAt: Number.MAX_SAFE_INTEGER, path });
    } catch { await rm(path, { force: true }); return undefined; }
  }
}

export function validateArtifactBatch(artifacts: readonly PluginTransferArtifact[]): void {
  if (artifacts.length > MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH) throw new PluginArtifactTransferError("plugin_transfer_batch_too_large");
  let bytes = 0;
  for (const artifact of artifacts) {
    if (!isPluginTransferArtifact(artifact)) throw new PluginArtifactTransferError("invalid_request");
    bytes += artifact.bytes;
    if (bytes > MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH_BYTES) throw new PluginArtifactTransferError("plugin_transfer_batch_too_large");
  }
}

export function isPluginTransferArtifact(value: unknown): value is PluginTransferArtifact {
  if (!isRecord(value) || Object.keys(value).length !== 5) return false;
  return isPluginId(value.id) && typeof value.version === "string" && parseSemver(value.version) !== null &&
    typeof value.bytes === "number" && Number.isSafeInteger(value.bytes) && value.bytes > 0 && value.bytes <= MAX_PLUGIN_ARTIFACT_BYTES &&
    typeof value.sha256 === "string" && /^[a-f0-9]{64}$/.test(value.sha256) && (value.format === "archive" || value.format === "singleFile");
}

async function findRetainedArtifact(dataRoot: string, id: string, version: string) {
  for (const format of ["singleFile", "archive"] as const) {
    const path = resolve(dataRoot, "plugin-archives", id, `${version}${format === "singleFile" ? ".mgplugin.js" : ".mgplugin"}`);
    try { const metadata = await stat(path); if (metadata.isFile()) return { bytes: metadata.size, format, path }; }
    catch (error) { if (!isMissing(error)) throw error; }
  }
  return undefined;
}

function isBuildResult(value: unknown): value is { bytes: Uint8Array; fileName: string; format: PluginArtifactFormat } {
  return isRecord(value) && value.bytes instanceof Uint8Array && value.bytes.byteLength > 0 &&
    typeof value.fileName === "string" && value.fileName.length > 0 && value.fileName.length <= 240 &&
    (value.format === "archive" || value.format === "singleFile");
}
async function hashFile(path: string): Promise<string> { return sha256(await readFile(path)); }
function sha256(bytes: Uint8Array): string { return createHash("sha256").update(bytes).digest("hex"); }
interface Semver { major: number; minor: number; patch: number; prerelease: string[] }
function parseSemver(value: string): Semver | null { const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(value); return m === null ? null : { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), prerelease: m[4]?.split(".") ?? [] }; }
function compareSemver(left: string, right: string): number { const a = parseSemver(left)!; const b = parseSemver(right)!; for (const k of ["major", "minor", "patch"] as const) if (a[k] !== b[k]) return a[k] > b[k] ? 1 : -1; if (!a.prerelease.length && b.prerelease.length) return 1; if (a.prerelease.length && !b.prerelease.length) return -1; return a.prerelease.join(".").localeCompare(b.prerelease.join(".")); }
function developmentVersion(version: string, at: number): string { const v = parseSemver(version); if (v === null || v.patch >= Number.MAX_SAFE_INTEGER) throw new PluginArtifactTransferError("invalid_request"); return `${v.major}.${v.minor}.${v.patch + 1}-devsync.${at}`; }
function key(id: string, version: string): string { return `${id}\u001f${version}`; }
function isPluginId(value: unknown): value is string { return typeof value === "string" && /^[a-z0-9][a-z0-9.-]{0,127}$/.test(value); }
function isArtifactName(value: string): boolean { return value.endsWith(".mgplugin") || value.endsWith(".mgplugin.js"); }
function formatForPath(path: string): PluginArtifactFormat { return path.endsWith(".mgplugin.js") ? "singleFile" : "archive"; }
function isMissing(error: unknown): boolean { return isRecord(error) && error.code === "ENOENT"; }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
