/** Runtime diagnostics TXT record codec and retention helpers. */
import { rm } from "node:fs/promises";
import { join } from "node:path";
import {
  type RuntimeDiagnosticAttachmentDescriptor,
  type RuntimeDiagnosticCaptureState,
  type RuntimeDiagnosticDetailStorage,
  type RuntimeDiagnosticEvent,
  type RuntimeDiagnosticEventFilter,
  type RuntimeDiagnosticPage,
  type RuntimeDiagnosticPayloadKind,
  type RuntimeDiagnosticPrivacyClass,
  type RuntimeDiagnosticSession,
  type RuntimeDiagnosticSessionFilter,
  type RuntimeDiagnosticSessionState,
  type RuntimeDiagnosticSeverity,
  validateRuntimeDiagnosticName,
  validateRuntimeDiagnosticOpaqueId,
} from "./contracts.js";
import type {
  RuntimeDiagnosticAttachmentWrite,
  RuntimeDiagnosticsMaintenanceResult,
  RuntimeDiagnosticsRetentionPolicy,
} from "./text-store.js";

export const textFormatVersion = 1;
export const maximumPageSize = 200;
export const severityOrder = Object.freeze(["trace", "debug", "info", "warn", "error", "fatal"] satisfies readonly RuntimeDiagnosticSeverity[]);

export interface StoredCapturePolicy {
  readonly components: ReadonlySet<string>;
  readonly detailStorage: RuntimeDiagnosticDetailStorage;
  readonly maxStoredBytes: number;
  readonly origins: ReadonlySet<string>;
  readonly session: RuntimeDiagnosticSession;
}

export interface RunRecord {
  attachmentCount: number;
  endedAtUtcMicros?: number;
  eventCount: number;
  sourceRunId: string;
  startedAtUtcMicros: number;
  state: "active" | "completed" | "incomplete";
  storedBytes: number;
}

export interface SessionRecord {
  readonly components: ReadonlySet<string>;
  readonly detailStorage: RuntimeDiagnosticDetailStorage;
  readonly isDefault: boolean;
  readonly maxStoredBytes: number;
  readonly origins: ReadonlySet<string>;
  session: RuntimeDiagnosticSession;
}

export interface AttachmentRecord {
  readonly descriptor: RuntimeDiagnosticAttachmentDescriptor;
  readonly detailKey?: string;
  readonly persisted: boolean;
}

export type TextRecord = Readonly<Record<string, unknown>>;
export const emptyMaintenanceResult = Object.freeze({
  deletedEvents: 0,
  deletedObjects: 0,
  deletedSessions: 0,
  reclaimedBytes: 0,
} satisfies RuntimeDiagnosticsMaintenanceResult);

export function baseRecord(recordType: string): TextRecord {
  return Object.freeze({ recordType, textFormatVersion });
}

export function runStartRecord(run: RunRecord): TextRecord {
  return Object.freeze({
    ...baseRecord("run.start"),
    sourceRunId: run.sourceRunId,
    startedAtUtcMicros: run.startedAtUtcMicros,
  });
}

export function runEndRecord(
  sourceRunId: string,
  endedAtUtcMicros: number,
  state: string,
): TextRecord {
  return Object.freeze({
    ...baseRecord("run.end"),
    endedAtUtcMicros,
    sourceRunId,
    state,
  });
}

export function sessionStartRecord(record: SessionRecord): TextRecord {
  return Object.freeze({
    ...baseRecord("session.start"),
    components: [...record.components].sort(),
    detailStorage: record.detailStorage,
    expiresAtUtcMicros: record.session.expiresAtUtcMicros ?? null,
    isDefault: record.isDefault,
    maxStoredBytes: record.maxStoredBytes,
    origins: [...record.origins].sort(),
    payloadKind: record.session.payloadKind,
    sessionId: record.session.sessionId,
    sourceRunId: record.session.sourceRunId,
    startedAtUtcMicros: record.session.startedAtUtcMicros,
  });
}

export function sessionEndRecord(
  sessionId: string,
  endedAtUtcMicros: number,
  state: string,
): TextRecord {
  return Object.freeze({
    ...baseRecord("session.end"),
    endedAtUtcMicros,
    sessionId,
    state,
  });
}

export function attachmentRecord(record: AttachmentRecord): TextRecord {
  return Object.freeze({
    ...baseRecord("attachment"),
    descriptor: record.descriptor,
    detailKey: record.detailKey ?? null,
    persisted: record.persisted,
  });
}

export function encodeRecord(record: TextRecord): string {
  return JSON.stringify(record);
}

export function decodeSessionStart(record: TextRecord): SessionRecord {
  const expires = record.expiresAtUtcMicros;
  const payloadKind = readString(record, "payloadKind") as RuntimeDiagnosticPayloadKind;
  const detailStorage = readString(record, "detailStorage") as RuntimeDiagnosticDetailStorage;
  return {
    components: decodeStringSet(record.components),
    detailStorage,
    isDefault: record.isDefault === true,
    maxStoredBytes: readInteger(record, "maxStoredBytes"),
    origins: decodeStringSet(record.origins),
    session: freezeSession({
      attachmentCount: 0,
      eventCount: 0,
      ...(typeof expires === "number" ? { expiresAtUtcMicros: expires } : {}),
      payloadKind,
      sessionId: readString(record, "sessionId"),
      source: "runtime",
      sourceRunId: readString(record, "sourceRunId"),
      startedAtUtcMicros: readInteger(record, "startedAtUtcMicros"),
      state: "active",
      storedBytes: 0,
    }),
  };
}

export function decodeEvent(value: unknown): RuntimeDiagnosticEvent {
  if (!isRecord(value)) throw new TypeError("Invalid diagnostic event envelope.");
  validateRuntimeDiagnosticOpaqueId(readString(value, "eventId"), "eventId");
  validateRuntimeDiagnosticOpaqueId(readString(value, "sourceRunId"), "sourceRunId");
  return Object.freeze(value as unknown as RuntimeDiagnosticEvent);
}

export function decodeAttachment(value: unknown): RuntimeDiagnosticAttachmentDescriptor {
  if (!isRecord(value)) throw new TypeError("Invalid diagnostic attachment descriptor.");
  validateRuntimeDiagnosticOpaqueId(readString(value, "attachmentId"), "attachmentId");
  validateRuntimeDiagnosticOpaqueId(readString(value, "eventId"), "eventId");
  return Object.freeze(value as unknown as RuntimeDiagnosticAttachmentDescriptor);
}

export function failedExpiredMemoryDescriptor(
  descriptor: RuntimeDiagnosticAttachmentDescriptor,
): RuntimeDiagnosticAttachmentDescriptor {
  return Object.freeze({
    ...descriptor,
    captureState: "failed",
    storedByteLength: 0,
    truncationReason: "memoryDetailExpired",
  });
}

export function freezeSession(session: RuntimeDiagnosticSession): RuntimeDiagnosticSession {
  return Object.freeze(session);
}

export function updateSession(
  session: RuntimeDiagnosticSession,
  changes: Partial<RuntimeDiagnosticSession>,
): RuntimeDiagnosticSession {
  return Object.freeze({ ...session, ...changes });
}

export function matchesSession(
  session: RuntimeDiagnosticSession,
  filter: RuntimeDiagnosticSessionFilter,
): boolean {
  if (filter.states !== undefined && filter.states.size > 0 && !filter.states.has(session.state)) {
    return false;
  }
  if (filter.startedAfterUtcMicros !== undefined &&
    session.startedAtUtcMicros < filter.startedAfterUtcMicros) return false;
  if (filter.startedBeforeUtcMicros !== undefined &&
    session.startedAtUtcMicros > filter.startedBeforeUtcMicros) return false;
  return true;
}

export function matchesEvent(
  event: RuntimeDiagnosticEvent,
  filter: RuntimeDiagnosticEventFilter,
): boolean {
  if (filter.sessionId !== undefined && event.captureSessionId !== filter.sessionId) return false;
  if (filter.traceId !== undefined && event.traceId !== filter.traceId) return false;
  if (filter.minimumSeverity !== undefined &&
    severityIndex(event.severity) < severityIndex(filter.minimumSeverity)) return false;
  if (filter.components !== undefined && filter.components.size > 0 &&
    !filter.components.has(event.component)) return false;
  if (filter.eventNames !== undefined && filter.eventNames.size > 0 &&
    !filter.eventNames.has(event.eventName)) return false;
  if (filter.occurredAfterUtcMicros !== undefined &&
    event.occurredAtUtcMicros < filter.occurredAfterUtcMicros) return false;
  if (filter.occurredBeforeUtcMicros !== undefined &&
    event.occurredAtUtcMicros > filter.occurredBeforeUtcMicros) return false;
  return true;
}

export function pageResult<T>(
  items: readonly T[],
  limit: number,
  cursor: (item: T) => string,
): RuntimeDiagnosticPage<T> {
  const hasNext = items.length > limit;
  const selected = items.slice(0, limit);
  const last = selected.at(-1);
  return Object.freeze({
    items: Object.freeze(selected),
    ...(hasNext && last !== undefined ? { nextCursor: cursor(last) } : {}),
  });
}

export function compareDescending(
  leftTime: number,
  leftId: string,
  rightTime: number,
  rightId: string,
): number {
  return rightTime - leftTime || rightId.localeCompare(leftId);
}

export function isBeforeAnchor(
  micros: number,
  id: string,
  anchor: readonly [number, string],
): boolean {
  return micros < anchor[0] || (micros === anchor[0] && id.localeCompare(anchor[1]) < 0);
}

export function encodeCursor(kind: "event" | "session", micros: number, id: string): string {
  return Buffer.from(JSON.stringify([kind, micros, id]), "utf8").toString("base64url");
}

export function decodeCursor(
  cursor: string,
  kind: "event" | "session",
): readonly [number, string] {
  if (!/^[A-Za-z0-9_-]{8,512}$/.test(cursor)) throw new TypeError("Invalid diagnostic cursor.");
  const value: unknown = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
  if (!Array.isArray(value) || value.length !== 3 || value[0] !== kind ||
    typeof value[1] !== "number" || typeof value[2] !== "string") {
    throw new TypeError("Invalid diagnostic cursor.");
  }
  return [value[1], value[2]];
}

export function validateAttachmentInput(input: RuntimeDiagnosticAttachmentWrite): void {
  validateRuntimeDiagnosticOpaqueId(input.eventId, "eventId");
  validateRuntimeDiagnosticName(input.kind, "attachment kind");
  validateRuntimeDiagnosticName(input.formatId, "attachment formatId");
  if (!Number.isSafeInteger(input.formatVersion) || input.formatVersion <= 0 ||
    !Number.isSafeInteger(input.redactionVersion) || input.redactionVersion <= 0) {
    throw new RangeError("Diagnostic attachment versions must be positive integers.");
  }
}

export function isTextMediaType(mediaType: string): boolean {
  const normalized = mediaType.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  return normalized.startsWith("text/") ||
    normalized === "application/json" ||
    normalized.endsWith("+json") ||
    normalized === "application/xml" ||
    normalized.endsWith("+xml") ||
    normalized === "application/x-www-form-urlencoded" ||
    normalized === "application/javascript";
}

export function addByteTrimTargets(
  targets: Set<string>,
  sessions: readonly SessionRecord[],
  byteLimit: number,
): void {
  let total = sessions.reduce((sum, item) => sum + item.session.storedBytes, 0);
  const ended = sessions
    .filter((item) => item.session.state !== "active")
    .sort((left, right) =>
      left.session.startedAtUtcMicros - right.session.startedAtUtcMicros);
  for (const session of ended) {
    if (total <= byteLimit) break;
    if (targets.has(session.session.sessionId)) continue;
    targets.add(session.session.sessionId);
    total -= session.session.storedBytes;
  }
}

export function addMaintenance(
  left: RuntimeDiagnosticsMaintenanceResult,
  right: RuntimeDiagnosticsMaintenanceResult,
): RuntimeDiagnosticsMaintenanceResult {
  return {
    deletedEvents: left.deletedEvents + right.deletedEvents,
    deletedObjects: left.deletedObjects + right.deletedObjects,
    deletedSessions: left.deletedSessions + right.deletedSessions,
    reclaimedBytes: left.reclaimedBytes + right.reclaimedBytes,
  };
}

export function validateRetentionPolicy(policy: RuntimeDiagnosticsRetentionPolicy): void {
  if (Object.values(policy).some((value) => !Number.isSafeInteger(value) || value <= 0) ||
    policy.captureBytes > policy.globalHardBytes ||
    policy.regularEventBytes > policy.globalHardBytes) {
    throw new RangeError("Runtime diagnostics retention policy is invalid.");
  }
}

export function validateLimit(limit: number): void {
  if (!Number.isSafeInteger(limit) || limit <= 0 || limit > maximumPageSize) {
    throw new RangeError("Diagnostic query limit must be between 1 and 200.");
  }
}

export function severityIndex(value: RuntimeDiagnosticSeverity): number {
  const index = severityOrder.indexOf(value);
  if (index < 0) throw new TypeError("Unknown Runtime diagnostic severity.");
  return index;
}

export function decodeSessionState(value: string): RuntimeDiagnosticSessionState {
  if (["active", "ended", "expired", "deleting", "deleted"].includes(value)) {
    return value as RuntimeDiagnosticSessionState;
  }
  throw new TypeError("Unknown Runtime diagnostic session state.");
}

export function decodeStringSet(value: unknown): ReadonlySet<string> {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new TypeError("Invalid diagnostic allowlist.");
  }
  return new Set(value as string[]);
}

export function readString(record: TextRecord, key: string): string {
  const value = record[key];
  if (typeof value !== "string") throw new TypeError(`Diagnostic ${key} must be a string.`);
  return value;
}

export function readInteger(record: TextRecord, key: string): number {
  const value = record[key];
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw new TypeError(`Diagnostic ${key} must be an integer.`);
  }
  return value;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function removeLegacyDiagnostics(diagnosticsRoot: string): Promise<void> {
  await Promise.all([
    "index.sqlite",
    "index.sqlite-wal",
    "index.sqlite-shm",
    "index.db",
    "index.db-wal",
    "index.db-shm",
  ].map((name) => rm(join(diagnosticsRoot, name), { force: true })));
  await Promise.all(["objects", "exports"].map((name) =>
    rm(join(diagnosticsRoot, name), { force: true, recursive: true })));
}

export function utcNow(): Date {
  return new Date();
}
