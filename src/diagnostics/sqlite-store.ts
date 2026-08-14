import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";

import {
  type RuntimeDiagnosticAttachmentChunk,
  type RuntimeDiagnosticAttachmentDescriptor,
  type RuntimeDiagnosticAttachmentRange,
  type RuntimeDiagnosticCapturePolicy,
  type RuntimeDiagnosticCaptureState,
  type RuntimeDiagnosticEvent,
  type RuntimeDiagnosticEventFilter,
  type RuntimeDiagnosticPage,
  type RuntimeDiagnosticPayloadKind,
  type RuntimeDiagnosticPrivacyClass,
  type RuntimeDiagnosticSession,
  type RuntimeDiagnosticSessionFilter,
  type RuntimeDiagnosticSessionState,
  type RuntimeDiagnosticSeverity,
  validateRuntimeDiagnosticCapturePolicy,
  validateRuntimeDiagnosticName,
  validateRuntimeDiagnosticOpaqueId,
} from "./contracts.js";
import {
  RuntimeDiagnosticObjectStore,
  type RuntimeDiagnosticStoredObject,
} from "./object-store.js";

const schemaVersion = 1;
const maximumPageSize = 200;
const maximumSingleAttachmentBytes = 16 * 1024 * 1024;
const severityOrder = Object.freeze([
  "trace",
  "debug",
  "info",
  "warn",
  "error",
  "fatal",
] satisfies readonly RuntimeDiagnosticSeverity[]);

export interface RuntimeDiagnosticsStoreOptions {
  readonly clock?: () => Date;
  readonly dataRoot: string;
  readonly sourceRunId: string;
}

export interface RuntimeDiagnosticAttachmentWrite {
  readonly charset?: string;
  readonly chunks: AsyncIterable<Uint8Array>;
  readonly completion?: () => {
    readonly captureState?: RuntimeDiagnosticCaptureState;
    readonly rawByteLength: number;
    readonly truncationReason?: string;
  };
  readonly declaredRawByteLength?: number;
  readonly eventId: string;
  readonly formatId: string;
  readonly formatVersion: number;
  readonly kind: string;
  readonly mediaType: string;
  readonly privacyClass: RuntimeDiagnosticPrivacyClass;
  readonly redactionVersion: number;
  readonly sanitizeText: boolean;
  readonly schemaId?: string;
  readonly schemaVersion?: number;
}

export interface RuntimeDiagnosticsStorageStatistics {
  readonly attachmentCount: number;
  readonly eventCount: number;
  readonly indexBytes: number;
  readonly logicalStoredBytes: number;
  readonly objectBytes: number;
  readonly objectCount: number;
  readonly runCount: number;
  readonly sessionCount: number;
  readonly walBytes: number;
}

export interface RuntimeDiagnosticsRetentionPolicy {
  readonly captureBytes: number;
  readonly captureMaxAgeMicros: number;
  readonly globalHardBytes: number;
  readonly regularEventBytes: number;
  readonly regularEventMaxAgeMicros: number;
}

export interface RuntimeDiagnosticsMaintenanceResult {
  readonly deletedEvents: number;
  readonly deletedObjects: number;
  readonly deletedSessions: number;
  readonly reclaimedBytes: number;
}

interface StoredCapturePolicy {
  readonly components: ReadonlySet<string>;
  readonly maxStoredBytes: number;
  readonly origins: ReadonlySet<string>;
  readonly session: RuntimeDiagnosticSession;
}

/** Runtime-owned SQLite index and immutable attachment object lifecycle. */
export class RuntimeDiagnosticsStore {
  readonly #clock: () => Date;
  readonly #database: DatabaseSync;
  readonly #databasePath: string;
  readonly #defaultSessionId: string;
  readonly #objectStore: RuntimeDiagnosticObjectStore;
  readonly #sourceRunId: string;
  #closed = false;

  private constructor(
    database: DatabaseSync,
    databasePath: string,
    objectStore: RuntimeDiagnosticObjectStore,
    sourceRunId: string,
    clock: () => Date,
  ) {
    this.#database = database;
    this.#databasePath = databasePath;
    this.#objectStore = objectStore;
    this.#sourceRunId = sourceRunId;
    this.#defaultSessionId = `default-${sourceRunId}`;
    this.#clock = clock;
  }

  static async open(options: RuntimeDiagnosticsStoreOptions): Promise<RuntimeDiagnosticsStore> {
    validateRuntimeDiagnosticOpaqueId(options.sourceRunId, "sourceRunId");
    const diagnosticsRoot = join(options.dataRoot, "diagnostics");
    await mkdir(diagnosticsRoot, { recursive: true });
    const objectStore = await RuntimeDiagnosticObjectStore.open(diagnosticsRoot);
    const databasePath = join(diagnosticsRoot, "index.sqlite");
    const database = new DatabaseSync(databasePath, {
      enableDoubleQuotedStringLiterals: false,
      enableForeignKeyConstraints: true,
    });
    const store = new RuntimeDiagnosticsStore(
      database,
      databasePath,
      objectStore,
      options.sourceRunId,
      options.clock ?? utcNow,
    );
    try {
      store.#configureAndCreateSchema();
      store.#recoverInterruptedState();
      await store.reconcileObjects();
      store.#startRun();
      return store;
    } catch (error) {
      database.close();
      throw error;
    }
  }

  get defaultSessionId(): string {
    return this.#defaultSessionId;
  }

  get sourceRunId(): string {
    return this.#sourceRunId;
  }

  appendEvents(events: readonly RuntimeDiagnosticEvent[]): void {
    this.#ensureOpen();
    if (events.length === 0) return;
    if (events.length > 128) throw new RangeError("Diagnostic write batches are limited to 128 events.");
    const insert = this.#database.prepare(`
      INSERT INTO diagnostic_events (
        event_id, source_run_id, capture_session_id, source_sequence,
        occurred_at_utc_micros, monotonic_offset_micros, severity, component,
        event_name, event_schema_version, trace_id, span_id, parent_span_id,
        phase, outcome, duration_micros, summary, attachment_count,
        captured_bytes, envelope_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    const sessionTotals = new Map<string, { bytes: number; count: number }>();
    let runBytes = 0;
    this.#transaction(() => {
      for (const event of events) {
        if (event.sourceRunId !== this.#sourceRunId || event.source !== "runtime") {
          throw new TypeError("A Runtime store accepts only its current source run.");
        }
        validateRuntimeDiagnosticOpaqueId(event.eventId, "eventId");
        validateRuntimeDiagnosticOpaqueId(event.captureSessionId, "captureSessionId");
        const encoded = JSON.stringify(event);
        const encodedBytes = Buffer.byteLength(encoded, "utf8");
        insert.run(
          event.eventId,
          event.sourceRunId,
          event.captureSessionId,
          event.sourceSequence,
          event.occurredAtUtcMicros,
          event.monotonicOffsetMicros,
          severityIndex(event.severity),
          event.component,
          event.eventName,
          event.eventSchemaVersion,
          event.traceId ?? null,
          event.spanId ?? null,
          event.parentSpanId ?? null,
          event.phase,
          event.outcome ?? null,
          event.durationMicros ?? null,
          event.summary,
          event.attachmentCount,
          event.capturedBytes,
          encoded,
        );
        const total = sessionTotals.get(event.captureSessionId) ?? { bytes: 0, count: 0 };
        total.bytes += encodedBytes;
        total.count += 1;
        sessionTotals.set(event.captureSessionId, total);
        runBytes += encodedBytes;
      }
      const updateSession = this.#database.prepare(`
        UPDATE diagnostic_capture_sessions
        SET event_count = event_count + ?, stored_bytes = stored_bytes + ?
        WHERE session_id = ?
      `);
      for (const [sessionId, total] of sessionTotals) {
        updateSession.run(total.count, total.bytes, sessionId);
      }
      this.#database.prepare(`
        UPDATE diagnostic_runs
        SET event_count = event_count + ?, stored_bytes = stored_bytes + ?
        WHERE source_run_id = ?
      `).run(events.length, runBytes, this.#sourceRunId);
    });
  }

  createCaptureSession(
    sessionId: string,
    policy: RuntimeDiagnosticCapturePolicy,
  ): RuntimeDiagnosticSession {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(sessionId, "sessionId");
    validateRuntimeDiagnosticCapturePolicy(policy);
    const existing = this.#database.prepare(`
      SELECT session_id FROM diagnostic_capture_sessions
      WHERE state = 'active' AND is_default = 0 LIMIT 1
    `).get();
    if (existing !== undefined) throw new Error("A Runtime capture session is already active.");
    const started = this.#clock().getTime() * 1_000;
    const expires = started + policy.durationMillis * 1_000;
    this.#database.prepare(`
      INSERT INTO diagnostic_capture_sessions (
        session_id, source_run_id, payload_kind, state,
        started_at_utc_micros, expires_at_utc_micros, max_stored_bytes,
        component_allowlist_json, origin_allowlist_json, is_default
      ) VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?, 0)
    `).run(
      sessionId,
      this.#sourceRunId,
      policy.payloadKind,
      started,
      expires,
      policy.maxStoredBytes,
      JSON.stringify([...policy.components].sort()),
      JSON.stringify([...policy.origins].sort()),
    );
    return Object.freeze({
      attachmentCount: 0,
      eventCount: 0,
      expiresAtUtcMicros: expires,
      payloadKind: policy.payloadKind,
      sessionId,
      source: "runtime",
      sourceRunId: this.#sourceRunId,
      startedAtUtcMicros: started,
      state: "active",
      storedBytes: 0,
    });
  }

  stopCaptureSession(sessionId: string, state: "ended" | "expired" = "ended"): void {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(sessionId, "sessionId");
    const result = this.#database.prepare(`
      UPDATE diagnostic_capture_sessions
      SET state = ?, ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
      WHERE session_id = ? AND is_default = 0 AND state = 'active'
    `).run(state, this.#clock().getTime() * 1_000, sessionId);
    if (result.changes === 0) throw new Error("The Runtime capture session is not active.");
  }

  getActiveCapturePolicy(): StoredCapturePolicy | undefined {
    this.#ensureOpen();
    const row = this.#database.prepare(`
      SELECT * FROM diagnostic_capture_sessions
      WHERE state = 'active' AND is_default = 0
      ORDER BY started_at_utc_micros DESC LIMIT 1
    `).get();
    if (row === undefined) return undefined;
    const session = decodeSession(row);
    const now = this.#clock().getTime() * 1_000;
    if (session.expiresAtUtcMicros !== undefined && session.expiresAtUtcMicros <= now) {
      this.stopCaptureSession(session.sessionId, "expired");
      return undefined;
    }
    return Object.freeze({
      components: decodeStringSet(readString(row, "component_allowlist_json")),
      maxStoredBytes: readInteger(row, "max_stored_bytes"),
      origins: decodeStringSet(readString(row, "origin_allowlist_json")),
      session,
    });
  }

  resolveCaptureSession(component: string, origin?: string): string {
    const active = this.getActiveCapturePolicy();
    if (active === undefined || active.session.payloadKind === "metadataOnly") {
      return this.#defaultSessionId;
    }
    const componentAllowed = active.components.size === 0 || active.components.has(component);
    const originAllowed =
      active.origins.size === 0 || (origin !== undefined && active.origins.has(origin));
    return componentAllowed && originAllowed
      ? active.session.sessionId
      : this.#defaultSessionId;
  }

  async captureAttachment(
    input: RuntimeDiagnosticAttachmentWrite,
  ): Promise<RuntimeDiagnosticAttachmentDescriptor> {
    this.#ensureOpen();
    validateAttachmentInput(input);
    const eventRow = this.#database.prepare(`
      SELECT capture_session_id FROM diagnostic_events WHERE event_id = ?
    `).get(input.eventId);
    if (eventRow === undefined) throw new Error("Diagnostic attachment event does not exist.");
    const sessionId = readString(eventRow, "capture_session_id");
    const sessionRow = this.#database.prepare(`
      SELECT * FROM diagnostic_capture_sessions WHERE session_id = ?
    `).get(sessionId);
    if (sessionRow === undefined) throw new Error("Diagnostic capture session does not exist.");
    const payloadKind = readString(sessionRow, "payload_kind") as RuntimeDiagnosticPayloadKind;
    const state = readString(sessionRow, "state") as RuntimeDiagnosticSessionState;
    const isDefault = readInteger(sessionRow, "is_default") !== 0;
    const remaining = Math.max(
      0,
      readInteger(sessionRow, "max_stored_bytes") - readInteger(sessionRow, "stored_bytes"),
    );
    const policyBlocked =
      isDefault ||
      state !== "active" ||
      payloadKind === "metadataOnly" ||
      payloadKind === "restrictedRaw" ||
      input.privacyClass === "secret" ||
      input.privacyClass === "restricted" ||
      (payloadKind === "safeStructured" && input.formatId !== "mgread.diagnostic-tree") ||
      remaining <= 0;
    if (policyBlocked) {
      return this.#recordAttachment(
        input,
        undefined,
        "policyBlocked",
        remaining <= 0 ? "sessionQuota" : "capturePolicy",
      );
    }
    const stored = await this.#objectStore.writeStream(input.chunks, {
      maxStoredBytes: Math.min(remaining, maximumSingleAttachmentBytes),
      privacyClass: input.privacyClass,
      sanitizeText: input.sanitizeText,
    });
    const completion = input.completion?.();
    const captureState = completion?.captureState ?? stored.captureState;
    const truncationReason = completion?.truncationReason ?? stored.truncationReason;
    return this.#recordAttachment(
      completion === undefined
        ? input
        : { ...input, declaredRawByteLength: completion.rawByteLength },
      stored,
      captureState,
      truncationReason,
    );
  }

  listSessions(
    filter: RuntimeDiagnosticSessionFilter = {},
    cursor?: string,
    limit = 100,
  ): RuntimeDiagnosticPage<RuntimeDiagnosticSession> {
    this.#ensureOpen();
    validateLimit(limit);
    const where: string[] = [];
    const parameters: SQLInputValue[] = [];
    if (filter.states !== undefined && filter.states.size > 0) {
      where.push(`state IN (${placeholders(filter.states.size)})`);
      parameters.push(...filter.states);
    }
    if (filter.startedAfterUtcMicros !== undefined) {
      where.push("started_at_utc_micros >= ?");
      parameters.push(filter.startedAfterUtcMicros);
    }
    if (filter.startedBeforeUtcMicros !== undefined) {
      where.push("started_at_utc_micros <= ?");
      parameters.push(filter.startedBeforeUtcMicros);
    }
    if (cursor !== undefined) {
      const [micros, id] = decodeCursor(cursor, "session");
      where.push("(started_at_utc_micros < ? OR (started_at_utc_micros = ? AND session_id < ?))");
      parameters.push(micros, micros, id);
    }
    const rows = this.#database.prepare(`
      SELECT * FROM diagnostic_capture_sessions
      ${where.length === 0 ? "" : `WHERE ${where.join(" AND ")}`}
      ORDER BY started_at_utc_micros DESC, session_id DESC LIMIT ?
    `).all(...parameters, limit + 1);
    const hasNext = rows.length > limit;
    const selected = rows.slice(0, limit).map(decodeSession);
    const last = selected.at(-1);
    return Object.freeze({
      items: Object.freeze(selected),
      ...(hasNext && last !== undefined
        ? { nextCursor: encodeCursor("session", last.startedAtUtcMicros, last.sessionId) }
        : {}),
    });
  }

  listEvents(
    filter: RuntimeDiagnosticEventFilter,
    cursor?: string,
    limit = 100,
  ): RuntimeDiagnosticPage<RuntimeDiagnosticEvent> {
    this.#ensureOpen();
    validateLimit(limit);
    const where: string[] = [];
    const parameters: SQLInputValue[] = [];
    if (filter.sessionId !== undefined) {
      validateRuntimeDiagnosticOpaqueId(filter.sessionId, "sessionId");
      where.push("capture_session_id = ?");
      parameters.push(filter.sessionId);
    }
    if (filter.traceId !== undefined) {
      validateRuntimeDiagnosticOpaqueId(filter.traceId, "traceId");
      where.push("trace_id = ?");
      parameters.push(filter.traceId);
    }
    if (filter.minimumSeverity !== undefined) {
      where.push("severity >= ?");
      parameters.push(severityIndex(filter.minimumSeverity));
    }
    appendStringSet(where, parameters, "component", filter.components);
    appendStringSet(where, parameters, "event_name", filter.eventNames);
    if (filter.occurredAfterUtcMicros !== undefined) {
      where.push("occurred_at_utc_micros >= ?");
      parameters.push(filter.occurredAfterUtcMicros);
    }
    if (filter.occurredBeforeUtcMicros !== undefined) {
      where.push("occurred_at_utc_micros <= ?");
      parameters.push(filter.occurredBeforeUtcMicros);
    }
    if (cursor !== undefined) {
      const [micros, id] = decodeCursor(cursor, "event");
      where.push("(occurred_at_utc_micros < ? OR (occurred_at_utc_micros = ? AND event_id < ?))");
      parameters.push(micros, micros, id);
    }
    const rows = this.#database.prepare(`
      SELECT envelope_json FROM diagnostic_events
      ${where.length === 0 ? "" : `WHERE ${where.join(" AND ")}`}
      ORDER BY occurred_at_utc_micros DESC, event_id DESC LIMIT ?
    `).all(...parameters, limit + 1);
    const hasNext = rows.length > limit;
    const selected = rows.slice(0, limit).map((row) => decodeEvent(readString(row, "envelope_json")));
    const last = selected.at(-1);
    return Object.freeze({
      items: Object.freeze(selected),
      ...(hasNext && last !== undefined
        ? { nextCursor: encodeCursor("event", last.occurredAtUtcMicros, last.eventId) }
        : {}),
    });
  }

  getEvent(eventId: string): RuntimeDiagnosticEvent | undefined {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(eventId, "eventId");
    const row = this.#database.prepare(
      "SELECT envelope_json FROM diagnostic_events WHERE event_id = ?",
    ).get(eventId);
    return row === undefined ? undefined : decodeEvent(readString(row, "envelope_json"));
  }

  listAttachments(eventId: string): readonly RuntimeDiagnosticAttachmentDescriptor[] {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(eventId, "eventId");
    return Object.freeze(
      this.#database.prepare(`
        SELECT descriptor_json FROM diagnostic_attachments
        WHERE event_id = ? ORDER BY attachment_id ASC
      `).all(eventId).map((row) => decodeAttachment(readString(row, "descriptor_json"))),
    );
  }

  async readAttachment(
    attachmentId: string,
    range: RuntimeDiagnosticAttachmentRange,
  ): Promise<RuntimeDiagnosticAttachmentChunk> {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(attachmentId, "attachmentId");
    const row = this.#database.prepare(`
      SELECT object_key, stored_byte_length FROM diagnostic_attachments
      WHERE attachment_id = ?
    `).get(attachmentId);
    if (row === undefined) throw new Error("Diagnostic attachment does not exist.");
    const objectKey = row.object_key;
    if (typeof objectKey !== "string") throw new Error("Diagnostic attachment payload was not captured.");
    const result = await this.#objectStore.readRange(objectKey, range);
    const nextOffset = range.offset + result.bytes.byteLength;
    return Object.freeze({
      bytesBase64: Buffer.from(result.bytes).toString("base64"),
      eof: nextOffset >= result.totalBytes,
      nextOffset,
      totalStoredBytes: result.totalBytes,
    });
  }

  async reconcileObjects(): Promise<void> {
    this.#ensureOpen();
    const references = this.#database.prepare(`
      SELECT object_key, COUNT(*) AS actual_count FROM diagnostic_attachments
      WHERE object_key IS NOT NULL GROUP BY object_key
    `).all();
    const referenced = new Set<string>();
    const update = this.#database.prepare(
      "UPDATE diagnostic_objects SET reference_count = ? WHERE object_key = ?",
    );
    for (const row of references) {
      const objectKey = readString(row, "object_key");
      referenced.add(objectKey);
      update.run(readInteger(row, "actual_count"), objectKey);
    }
    const indexedRows = this.#database.prepare(
      "SELECT object_key FROM diagnostic_objects",
    ).all();
    const indexed = new Set(indexedRows.map((row) => readString(row, "object_key")));
    for (const objectKey of indexed) {
      if (referenced.has(objectKey)) continue;
      await this.#objectStore.delete(objectKey);
      this.#database.prepare(
        "DELETE FROM diagnostic_objects WHERE object_key = ?",
      ).run(objectKey);
    }
    const physical = await this.#objectStore.listObjectKeys();
    for (const objectKey of physical) {
      if (!indexed.has(objectKey)) await this.#objectStore.delete(objectKey);
    }
  }

  async deleteSession(sessionId: string): Promise<RuntimeDiagnosticsMaintenanceResult> {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(sessionId, "sessionId");
    const session = this.#database.prepare(`
      SELECT source_run_id, state, is_default FROM diagnostic_capture_sessions
      WHERE session_id = ?
    `).get(sessionId);
    if (session === undefined) return emptyMaintenanceResult;
    if (readString(session, "state") === "active") {
      throw new Error("An active diagnostic session cannot be deleted.");
    }
    const isDefault = readInteger(session, "is_default") !== 0;
    const sourceRunId = readString(session, "source_run_id");
    const eventRow = this.#database.prepare(
      isDefault
        ? "SELECT COUNT(*) AS count FROM diagnostic_events WHERE source_run_id = ?"
        : "SELECT COUNT(*) AS count FROM diagnostic_events WHERE capture_session_id = ?",
    ).get(isDefault ? sourceRunId : sessionId);
    const sessionRow = this.#database.prepare(
      isDefault
        ? "SELECT COUNT(*) AS count FROM diagnostic_capture_sessions WHERE source_run_id = ?"
        : "SELECT 1 AS count",
    ).get(...(isDefault ? [sourceRunId] : []));
    const before = await this.getStatistics();
    this.#transaction(() => {
      if (isDefault) {
        this.#database.prepare("DELETE FROM diagnostic_runs WHERE source_run_id = ?").run(sourceRunId);
      } else {
        this.#database.prepare("DELETE FROM diagnostic_capture_sessions WHERE session_id = ?").run(sessionId);
      }
    });
    await this.reconcileObjects();
    const after = await this.getStatistics();
    return Object.freeze({
      deletedEvents: eventRow === undefined ? 0 : readInteger(eventRow, "count"),
      deletedObjects: Math.max(0, before.objectCount - after.objectCount),
      deletedSessions: sessionRow === undefined ? 0 : readInteger(sessionRow, "count"),
      reclaimedBytes: Math.max(0, before.objectBytes - after.objectBytes),
    });
  }

  async enforceRetention(
    policy: RuntimeDiagnosticsRetentionPolicy,
  ): Promise<RuntimeDiagnosticsMaintenanceResult> {
    this.#ensureOpen();
    validateRetentionPolicy(policy);
    const now = this.#clock().getTime() * 1_000;
    const expired = this.#database.prepare(`
      SELECT session_id FROM diagnostic_capture_sessions
      WHERE state != 'active' AND (
        (is_default = 1 AND started_at_utc_micros <= ?)
        OR (is_default = 0 AND COALESCE(ended_at_utc_micros, started_at_utc_micros) <= ?)
      ) ORDER BY started_at_utc_micros ASC
    `).all(
      now - policy.regularEventMaxAgeMicros,
      now - policy.captureMaxAgeMicros,
    );
    let total: RuntimeDiagnosticsMaintenanceResult = { ...emptyMaintenanceResult };
    for (const row of expired) {
      total = addMaintenance(total, await this.deleteSession(readString(row, "session_id")));
    }
    total = await this.#trimSessions("is_default = 0", policy.captureBytes, total);
    total = await this.#trimSessions("is_default = 1", policy.regularEventBytes, total);
    total = await this.#trimSessions("1 = 1", policy.globalHardBytes, total);
    this.checkpointWal();
    return Object.freeze(total);
  }

  async getStatistics(): Promise<RuntimeDiagnosticsStorageStatistics> {
    this.#ensureOpen();
    const scalar = (sql: string): number => {
      const row = this.#database.prepare(sql).get();
      if (row === undefined) return 0;
      const value = Object.values(row)[0];
      return typeof value === "bigint" ? Number(value) : typeof value === "number" ? value : 0;
    };
    const indexBytes = await fileSize(this.#databasePath);
    const walBytes = await fileSize(`${this.#databasePath}-wal`);
    return Object.freeze({
      attachmentCount: scalar("SELECT COUNT(*) FROM diagnostic_attachments"),
      eventCount: scalar("SELECT COUNT(*) FROM diagnostic_events"),
      indexBytes,
      logicalStoredBytes: scalar("SELECT COALESCE(SUM(stored_bytes), 0) FROM diagnostic_runs"),
      objectBytes: scalar("SELECT COALESCE(SUM(stored_byte_length), 0) FROM diagnostic_objects"),
      objectCount: scalar("SELECT COUNT(*) FROM diagnostic_objects"),
      runCount: scalar("SELECT COUNT(*) FROM diagnostic_runs"),
      sessionCount: scalar("SELECT COUNT(*) FROM diagnostic_capture_sessions"),
      walBytes,
    });
  }

  checkpointWal(): void {
    this.#ensureOpen();
    this.#database.prepare("PRAGMA wal_checkpoint(PASSIVE)").all();
  }

  close(outcome: "completed" | "incomplete" = "completed"): void {
    if (this.#closed) return;
    this.#closed = true;
    try {
      const ended = this.#clock().getTime() * 1_000;
      this.#database.prepare(`
        UPDATE diagnostic_capture_sessions
        SET state = 'ended', ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
        WHERE source_run_id = ? AND state = 'active'
      `).run(ended, this.#sourceRunId);
      this.#database.prepare(`
        UPDATE diagnostic_runs SET state = ?, ended_at_utc_micros = ?
        WHERE source_run_id = ?
      `).run(outcome, ended, this.#sourceRunId);
      this.#database.prepare("PRAGMA wal_checkpoint(PASSIVE)").all();
    } finally {
      this.#database.close();
    }
  }

  #configureAndCreateSchema(): void {
    this.#database.exec("PRAGMA journal_mode = WAL");
    this.#database.exec("PRAGMA synchronous = NORMAL");
    this.#database.exec("PRAGMA busy_timeout = 5000");
    this.#database.exec(`
      CREATE TABLE IF NOT EXISTS diagnostic_schema (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        schema_version INTEGER NOT NULL
      );
      INSERT OR IGNORE INTO diagnostic_schema (singleton, schema_version) VALUES (1, ${schemaVersion});
    `);
    const versionRow = this.#database.prepare(
      "SELECT schema_version FROM diagnostic_schema WHERE singleton = 1",
    ).get();
    if (versionRow === undefined || readInteger(versionRow, "schema_version") !== schemaVersion) {
      throw new Error("Runtime diagnostics schema is newer or requires migration.");
    }
    this.#database.exec(`
      CREATE TABLE IF NOT EXISTS diagnostic_runs (
        source_run_id TEXT PRIMARY KEY NOT NULL,
        started_at_utc_micros INTEGER NOT NULL,
        ended_at_utc_micros INTEGER,
        state TEXT NOT NULL,
        event_count INTEGER NOT NULL DEFAULT 0,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        stored_bytes INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS diagnostic_capture_sessions (
        session_id TEXT PRIMARY KEY NOT NULL,
        source_run_id TEXT NOT NULL REFERENCES diagnostic_runs(source_run_id) ON DELETE CASCADE,
        payload_kind TEXT NOT NULL,
        state TEXT NOT NULL,
        started_at_utc_micros INTEGER NOT NULL,
        ended_at_utc_micros INTEGER,
        expires_at_utc_micros INTEGER,
        max_stored_bytes INTEGER NOT NULL,
        stored_bytes INTEGER NOT NULL DEFAULT 0,
        event_count INTEGER NOT NULL DEFAULT 0,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        component_allowlist_json TEXT NOT NULL,
        origin_allowlist_json TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS diagnostic_events (
        event_id TEXT PRIMARY KEY NOT NULL,
        source_run_id TEXT NOT NULL REFERENCES diagnostic_runs(source_run_id) ON DELETE CASCADE,
        capture_session_id TEXT NOT NULL REFERENCES diagnostic_capture_sessions(session_id) ON DELETE CASCADE,
        source_sequence INTEGER NOT NULL,
        occurred_at_utc_micros INTEGER NOT NULL,
        monotonic_offset_micros INTEGER NOT NULL,
        severity INTEGER NOT NULL,
        component TEXT NOT NULL,
        event_name TEXT NOT NULL,
        event_schema_version INTEGER NOT NULL,
        trace_id TEXT,
        span_id TEXT,
        parent_span_id TEXT,
        phase TEXT NOT NULL,
        outcome TEXT,
        duration_micros INTEGER,
        summary TEXT NOT NULL,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        captured_bytes INTEGER NOT NULL DEFAULT 0,
        envelope_json TEXT NOT NULL,
        UNIQUE(source_run_id, source_sequence)
      );
      CREATE TABLE IF NOT EXISTS diagnostic_objects (
        object_key TEXT PRIMARY KEY NOT NULL,
        sha256 TEXT NOT NULL,
        privacy_class TEXT NOT NULL,
        storage_codec TEXT NOT NULL,
        stored_byte_length INTEGER NOT NULL,
        reference_count INTEGER NOT NULL,
        created_at_utc_micros INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS diagnostic_attachments (
        attachment_id TEXT PRIMARY KEY NOT NULL,
        event_id TEXT NOT NULL REFERENCES diagnostic_events(event_id) ON DELETE CASCADE,
        object_key TEXT REFERENCES diagnostic_objects(object_key),
        stored_byte_length INTEGER NOT NULL,
        descriptor_json TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS diagnostic_sessions_time
        ON diagnostic_capture_sessions(started_at_utc_micros DESC, session_id DESC);
      CREATE INDEX IF NOT EXISTS diagnostic_events_session_time
        ON diagnostic_events(capture_session_id, occurred_at_utc_micros DESC, event_id DESC);
      CREATE INDEX IF NOT EXISTS diagnostic_events_trace_time
        ON diagnostic_events(trace_id, occurred_at_utc_micros, event_id);
      CREATE INDEX IF NOT EXISTS diagnostic_events_severity_time
        ON diagnostic_events(severity, occurred_at_utc_micros DESC);
      CREATE INDEX IF NOT EXISTS diagnostic_events_component_name_time
        ON diagnostic_events(component, event_name, occurred_at_utc_micros DESC);
    `);
  }

  #recoverInterruptedState(): void {
    const now = this.#clock().getTime() * 1_000;
    this.#transaction(() => {
      this.#database.prepare(`
        UPDATE diagnostic_capture_sessions
        SET state = 'ended', ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
        WHERE state = 'active'
      `).run(now);
      this.#database.prepare(`
        UPDATE diagnostic_runs
        SET state = 'incomplete', ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
        WHERE state = 'active'
      `).run(now);
    });
  }

  #startRun(): void {
    const started = this.#clock().getTime() * 1_000;
    this.#transaction(() => {
      this.#database.prepare(`
        INSERT INTO diagnostic_runs (source_run_id, started_at_utc_micros, state)
        VALUES (?, ?, 'active')
      `).run(this.#sourceRunId, started);
      this.#database.prepare(`
        INSERT INTO diagnostic_capture_sessions (
          session_id, source_run_id, payload_kind, state,
          started_at_utc_micros, max_stored_bytes,
          component_allowlist_json, origin_allowlist_json, is_default
        ) VALUES (?, ?, 'metadataOnly', 'active', ?, ?, '[]', '[]', 1)
      `).run(this.#defaultSessionId, this.#sourceRunId, started, 32 * 1024 * 1024);
    });
  }

  #recordAttachment(
    input: RuntimeDiagnosticAttachmentWrite,
    stored: RuntimeDiagnosticStoredObject | undefined,
    captureState: RuntimeDiagnosticCaptureState,
    truncationReason?: string,
  ): RuntimeDiagnosticAttachmentDescriptor {
    const attachmentId = `attachment-${randomUUID()}`;
    const rawByteLength = input.declaredRawByteLength ?? stored?.rawByteLength ?? 0;
    const storedByteLength = stored?.storedByteLength ?? 0;
    const descriptor: RuntimeDiagnosticAttachmentDescriptor = Object.freeze({
      attachmentId,
      captureState,
      ...(input.charset === undefined ? {} : { charset: input.charset }),
      eventId: input.eventId,
      formatId: input.formatId,
      formatVersion: input.formatVersion,
      kind: input.kind,
      mediaType: input.mediaType,
      privacyClass: input.privacyClass,
      rawByteLength,
      redactionVersion: input.redactionVersion,
      ...(input.schemaId === undefined ? {} : { schemaId: input.schemaId }),
      ...(input.schemaVersion === undefined ? {} : { schemaVersion: input.schemaVersion }),
      ...(stored === undefined ? {} : { sha256: stored.sha256 }),
      storageCodec: "identity",
      storedByteLength,
      ...(truncationReason === undefined ? {} : { truncationReason }),
    });
    this.#transaction(() => {
      if (stored !== undefined) {
        this.#database.prepare(`
          INSERT INTO diagnostic_objects (
            object_key, sha256, privacy_class, storage_codec,
            stored_byte_length, reference_count, created_at_utc_micros
          ) VALUES (?, ?, ?, 'identity', ?, 1, ?)
          ON CONFLICT(object_key) DO UPDATE SET reference_count = reference_count + 1
        `).run(
          stored.objectKey,
          stored.sha256,
          input.privacyClass,
          stored.storedByteLength,
          this.#clock().getTime() * 1_000,
        );
      }
      this.#database.prepare(`
        INSERT INTO diagnostic_attachments (
          attachment_id, event_id, object_key, stored_byte_length, descriptor_json
        ) VALUES (?, ?, ?, ?, ?)
      `).run(
        attachmentId,
        input.eventId,
        stored?.objectKey ?? null,
        storedByteLength,
        JSON.stringify(descriptor),
      );
      const eventRow = this.#database.prepare(`
        SELECT envelope_json, capture_session_id, source_run_id
        FROM diagnostic_events WHERE event_id = ?
      `).get(input.eventId);
      if (eventRow === undefined) throw new Error("Diagnostic attachment event disappeared.");
      const event = decodeEvent(readString(eventRow, "envelope_json"));
      const updated: RuntimeDiagnosticEvent = Object.freeze({
        ...event,
        attachmentCount: event.attachmentCount + 1,
        capturedBytes: event.capturedBytes + storedByteLength,
      });
      this.#database.prepare(`
        UPDATE diagnostic_events SET attachment_count = ?, captured_bytes = ?, envelope_json = ?
        WHERE event_id = ?
      `).run(updated.attachmentCount, updated.capturedBytes, JSON.stringify(updated), input.eventId);
      const sessionId = readString(eventRow, "capture_session_id");
      this.#database.prepare(`
        UPDATE diagnostic_capture_sessions SET
          attachment_count = attachment_count + 1,
          stored_bytes = stored_bytes + ? WHERE session_id = ?
      `).run(storedByteLength, sessionId);
      this.#database.prepare(`
        UPDATE diagnostic_runs SET
          attachment_count = attachment_count + 1,
          stored_bytes = stored_bytes + ? WHERE source_run_id = ?
      `).run(storedByteLength, readString(eventRow, "source_run_id"));
    });
    return descriptor;
  }

  async #trimSessions(
    where: string,
    byteLimit: number,
    initial: RuntimeDiagnosticsMaintenanceResult,
  ): Promise<RuntimeDiagnosticsMaintenanceResult> {
    let total = { ...initial };
    while (true) {
      const aggregate = this.#database.prepare(`
        SELECT COALESCE(SUM(stored_bytes), 0) AS total
        FROM diagnostic_capture_sessions WHERE ${where}
      `).get();
      if (aggregate === undefined || readInteger(aggregate, "total") <= byteLimit) break;
      const oldest = this.#database.prepare(`
        SELECT session_id FROM diagnostic_capture_sessions
        WHERE state != 'active' AND ${where}
        ORDER BY started_at_utc_micros ASC, session_id ASC LIMIT 1
      `).get();
      if (oldest === undefined) break;
      total = addMaintenance(total, await this.deleteSession(readString(oldest, "session_id")));
    }
    return total;
  }

  #transaction<T>(operation: () => T): T {
    this.#database.exec("BEGIN IMMEDIATE");
    try {
      const result = operation();
      this.#database.exec("COMMIT");
      return result;
    } catch (error) {
      this.#database.exec("ROLLBACK");
      throw error;
    }
  }

  #ensureOpen(): void {
    if (this.#closed || !this.#database.isOpen) throw new Error("Runtime diagnostics store is closed.");
  }
}

const emptyMaintenanceResult = Object.freeze({
  deletedEvents: 0,
  deletedObjects: 0,
  deletedSessions: 0,
  reclaimedBytes: 0,
});

function validateAttachmentInput(input: RuntimeDiagnosticAttachmentWrite): void {
  validateRuntimeDiagnosticOpaqueId(input.eventId, "eventId");
  validateRuntimeDiagnosticName(input.kind, "attachment kind");
  validateRuntimeDiagnosticName(input.formatId, "attachment formatId");
  if (
    !Number.isSafeInteger(input.formatVersion) || input.formatVersion <= 0 ||
    !Number.isSafeInteger(input.redactionVersion) || input.redactionVersion <= 0 ||
    (input.schemaVersion !== undefined &&
      (!Number.isSafeInteger(input.schemaVersion) || input.schemaVersion <= 0)) ||
    (input.declaredRawByteLength !== undefined &&
      (!Number.isSafeInteger(input.declaredRawByteLength) || input.declaredRawByteLength < 0))
  ) {
    throw new RangeError("Diagnostic attachment metadata is invalid.");
  }
  if (input.mediaType.length === 0 || input.mediaType.length > 256) {
    throw new RangeError("Diagnostic attachment media type is invalid.");
  }
}

function decodeEvent(encoded: string): RuntimeDiagnosticEvent {
  const value = JSON.parse(encoded) as unknown;
  if (typeof value !== "object" || value === null) throw new TypeError("Invalid diagnostic event envelope.");
  const event = value as RuntimeDiagnosticEvent;
  if (
    !Number.isSafeInteger(event.envelopeVersion) || event.envelopeVersion <= 0 ||
    event.source !== "runtime" || typeof event.eventId !== "string" ||
    typeof event.eventName !== "string" || typeof event.component !== "string" ||
    typeof event.summary !== "string"
  ) {
    throw new TypeError("Invalid diagnostic event envelope.");
  }
  return Object.freeze(event);
}

function decodeAttachment(encoded: string): RuntimeDiagnosticAttachmentDescriptor {
  const value = JSON.parse(encoded) as unknown;
  if (typeof value !== "object" || value === null) {
    throw new TypeError("Invalid diagnostic attachment descriptor.");
  }
  return Object.freeze(value as RuntimeDiagnosticAttachmentDescriptor);
}

function decodeSession(row: Record<string, unknown>): RuntimeDiagnosticSession {
  const ended = readOptionalInteger(row, "ended_at_utc_micros");
  const expires = readOptionalInteger(row, "expires_at_utc_micros");
  return Object.freeze({
    attachmentCount: readInteger(row, "attachment_count"),
    ...(ended === undefined ? {} : { endedAtUtcMicros: ended }),
    eventCount: readInteger(row, "event_count"),
    ...(expires === undefined ? {} : { expiresAtUtcMicros: expires }),
    payloadKind: readString(row, "payload_kind") as RuntimeDiagnosticPayloadKind,
    sessionId: readString(row, "session_id"),
    source: "runtime",
    sourceRunId: readString(row, "source_run_id"),
    startedAtUtcMicros: readInteger(row, "started_at_utc_micros"),
    state: readString(row, "state") as RuntimeDiagnosticSessionState,
    storedBytes: readInteger(row, "stored_bytes"),
  });
}

function readString(row: Record<string, unknown>, key: string): string {
  const value = row[key];
  if (typeof value !== "string") throw new TypeError(`Diagnostic row ${key} must be text.`);
  return value;
}

function readInteger(row: Record<string, unknown>, key: string): number {
  const value = row[key];
  const number = typeof value === "bigint" ? Number(value) : value;
  if (typeof number !== "number" || !Number.isSafeInteger(number)) {
    throw new TypeError(`Diagnostic row ${key} must be a safe integer.`);
  }
  return number;
}

function readOptionalInteger(row: Record<string, unknown>, key: string): number | undefined {
  return row[key] === null || row[key] === undefined ? undefined : readInteger(row, key);
}

function severityIndex(severity: RuntimeDiagnosticSeverity): number {
  const index = severityOrder.indexOf(severity);
  if (index < 0) throw new TypeError("Unknown Runtime diagnostic severity.");
  return index;
}

function validateLimit(limit: number): void {
  if (!Number.isSafeInteger(limit) || limit <= 0 || limit > maximumPageSize) {
    throw new RangeError(`Diagnostic page limits must be between 1 and ${maximumPageSize}.`);
  }
}

function placeholders(count: number): string {
  return new Array<string>(count).fill("?").join(", ");
}

function appendStringSet(
  where: string[],
  parameters: SQLInputValue[],
  column: string,
  values?: ReadonlySet<string>,
): void {
  if (values === undefined || values.size === 0) return;
  for (const value of values) validateRuntimeDiagnosticName(value, column);
  where.push(`${column} IN (${placeholders(values.size)})`);
  parameters.push(...values);
}

function encodeCursor(kind: "event" | "session", micros: number, id: string): string {
  return Buffer.from(JSON.stringify([kind, micros, id]), "utf8").toString("base64url");
}

function decodeCursor(cursor: string, kind: "event" | "session"): readonly [number, string] {
  if (!/^[A-Za-z0-9_-]{8,512}$/.test(cursor)) throw new TypeError("Invalid diagnostic cursor.");
  const decoded = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as unknown;
  if (
    !Array.isArray(decoded) || decoded.length !== 3 || decoded[0] !== kind ||
    !Number.isSafeInteger(decoded[1]) || typeof decoded[2] !== "string"
  ) {
    throw new TypeError("Diagnostic cursor does not match the query.");
  }
  return [decoded[1] as number, decoded[2]];
}

function decodeStringSet(encoded: string): ReadonlySet<string> {
  const value = JSON.parse(encoded) as unknown;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new TypeError("Invalid diagnostic allowlist.");
  }
  return new Set(value as string[]);
}

function validateRetentionPolicy(policy: RuntimeDiagnosticsRetentionPolicy): void {
  if (
    Object.values(policy).some((value) => !Number.isSafeInteger(value) || value <= 0) ||
    policy.regularEventBytes > policy.globalHardBytes ||
    policy.captureBytes > policy.globalHardBytes
  ) {
    throw new RangeError("Runtime diagnostics retention policy is invalid.");
  }
}

function addMaintenance(
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

async function fileSize(path: string): Promise<number> {
  if (!existsSync(path)) return 0;
  return (await stat(path)).size;
}

function utcNow(): Date {
  return new Date();
}
