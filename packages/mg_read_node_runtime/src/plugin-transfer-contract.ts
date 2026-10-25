/**
 * Leaf contract shared by transfer planning and import-batch verification.
 * Owns value types, limits, error identity and pure descriptor validation.
 * Must never import transfer managers or batch IO. Keep the static Core graph
 * acyclic for Android Javet; Node-only tests do not validate that boundary.
 */
import type { createReadStream } from "node:fs";
import type { JsonObject } from "./protocol.js";
import { MAX_PLUGIN_ARTIFACT_BYTES, type PluginArtifactFormat } from "./plugin-single-file.js";

export const MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH_BYTES = 512 * 1024 * 1024;

export interface PluginTransferArtifact extends JsonObject {
  readonly bytes: number;
  readonly developmentFingerprint: string | null;
  readonly developmentRevision: number | null;
  readonly format: PluginArtifactFormat;
  readonly id: string;
  readonly provenance: "development" | "developmentReplica" | "installed";
  readonly checksum: string;
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
  readonly checksum: string;
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

export function validateArtifactBatch(artifacts: readonly PluginTransferArtifact[]): void {
  let bytes = 0;
  for (const artifact of artifacts) {
    if (!isPluginTransferArtifact(artifact)) throw new PluginArtifactTransferError("invalid_request");
    bytes += artifact.bytes;
    if (bytes > MAX_PLUGIN_ARTIFACT_TRANSFER_BATCH_BYTES) throw new PluginArtifactTransferError("plugin_transfer_batch_too_large");
  }
}

export function validateOfferBatch(offers: readonly PluginTransferOffer[]): void {
  for (const offer of offers) {
    if (!isPluginTransferOffer(offer)) throw new PluginArtifactTransferError("invalid_request");
  }
}

export function isPluginTransferArtifact(value: unknown): value is PluginTransferArtifact {
  if (!isRecord(value) || Object.keys(value).length !== 8) return false;
  return isPluginId(value.id) && typeof value.version === "string" && parseSemver(value.version) !== null &&
    typeof value.bytes === "number" && Number.isSafeInteger(value.bytes) && value.bytes > 0 && value.bytes <= MAX_PLUGIN_ARTIFACT_BYTES &&
    typeof value.checksum === "string" && /^[a-f0-9]{8}$/.test(value.checksum) && (value.format === "archive" || value.format === "singleFile") &&
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

export interface Semver { major: number; minor: number; patch: number; prerelease: string[] }
export function parseSemver(value: string): Semver | null { const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(value); return m === null ? null : { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), prerelease: m[4]?.split(".") ?? [] }; }

export function isPluginId(value: unknown): value is string { return typeof value === "string" && /^[a-z0-9][a-z0-9.-]{0,127}$/.test(value); }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
