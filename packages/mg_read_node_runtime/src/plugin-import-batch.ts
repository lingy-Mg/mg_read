/**
 * Shared desktop/Android import directory contract and preflight.
 * Host-owned .part directories stay invisible to cold startup until one rename.
 * Verify every artifact's bytes and embedded identity before the first install;
 * never evaluate plugin code. Failed/published batches are consumed by the inbox.
 */
import { createReadStream } from "node:fs";
import { lstat, mkdtemp, readFile, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { extractPluginArchive } from "./plugin-archive.js";
import { parsePluginSingleFile } from "./plugin-single-file.js";
import { readPluginProject } from "./plugin-package.js";
import { crc32Update } from "./lan-sync-checksum.js";
import { PluginArtifactTransferError, validateArtifactBatch, type PluginTransferArtifact } from "./plugin-artifact-transfer.js";

export interface PluginImportBatchEntry {
  readonly artifact: PluginTransferArtifact;
  readonly path: string;
}

export function importBatchDirectory(inbox: string, id: string, staged: boolean): string {
  if (!/^[a-f0-9]{32}$/.test(id)) throw new PluginArtifactTransferError("invalid_request");
  return resolve(inbox, staged ? `.batch-${id}.part` : `batch-${id}`);
}

export async function verifyPluginImportBatch(
  inbox: string, id: string, staged: boolean, expected?: readonly PluginTransferArtifact[],
): Promise<readonly PluginImportBatchEntry[]> {
  const root = importBatchDirectory(inbox, id, staged);
  if (!(await lstat(root)).isDirectory()) throw new PluginArtifactTransferError("invalid_request");
  const manifestPath = resolve(root, "manifest.json");
  const metadata = await lstat(manifestPath);
  if (!metadata.isFile() || metadata.size > 8 * 1024 * 1024) throw new PluginArtifactTransferError("invalid_request");
  const manifest: unknown = JSON.parse(await readFile(manifestPath, "utf8"));
  if (!isObject(manifest) || manifest.schemaVersion !== 1 || !Array.isArray(manifest.artifacts)) {
    throw new PluginArtifactTransferError("invalid_request");
  }
  const raw = manifest.artifacts;
  const artifacts = raw.map((entry: unknown) => {
    if (!isObject(entry)) throw new PluginArtifactTransferError("invalid_request");
    const {file: _file, ...artifact} = entry;
    return artifact as PluginTransferArtifact;
  });
  validateArtifactBatch(artifacts);
  if (expected !== undefined && (expected.length !== artifacts.length || artifacts.some((artifact, index) => {
    const candidate = expected[index]!;
    return artifact.id !== candidate.id || artifact.version !== candidate.version || artifact.bytes !== candidate.bytes ||
      artifact.format !== candidate.format || artifact.checksum !== candidate.checksum || artifact.provenance !== candidate.provenance ||
      artifact.developmentFingerprint !== candidate.developmentFingerprint || artifact.developmentRevision !== candidate.developmentRevision;
  }))) throw new PluginArtifactTransferError("plugin_transfer_checksum_mismatch");

  const entries: PluginImportBatchEntry[] = [];
  for (let index = 0; index < artifacts.length; index++) {
    const artifact = artifacts[index]!;
    const file = `${index}${artifact.format === "singleFile" ? ".mgplugin.js" : ".mgplugin"}`;
    if (raw[index].file !== file) throw new PluginArtifactTransferError("invalid_request");
    const path = resolve(root, `${file}${staged ? ".part" : ""}`);
    const stat = await lstat(path);
    if (!stat.isFile() || stat.size !== artifact.bytes) throw new PluginArtifactTransferError("plugin_transfer_size_mismatch");
    let crc = 0xffffffff;
    for await (const chunk of createReadStream(path, {highWaterMark: 64 * 1024})) crc = crc32Update(crc, chunk);
    if (((crc ^ 0xffffffff) >>> 0).toString(16).padStart(8, "0") !== artifact.checksum) {
      throw new PluginArtifactTransferError("plugin_transfer_checksum_mismatch");
    }
    await verifyPluginArtifactIdentity(path, artifact);
    entries.push({artifact, path});
  }
  return entries;
}

export async function verifyPluginArtifactIdentity(path: string, expected: Pick<PluginTransferArtifact, "id" | "version" | "format">): Promise<void> {
  let actual: {readonly id: string; readonly version: string};
  if (expected.format === "singleFile") {
    const descriptor = (await parsePluginSingleFile(path)).descriptor;
    actual = {id: descriptor.mgread.id, version: descriptor.version};
  }
  else {
    const scratch = await mkdtemp(resolve(dirname(path), ".artifact-check-"));
    try {
      await extractPluginArchive(path, scratch);
      actual = (await readPluginProject(scratch)).descriptor;
    } finally { await rm(scratch, {force: true, recursive: true}); }
  }
  if (actual.id !== expected.id || actual.version !== expected.version) {
    throw new PluginArtifactTransferError("plugin_transfer_checksum_mismatch");
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
