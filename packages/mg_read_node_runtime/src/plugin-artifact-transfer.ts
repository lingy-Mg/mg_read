/**
 * Runtime 私有插件 artifact v2 传输管理器。
 *
 * 职责：索引双格式原始 artifact、规划版本同步、调用开发项目构建工具并签发一次性资源。
 * - 为局域网临时同步生成 devsync 版本，为用户主动打包保留项目声明版本。
 * 注意：开发构建工具在唯一 Runtime VM 内动态导入；Runtime 信任其 artifact 结果，不重复解析；wire 不暴露路径、代码或图标字节。
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
import { developmentProjectFingerprint } from "./plugin-manager-files.js";
import type { JsonObject } from "./protocol.js";

export const MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH = 32;
export const MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH_BYTES = 512 * 1024 * 1024;

export interface PluginTransferArtifact extends JsonObject {
  readonly bytes: number;
  readonly developmentFingerprint: string | null;
  readonly developmentRevision: number | null;
  readonly format: PluginArtifactFormat;
  readonly id: string;
  readonly provenance: "development" | "developmentReplica" | "installed";
  readonly sha256: string;
  readonly version: string;
}

/** Path-free version metadata. Development projects are not packaged here. */
export interface PluginTransferOffer extends JsonObject {
  readonly developmentFingerprint: string | null;
  readonly developmentRevision: number | null;
  readonly format: PluginArtifactFormat;
  readonly id: string;
  readonly provenance: "development" | "developmentReplica" | "installed";
  readonly version: string;
}

export interface PluginTransferPlanItem extends JsonObject {
  readonly action: "developmentConflict" | "missing" | "upgrade" | "same" | "receiverNewer" | "unavailable";
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
    | "plugin_transfer_build_failed"
    | "plugin_transfer_checksum_mismatch"
    | "plugin_transfer_size_mismatch",
    readonly detail?: string,
  ) {
    super(detail === undefined
      ? "The Runtime plugin artifact transfer could not be completed."
      : `The Runtime plugin artifact transfer could not be completed. ${detail}`);
    this.name = "PluginArtifactTransferError";
  }
}

interface TransferEntry {
  readonly artifact: PluginTransferArtifact;
  readonly expiresAt: number;
  readonly path: string;
}

export interface DevelopmentTransferProject {
  readonly fingerprint: string;
  readonly id: string;
  readonly packageMode: "archive" | "single-file";
  readonly projectRoot: string;
  readonly syncRevision: number;
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

  async listOffers(
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
    development: readonly DevelopmentTransferProject[] = [],
  ): Promise<readonly PluginTransferOffer[]> {
    const output: PluginTransferOffer[] = [];
    const developmentIds = new Set(development.map((item) => item.id));
    for (const plugin of installed) {
      if (developmentIds.has(plugin.id)) continue;
      const version = plugin.activeVersion ?? plugin.pendingVersion;
      if (version === null) continue;
      const retained = await findRetainedArtifact(this.#dataRoot, plugin.id, version);
      if (retained === undefined || retained.bytes > MAX_PLUGIN_ARTIFACT_BYTES) continue;
      output.push(Object.freeze({
        ...developmentMetadataForVersion(version),
        format: retained.format,
        id: plugin.id,
        version,
      }));
    }
    for (const project of development) {
      if (!await hasDevelopmentBuildEntry(project)) continue;
      output.push(Object.freeze({
        developmentFingerprint: project.fingerprint,
        developmentRevision: project.syncRevision,
        format: project.packageMode === "single-file" ? "singleFile" : "archive",
        id: project.id,
        provenance: "development",
        version: developmentVersion(project.version, project.syncRevision, project.fingerprint),
      }));
    }
    output.sort((left, right) => left.id.localeCompare(right.id));
    return Object.freeze(output);
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
        bytes: retained.bytes,
        ...developmentMetadataForVersion(version),
        format: retained.format,
        id: plugin.id,
        sha256: await hashFile(retained.path),
        version,
      }));
    }
    await mkdir(this.#stagingRoot, { recursive: true });
    for (const project of development) {
      const version = developmentVersion(
        project.version,
        project.syncRevision,
        project.fingerprint,
      );
      try {
        const entry = await this.#buildDevelopment(project, version, "development");
        this.#development.set(key(project.id, version), entry);
        output.push(entry.artifact);
      } catch (error) {
        if (!(error instanceof PluginArtifactTransferError)) throw error;
      }
    }
    output.sort((left, right) => left.id.localeCompare(right.id));
    return Object.freeze(output);
  }

  plan(
    incoming: readonly PluginTransferArtifact[],
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
    development: readonly { readonly fingerprint: string; readonly id: string; readonly syncRevision: number }[] = [],
  ): readonly PluginTransferPlanItem[] {
    validateArtifactBatch(incoming);
    return this.#planVersions(incoming, installed, development);
  }

  planOffers(
    incoming: readonly PluginTransferOffer[],
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
    development: readonly { readonly fingerprint: string; readonly id: string; readonly syncRevision: number }[] = [],
  ): readonly PluginTransferPlanItem[] {
    validateOfferBatch(incoming);
    return this.#planVersions(incoming, installed, development);
  }

  #planVersions(
    incoming: readonly PluginTransferOffer[],
    installed: readonly { readonly id: string; readonly activeVersion: string | null; readonly pendingVersion: string | null }[],
    development: readonly { readonly fingerprint: string; readonly id: string; readonly syncRevision: number }[],
  ): readonly PluginTransferPlanItem[] {
    const receiver = new Map(installed.map((item) => [item.id, item.activeVersion ?? item.pendingVersion]));
    const receiverDevelopment = new Map(development.map((item) => [item.id, item]));
    return Object.freeze(incoming.map((artifact) => {
      const current = receiver.get(artifact.id) ?? null;
      const liveDevelopment = receiverDevelopment.get(artifact.id);
      if (liveDevelopment !== undefined) {
        // A live development project is the receiver's source of truth for
        // this ID. Only the exact same development build can be treated as
        // already present; installed packages and other development builds
        // must never replace it, even when their SemVer is higher.
        const sameBuild = artifact.provenance !== "installed" &&
          artifact.developmentFingerprint === liveDevelopment.fingerprint;
        const action = sameBuild ? "same" : "developmentConflict";
        return Object.freeze({ action, id: artifact.id, receiverVersion: current, version: artifact.version });
      }
      if (artifact.provenance !== "installed") {
        const currentDevelopment = current === null ? undefined : parseDevelopmentVersion(current);
        const action = current === null
          ? "missing"
          : currentDevelopment?.fingerprint === artifact.developmentFingerprint
            ? "same"
            : currentDevelopment !== undefined
              ? artifact.developmentRevision! > currentDevelopment.revision ? "upgrade" : "receiverNewer"
              : artifact.provenance === "development" ? "upgrade" : compareSemver(artifact.version, current) > 0 ? "upgrade" : "receiverNewer";
        return Object.freeze({ action, id: artifact.id, receiverVersion: current, version: artifact.version });
      }
      const comparison = current === null ? 1 : compareSemver(artifact.version, current);
      const action = current === null ? "missing" : comparison > 0 ? "upgrade" : comparison === 0 ? "same" : "receiverNewer";
      return Object.freeze({ action, id: artifact.id, receiverVersion: current, version: artifact.version });
    }));
  }

  async createResource(
    id: string,
    version: string,
    development?: DevelopmentTransferProject,
  ): Promise<{ readonly artifact: PluginTransferArtifact; readonly token: string }> {
    if (!isPluginId(id) || parseSemver(version) === null) throw new PluginArtifactTransferError("invalid_request");
    let entry = this.#development.get(key(id, version));
    if (entry === undefined && development !== undefined && development.id === id &&
        developmentVersion(development.version, development.syncRevision, development.fingerprint) === version) {
      await mkdir(this.#stagingRoot, { recursive: true });
      entry = await this.#buildDevelopment(development, version, "development");
      this.#development.set(key(id, version), entry);
    }
    if (entry === undefined) {
      const retained = await findRetainedArtifact(this.#dataRoot, id, version);
      if (retained === undefined) throw new PluginArtifactTransferError("plugin_transfer_artifact_missing");
      if (retained.bytes > MAX_PLUGIN_ARTIFACT_BYTES) throw new PluginArtifactTransferError("plugin_transfer_artifact_too_large");
      entry = Object.freeze({
        artifact: Object.freeze({
          bytes: retained.bytes,
          ...developmentMetadataForVersion(version),
          format: retained.format,
          id,
          sha256: await hashFile(retained.path),
          version,
        }),
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
    const entry = await this.#buildDevelopment(project, project.version, "installed");
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

  async #buildDevelopment(
    project: DevelopmentTransferProject,
    version: string,
    provenance: "development" | "installed",
  ): Promise<TransferEntry> {
    const format: PluginArtifactFormat = project.packageMode === "single-file" ? "singleFile" : "archive";
    const extension = format === "singleFile" ? ".mgplugin.js" : ".mgplugin";
    const path = resolve(this.#stagingRoot, `${project.id}-${randomUUID()}${extension}`);
    try {
      const tool = await import(pathToFileURL(resolve(project.projectRoot, "tools", "mgread.mjs")).href) as Record<string, unknown>;
      if (typeof tool.buildPluginArtifact !== "function") {
        throw developmentBuildError(project, version, "build_export_missing");
      }
      const built = await (tool.buildPluginArtifact as (input: { versionOverride: string }) => unknown)({ versionOverride: version });
      if (!isBuildResult(built)) {
        throw developmentBuildError(project, version, "build_result_invalid");
      }
      if (built.format !== format || !built.fileName.endsWith(extension)) {
        throw developmentBuildError(project, version, "build_format_mismatch");
      }
      if (built.bytes.byteLength > MAX_PLUGIN_ARTIFACT_BYTES) {
        throw new PluginArtifactTransferError(
          "plugin_transfer_artifact_too_large",
          developmentBuildDetail(project, version, "artifact_too_large"),
        );
      }
      if (project.fingerprint !== await developmentProjectFingerprint(project.projectRoot)) {
        throw developmentBuildError(project, version, "source_changed_during_build");
      }
      await writeFile(path, built.bytes, { flag: "wx", mode: 0o444 });
      const artifact = Object.freeze({
        bytes: built.bytes.byteLength,
        developmentFingerprint: provenance === "development" ? project.fingerprint : null,
        developmentRevision: provenance === "development" ? project.syncRevision : null,
        format,
        id: project.id,
        provenance,
        sha256: sha256(built.bytes),
        version,
      });
      return Object.freeze({ artifact, expiresAt: Number.MAX_SAFE_INTEGER, path });
    } catch (error) {
      await rm(path, { force: true });
      if (error instanceof PluginArtifactTransferError) throw error;
      throw developmentBuildError(project, version, buildFailureReason(error));
    }
  }
}

function developmentBuildError(
  project: DevelopmentTransferProject,
  version: string,
  reason: string,
): PluginArtifactTransferError {
  return new PluginArtifactTransferError(
    "plugin_transfer_build_failed",
    developmentBuildDetail(project, version, reason),
  );
}

function developmentBuildDetail(
  project: DevelopmentTransferProject,
  version: string,
  reason: string,
): string {
  return `pluginId=${project.id} version=${version} reason=${reason}`;
}

function buildFailureReason(error: unknown): string {
  if (isRecord(error) &&
      (error.code === "ERR_MODULE_NOT_FOUND" || error.code === "ENOENT")) {
    return "build_module_missing";
  }
  return "build_exception";
}

async function hasDevelopmentBuildEntry(
  project: DevelopmentTransferProject,
): Promise<boolean> {
  try {
    return (await stat(resolve(project.projectRoot, "tools", "mgread.mjs"))).isFile();
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
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

export function validateOfferBatch(offers: readonly PluginTransferOffer[]): void {
  if (offers.length > MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH) {
    throw new PluginArtifactTransferError("plugin_transfer_batch_too_large");
  }
  for (const offer of offers) {
    if (!isPluginTransferOffer(offer)) throw new PluginArtifactTransferError("invalid_request");
  }
}

export function isPluginTransferArtifact(value: unknown): value is PluginTransferArtifact {
  if (!isRecord(value) || Object.keys(value).length !== 8) return false;
  return isPluginId(value.id) && typeof value.version === "string" && parseSemver(value.version) !== null &&
    typeof value.bytes === "number" && Number.isSafeInteger(value.bytes) && value.bytes > 0 && value.bytes <= MAX_PLUGIN_ARTIFACT_BYTES &&
    typeof value.sha256 === "string" && /^[a-f0-9]{64}$/.test(value.sha256) && (value.format === "archive" || value.format === "singleFile") &&
    (value.provenance === "installed" || value.provenance === "development" || value.provenance === "developmentReplica") &&
    ((value.provenance === "installed" && value.developmentFingerprint === null && value.developmentRevision === null) ||
      (value.provenance !== "installed" && typeof value.developmentFingerprint === "string" && /^[a-f0-9]{64}$/.test(value.developmentFingerprint) &&
        typeof value.developmentRevision === "number" && Number.isSafeInteger(value.developmentRevision) && value.developmentRevision > 0));
}

export function isPluginTransferOffer(value: unknown): value is PluginTransferOffer {
  if (!isRecord(value) || Object.keys(value).length !== 6) return false;
  return isPluginId(value.id) && typeof value.version === "string" && parseSemver(value.version) !== null &&
    (value.format === "archive" || value.format === "singleFile") &&
    (value.provenance === "installed" || value.provenance === "development" || value.provenance === "developmentReplica") &&
    ((value.provenance === "installed" && value.developmentFingerprint === null && value.developmentRevision === null) ||
      (value.provenance !== "installed" && typeof value.developmentFingerprint === "string" && /^[a-f0-9]{64}$/.test(value.developmentFingerprint) &&
        typeof value.developmentRevision === "number" && Number.isSafeInteger(value.developmentRevision) && value.developmentRevision > 0));
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
function developmentVersion(version: string, revision: number, fingerprint: string): string { const v = parseSemver(version); if (v === null || v.patch >= Number.MAX_SAFE_INTEGER || !Number.isSafeInteger(revision) || revision <= 0 || !/^[a-f0-9]{64}$/.test(fingerprint)) throw new PluginArtifactTransferError("invalid_request"); return `${v.major}.${v.minor}.${v.patch + 1}-devsync.${revision}.${fingerprint}`; }
function parseDevelopmentVersion(version: string): { readonly fingerprint: string; readonly revision: number } | undefined { const match = /^\d+\.\d+\.\d+-devsync\.(\d+)\.([a-f0-9]{64})$/.exec(version); const revision = match === null ? undefined : Number(match[1]); return match === null || !Number.isSafeInteger(revision) || revision! <= 0 ? undefined : { fingerprint: match[2]!, revision: revision! }; }
function developmentMetadataForVersion(version: string): Pick<PluginTransferArtifact, "developmentFingerprint" | "developmentRevision" | "provenance"> { const development = parseDevelopmentVersion(version); return development === undefined ? { developmentFingerprint: null, developmentRevision: null, provenance: "installed" } : { developmentFingerprint: development.fingerprint, developmentRevision: development.revision, provenance: "developmentReplica" }; }
function key(id: string, version: string): string { return `${id}\u001f${version}`; }
function isPluginId(value: unknown): value is string { return typeof value === "string" && /^[a-z0-9][a-z0-9.-]{0,127}$/.test(value); }
function isArtifactName(value: string): boolean { return value.endsWith(".mgplugin") || value.endsWith(".mgplugin.js"); }
function formatForPath(path: string): PluginArtifactFormat { return path.endsWith(".mgplugin.js") ? "singleFile" : "archive"; }
function isMissing(error: unknown): boolean { return isRecord(error) && error.code === "ENOENT"; }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
