import { randomUUID } from "node:crypto";
import {
  appendFileSync,
  closeSync,
  existsSync,
  ftruncateSync,
  openSync,
  writeFileSync,
} from "node:fs";
import {
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

import {
  type RuntimeDiagnosticAttachmentChunk,
  type RuntimeDiagnosticAttachmentDescriptor,
  type RuntimeDiagnosticAttachmentRange,
  type RuntimeDiagnosticCapturePolicy,
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
  validateRuntimeDiagnosticCapturePolicy,
  validateRuntimeDiagnosticName,
  validateRuntimeDiagnosticOpaqueId,
} from "./contracts.js";
import {
  RuntimeDiagnosticTextDetailStore,
  type RuntimeDiagnosticStoredTextDetail,
} from "./text-detail-store.js";

import {
  addByteTrimTargets,
  addMaintenance,
  attachmentRecord,
  baseRecord,
  compareDescending,
  decodeAttachment,
  decodeCursor,
  decodeEvent,
  decodeSessionStart,
  decodeSessionState,
  emptyMaintenanceResult,
  encodeCursor,
  encodeRecord,
  failedExpiredMemoryDescriptor,
  freezeSession,
  isBeforeAnchor,
  isRecord,
  isTextMediaType,
  matchesEvent,
  matchesSession,
  pageResult,
  readInteger,
  readString,
  removeLegacyDiagnostics,
  runEndRecord,
  runStartRecord,
  sessionEndRecord,
  sessionStartRecord,
  severityIndex,
  updateSession,
  utcNow,
  validateAttachmentInput,
  validateLimit,
  validateRetentionPolicy,
  type AttachmentRecord,
  type RunRecord,
  type SessionRecord,
  type StoredCapturePolicy,
  type TextRecord,
} from "./text-store-support.js";

const textFormatVersion = 1;
const maximumPageSize = 200;
const maximumSegmentBytes = 4 * 1024 * 1024;
const maximumSingleAttachmentBytes = 8 * 1024 * 1024;
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
  readonly detailMemoryBytes?: number;
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
  readonly detailCount: number;
  readonly detailTextBytes: number;
  readonly eventCount: number;
  readonly eventTextBytes: number;
  readonly logicalStoredBytes: number;
  readonly memoryDetailBytes: number;
  readonly runCount: number;
  readonly segmentCount: number;
  readonly sessionCount: number;
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


/** Runtime-owned segmented TXT event and debug-detail lifecycle. */
export class RuntimeDiagnosticsStore {
  readonly #attachments = new Map<string, AttachmentRecord>();
  readonly #clock: () => Date;
  readonly #defaultSessionId: string;
  readonly #detailStore: RuntimeDiagnosticTextDetailStore;
  readonly #diagnosticsRoot: string;
  readonly #events = new Map<string, RuntimeDiagnosticEvent>();
  readonly #eventsRoot: string;
  readonly #runs = new Map<string, RunRecord>();
  readonly #segmentSequenceByRun = new Map<string, number>();
  readonly #sessions = new Map<string, SessionRecord>();
  readonly #sourceRunId: string;
  #activeSegmentBytes = 0;
  #activeSegmentPath: string | undefined;
  #activeSegmentRunId: string | undefined;
  #closed = false;

  private constructor(
    diagnosticsRoot: string,
    eventsRoot: string,
    detailStore: RuntimeDiagnosticTextDetailStore,
    sourceRunId: string,
    clock: () => Date,
  ) {
    this.#diagnosticsRoot = diagnosticsRoot;
    this.#eventsRoot = eventsRoot;
    this.#detailStore = detailStore;
    this.#sourceRunId = sourceRunId;
    this.#defaultSessionId = `default-${sourceRunId}`;
    this.#clock = clock;
  }

  static async open(options: RuntimeDiagnosticsStoreOptions): Promise<RuntimeDiagnosticsStore> {
    validateRuntimeDiagnosticOpaqueId(options.sourceRunId, "sourceRunId");
    const diagnosticsRoot = join(options.dataRoot, "diagnostics");
    const eventsRoot = join(diagnosticsRoot, "events");
    await mkdir(eventsRoot, { recursive: true });
    await removeLegacyDiagnostics(diagnosticsRoot);
    const detailStore = await RuntimeDiagnosticTextDetailStore.open(
      diagnosticsRoot,
      options.detailMemoryBytes ?? 8 * 1024 * 1024,
    );
    const store = new RuntimeDiagnosticsStore(
      diagnosticsRoot,
      eventsRoot,
      detailStore,
      options.sourceRunId,
      options.clock ?? utcNow,
    );
    await store.#loadCatalog();
    store.#recoverInterruptedState();
    await store.reconcileDetails();
    store.#startRun();
    return store;
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
    if (events.length > 128) {
      throw new RangeError("Diagnostic write batches are limited to 128 events.");
    }
    const lines: string[] = [];
    for (const event of events) {
      if (event.sourceRunId !== this.#sourceRunId || event.source !== "runtime") {
        throw new TypeError("A Runtime store accepts only its current source run.");
      }
      validateRuntimeDiagnosticOpaqueId(event.eventId, "eventId");
      validateRuntimeDiagnosticOpaqueId(event.captureSessionId, "captureSessionId");
      if (this.#events.has(event.eventId)) {
        throw new Error("Runtime diagnostic event already exists.");
      }
      lines.push(encodeRecord({ event, ...baseRecord("event") }));
    }
    this.#appendLines(this.#sourceRunId, lines);
    for (let index = 0; index < events.length; index += 1) {
      const event = events[index];
      const line = lines[index];
      if (event === undefined || line === undefined) continue;
      this.#events.set(event.eventId, event);
      const bytes = Buffer.byteLength(`${line}\n`, "utf8");
      const run = this.#runs.get(event.sourceRunId);
      if (run !== undefined) {
        run.eventCount += 1;
        run.storedBytes += bytes;
      }
      const session = this.#sessions.get(event.captureSessionId);
      if (session !== undefined) {
        session.session = updateSession(session.session, {
          eventCount: session.session.eventCount + 1,
          storedBytes: session.session.storedBytes + bytes,
        });
      }
    }
  }

  createCaptureSession(
    sessionId: string,
    policy: RuntimeDiagnosticCapturePolicy,
  ): RuntimeDiagnosticSession {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(sessionId, "sessionId");
    validateRuntimeDiagnosticCapturePolicy(policy);
    if ([...this.#sessions.values()].some(
      (item) => !item.isDefault && item.session.state === "active",
    )) {
      throw new Error("A Runtime capture session is already active.");
    }
    const started = this.#clock().getTime() * 1_000;
    const session = freezeSession({
      attachmentCount: 0,
      eventCount: 0,
      expiresAtUtcMicros: started + policy.durationMillis * 1_000,
      payloadKind: policy.payloadKind,
      sessionId,
      source: "runtime",
      sourceRunId: this.#sourceRunId,
      startedAtUtcMicros: started,
      state: "active",
      storedBytes: 0,
    });
    const record: SessionRecord = {
      components: new Set(policy.components),
      detailStorage: policy.detailStorage ?? "persistToText",
      isDefault: false,
      maxStoredBytes: policy.maxStoredBytes,
      origins: new Set(policy.origins),
      session,
    };
    this.#appendRecords(this.#sourceRunId, [sessionStartRecord(record)]);
    this.#sessions.set(sessionId, record);
    return session;
  }

  stopCaptureSession(sessionId: string, state: "ended" | "expired" = "ended"): void {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(sessionId, "sessionId");
    const stored = this.#sessions.get(sessionId);
    if (stored === undefined || stored.isDefault || stored.session.state !== "active") {
      throw new Error("The Runtime capture session is not active.");
    }
    const endedAtUtcMicros = this.#clock().getTime() * 1_000;
    this.#appendRecords(this.#sourceRunId, [
      sessionEndRecord(sessionId, endedAtUtcMicros, state),
    ]);
    stored.session = updateSession(stored.session, { endedAtUtcMicros, state });
    if (stored.detailStorage === "memoryOnly") {
      this.#detailStore.clearMemory(
        [...this.#attachments.values()]
          .filter((attachment) => {
            const event = this.#events.get(attachment.descriptor.eventId);
            return event?.captureSessionId === sessionId && !attachment.persisted;
          })
          .flatMap((attachment) => attachment.detailKey === undefined ? [] : [attachment.detailKey]),
      );
    }
  }

  getActiveCapturePolicy(): StoredCapturePolicy | undefined {
    this.#ensureOpen();
    const active = [...this.#sessions.values()]
      .filter((item) => !item.isDefault && item.session.state === "active")
      .sort((left, right) => right.session.startedAtUtcMicros - left.session.startedAtUtcMicros)[0];
    if (active === undefined) return undefined;
    const expires = active.session.expiresAtUtcMicros;
    if (expires !== undefined && expires <= this.#clock().getTime() * 1_000) {
      this.stopCaptureSession(active.session.sessionId, "expired");
      return undefined;
    }
    return Object.freeze({
      components: active.components,
      detailStorage: active.detailStorage,
      maxStoredBytes: active.maxStoredBytes,
      origins: active.origins,
      session: active.session,
    });
  }

  resolveCaptureSession(component: string, origin?: string): string {
    const active = this.getActiveCapturePolicy();
    if (active === undefined || active.session.payloadKind === "metadataOnly") {
      return this.#defaultSessionId;
    }
    const componentAllowed = active.components.size === 0 || active.components.has(component);
    const originAllowed = active.origins.size === 0 ||
      (origin !== undefined && active.origins.has(origin));
    return componentAllowed && originAllowed
      ? active.session.sessionId
      : this.#defaultSessionId;
  }

  async captureAttachment(
    input: RuntimeDiagnosticAttachmentWrite,
  ): Promise<RuntimeDiagnosticAttachmentDescriptor> {
    this.#ensureOpen();
    validateAttachmentInput(input);
    const event = this.#events.get(input.eventId);
    if (event === undefined) throw new Error("Diagnostic attachment event does not exist.");
    const session = this.#sessions.get(event.captureSessionId);
    if (session === undefined) throw new Error("Diagnostic capture session does not exist.");
    const remaining = Math.max(0, session.maxStoredBytes - session.session.storedBytes);
    const structuredAllowed = input.formatId === "mgread.diagnostic-tree" ||
      input.formatId === "json";
    const policyBlocked =
      session.isDefault ||
      session.session.state !== "active" ||
      session.session.payloadKind === "metadataOnly" ||
      session.session.payloadKind === "restrictedRaw" ||
      input.privacyClass === "secret" ||
      input.privacyClass === "restricted" ||
      !isTextMediaType(input.mediaType) ||
      (session.session.payloadKind === "safeStructured" && !structuredAllowed) ||
      remaining <= 0;
    const attachmentId = `attachment-${randomUUID()}`;
    if (policyBlocked) {
      return this.#recordAttachment(
        attachmentId,
        input,
        undefined,
        "policyBlocked",
        remaining <= 0 ? "sessionQuota" : "capturePolicy",
      );
    }
    const stored = await this.#detailStore.writeStream(
      attachmentId,
      input.chunks,
      {
        maxStoredBytes: Math.min(remaining, maximumSingleAttachmentBytes),
        persistToText: session.detailStorage === "persistToText",
        privacyClass: input.privacyClass,
        sanitizeText: input.sanitizeText,
      },
    );
    const completion = input.completion?.();
    return this.#recordAttachment(
      attachmentId,
      completion === undefined
        ? input
        : { ...input, declaredRawByteLength: completion.rawByteLength },
      stored,
      completion?.captureState ?? stored.captureState,
      completion?.truncationReason ?? stored.truncationReason,
    );
  }

  listSessions(
    filter: RuntimeDiagnosticSessionFilter = {},
    cursor?: string,
    limit = 100,
  ): RuntimeDiagnosticPage<RuntimeDiagnosticSession> {
    this.#ensureOpen();
    validateLimit(limit);
    const anchor = cursor === undefined ? undefined : decodeCursor(cursor, "session");
    const sessions = [...this.#sessions.values()]
      .map((item) => item.session)
      .filter((session) => matchesSession(session, filter))
      .filter((session) => anchor === undefined || isBeforeAnchor(
        session.startedAtUtcMicros,
        session.sessionId,
        anchor,
      ))
      .sort((left, right) => compareDescending(
        left.startedAtUtcMicros,
        left.sessionId,
        right.startedAtUtcMicros,
        right.sessionId,
      ));
    return pageResult(sessions, limit, (item) =>
      encodeCursor("session", item.startedAtUtcMicros, item.sessionId));
  }

  listEvents(
    filter: RuntimeDiagnosticEventFilter,
    cursor?: string,
    limit = 100,
  ): RuntimeDiagnosticPage<RuntimeDiagnosticEvent> {
    this.#ensureOpen();
    validateLimit(limit);
    if (filter.sessionId !== undefined) {
      validateRuntimeDiagnosticOpaqueId(filter.sessionId, "sessionId");
    }
    if (filter.traceId !== undefined) {
      validateRuntimeDiagnosticOpaqueId(filter.traceId, "traceId");
    }
    const anchor = cursor === undefined ? undefined : decodeCursor(cursor, "event");
    const events = [...this.#events.values()]
      .filter((event) => matchesEvent(event, filter))
      .filter((event) => anchor === undefined || isBeforeAnchor(
        event.occurredAtUtcMicros,
        event.eventId,
        anchor,
      ))
      .sort((left, right) => compareDescending(
        left.occurredAtUtcMicros,
        left.eventId,
        right.occurredAtUtcMicros,
        right.eventId,
      ));
    return pageResult(events, limit, (item) =>
      encodeCursor("event", item.occurredAtUtcMicros, item.eventId));
  }

  getEvent(eventId: string): RuntimeDiagnosticEvent | undefined {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(eventId, "eventId");
    return this.#events.get(eventId);
  }

  listAttachments(eventId: string): readonly RuntimeDiagnosticAttachmentDescriptor[] {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(eventId, "eventId");
    return Object.freeze(
      [...this.#attachments.values()]
        .filter((item) => item.descriptor.eventId === eventId)
        .map((item) => item.descriptor)
        .sort((left, right) => left.attachmentId.localeCompare(right.attachmentId)),
    );
  }

  async readAttachment(
    attachmentId: string,
    range: RuntimeDiagnosticAttachmentRange,
  ): Promise<RuntimeDiagnosticAttachmentChunk> {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(attachmentId, "attachmentId");
    const attachment = this.#attachments.get(attachmentId);
    if (attachment === undefined) throw new Error("Diagnostic attachment does not exist.");
    if (attachment.detailKey === undefined) {
      throw new Error("Diagnostic attachment payload was not captured.");
    }
    const result = await this.#detailStore.readRange(attachment.detailKey, range);
    const nextOffset = range.offset + result.bytes.byteLength;
    return Object.freeze({
      bytesBase64: Buffer.from(result.bytes).toString("base64"),
      eof: nextOffset >= result.totalBytes,
      nextOffset,
      totalStoredBytes: result.totalBytes,
    });
  }

  async reconcileDetails(): Promise<void> {
    this.#ensureOpen();
    const referenced = new Set(
      [...this.#attachments.values()]
        .flatMap((item) => item.detailKey === undefined ? [] : [item.detailKey]),
    );
    const physical = await this.#detailStore.listDetailKeys();
    for (const detailKey of physical) {
      if (!referenced.has(detailKey)) await this.#detailStore.delete(detailKey);
    }
  }

  async deleteSession(sessionId: string): Promise<RuntimeDiagnosticsMaintenanceResult> {
    this.#ensureOpen();
    validateRuntimeDiagnosticOpaqueId(sessionId, "sessionId");
    const result = await this.#deleteSessionInternal(sessionId);
    if (result.deletedSessions > 0) await this.#compactCatalog();
    return result;
  }

  async enforceRetention(
    policy: RuntimeDiagnosticsRetentionPolicy,
  ): Promise<RuntimeDiagnosticsMaintenanceResult> {
    this.#ensureOpen();
    validateRetentionPolicy(policy);
    const now = this.#clock().getTime() * 1_000;
    const targets = new Set<string>();
    for (const record of this.#sessions.values()) {
      if (record.session.state === "active") continue;
      const anchor = record.isDefault
        ? record.session.startedAtUtcMicros
        : record.session.endedAtUtcMicros ?? record.session.startedAtUtcMicros;
      const maxAge = record.isDefault
        ? policy.regularEventMaxAgeMicros
        : policy.captureMaxAgeMicros;
      if (anchor <= now - maxAge) targets.add(record.session.sessionId);
    }
    addByteTrimTargets(targets, [...this.#sessions.values()].filter((item) => item.isDefault), policy.regularEventBytes);
    addByteTrimTargets(targets, [...this.#sessions.values()].filter((item) => !item.isDefault), policy.captureBytes);
    addByteTrimTargets(targets, [...this.#sessions.values()], policy.globalHardBytes);
    let total: RuntimeDiagnosticsMaintenanceResult = { ...emptyMaintenanceResult };
    for (const sessionId of targets) {
      total = addMaintenance(total, await this.#deleteSessionInternal(sessionId));
    }
    if (targets.size > 0) await this.#compactCatalog();
    await this.reconcileDetails();
    return Object.freeze(total);
  }

  async getStatistics(): Promise<RuntimeDiagnosticsStorageStatistics> {
    this.#ensureOpen();
    let eventTextBytes = 0;
    let segmentCount = 0;
    for (const entry of await readdir(this.#eventsRoot, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".txt")) continue;
      segmentCount += 1;
      eventTextBytes += (await stat(join(this.#eventsRoot, entry.name))).size;
    }
    const details = await this.#detailStore.getStatistics();
    return Object.freeze({
      attachmentCount: this.#attachments.size,
      detailCount: details.detailCount,
      detailTextBytes: details.detailTextBytes,
      eventCount: this.#events.size,
      eventTextBytes,
      logicalStoredBytes:
        eventTextBytes + details.detailTextBytes + details.memoryDetailBytes,
      memoryDetailBytes: details.memoryDetailBytes,
      runCount: this.#runs.size,
      segmentCount,
      sessionCount: this.#sessions.size,
    });
  }

  close(outcome: "completed" | "incomplete" = "completed"): void {
    if (this.#closed) return;
    const ended = this.#clock().getTime() * 1_000;
    const records: TextRecord[] = [];
    for (const record of this.#sessions.values()) {
      if (record.session.sourceRunId !== this.#sourceRunId ||
        record.session.state !== "active") continue;
      records.push(sessionEndRecord(record.session.sessionId, ended, "ended"));
      record.session = updateSession(record.session, {
        endedAtUtcMicros: ended,
        state: "ended",
      });
    }
    records.push(runEndRecord(this.#sourceRunId, ended, outcome));
    this.#appendRecords(this.#sourceRunId, records);
    const run = this.#runs.get(this.#sourceRunId);
    if (run !== undefined) {
      run.endedAtUtcMicros = ended;
      run.state = outcome;
    }
    this.#detailStore.clearAllMemory();
    this.#closed = true;
  }

  #recordAttachment(
    attachmentId: string,
    input: RuntimeDiagnosticAttachmentWrite,
    stored: RuntimeDiagnosticStoredTextDetail | undefined,
    captureState: RuntimeDiagnosticCaptureState,
    truncationReason?: string,
  ): RuntimeDiagnosticAttachmentDescriptor {
    const rawByteLength = input.declaredRawByteLength ?? stored?.rawByteLength ?? 0;
    const storedByteLength = stored?.storedByteLength ?? 0;
    const descriptor = Object.freeze({
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
      storageCodec: "identity" as const,
      storedByteLength,
      ...(truncationReason === undefined ? {} : { truncationReason }),
    } satisfies RuntimeDiagnosticAttachmentDescriptor);
    const record: AttachmentRecord = {
      descriptor,
      ...(stored === undefined ? {} : { detailKey: stored.detailKey }),
      persisted: stored?.persisted ?? false,
    };
    const event = this.#events.get(input.eventId);
    if (event === undefined) throw new Error("Diagnostic attachment event disappeared.");
    this.#appendRecords(event.sourceRunId, [attachmentRecord(record)]);
    this.#attachments.set(attachmentId, record);
    this.#events.set(event.eventId, Object.freeze({
      ...event,
      attachmentCount: event.attachmentCount + 1,
      capturedBytes: event.capturedBytes + storedByteLength,
    }));
    const session = this.#sessions.get(event.captureSessionId);
    if (session !== undefined) {
      session.session = updateSession(session.session, {
        attachmentCount: session.session.attachmentCount + 1,
        storedBytes: session.session.storedBytes + storedByteLength,
      });
    }
    const run = this.#runs.get(event.sourceRunId);
    if (run !== undefined) {
      run.attachmentCount += 1;
      run.storedBytes += storedByteLength;
    }
    return descriptor;
  }

  async #deleteSessionInternal(
    sessionId: string,
  ): Promise<RuntimeDiagnosticsMaintenanceResult> {
    const session = this.#sessions.get(sessionId);
    if (session === undefined) return emptyMaintenanceResult;
    if (session.session.state === "active") {
      throw new Error("An active diagnostic session cannot be deleted.");
    }
    const sessionIds = session.isDefault
      ? new Set(
        [...this.#sessions.values()]
          .filter((item) => item.session.sourceRunId === session.session.sourceRunId)
          .map((item) => item.session.sessionId),
      )
      : new Set([sessionId]);
    const eventIds = new Set(
      [...this.#events.values()]
        .filter((event) => session.isDefault
          ? event.sourceRunId === session.session.sourceRunId
          : event.captureSessionId === sessionId)
        .map((event) => event.eventId),
    );
    const attachments = [...this.#attachments.values()].filter(
      (item) => eventIds.has(item.descriptor.eventId),
    );
    let deletedObjects = 0;
    let reclaimedBytes = 0;
    for (const attachment of attachments) {
      this.#attachments.delete(attachment.descriptor.attachmentId);
      if (attachment.detailKey !== undefined &&
        await this.#detailStore.delete(attachment.detailKey)) {
        deletedObjects += 1;
        reclaimedBytes += attachment.descriptor.storedByteLength;
      }
    }
    for (const eventId of eventIds) this.#events.delete(eventId);
    for (const id of sessionIds) this.#sessions.delete(id);
    if (session.isDefault) this.#runs.delete(session.session.sourceRunId);
    return Object.freeze({
      deletedEvents: eventIds.size,
      deletedObjects,
      deletedSessions: sessionIds.size,
      reclaimedBytes,
    });
  }

  #startRun(): void {
    const started = this.#clock().getTime() * 1_000;
    const run: RunRecord = {
      attachmentCount: 0,
      eventCount: 0,
      sourceRunId: this.#sourceRunId,
      startedAtUtcMicros: started,
      state: "active",
      storedBytes: 0,
    };
    const session: SessionRecord = {
      components: new Set(),
      detailStorage: "memoryOnly",
      isDefault: true,
      maxStoredBytes: 32 * 1024 * 1024,
      origins: new Set(),
      session: freezeSession({
        attachmentCount: 0,
        eventCount: 0,
        payloadKind: "metadataOnly",
        sessionId: this.#defaultSessionId,
        source: "runtime",
        sourceRunId: this.#sourceRunId,
        startedAtUtcMicros: started,
        state: "active",
        storedBytes: 0,
      }),
    };
    this.#appendRecords(this.#sourceRunId, [runStartRecord(run), sessionStartRecord(session)]);
    this.#runs.set(run.sourceRunId, run);
    this.#sessions.set(session.session.sessionId, session);
  }

  #recoverInterruptedState(): void {
    const ended = this.#clock().getTime() * 1_000;
    const byRun = new Map<string, TextRecord[]>();
    for (const session of this.#sessions.values()) {
      if (session.session.state !== "active") continue;
      const records = byRun.get(session.session.sourceRunId) ?? [];
      records.push(sessionEndRecord(session.session.sessionId, ended, "ended"));
      byRun.set(session.session.sourceRunId, records);
      session.session = updateSession(session.session, {
        endedAtUtcMicros: ended,
        state: "ended",
      });
    }
    for (const run of this.#runs.values()) {
      if (run.state !== "active") continue;
      const records = byRun.get(run.sourceRunId) ?? [];
      records.push(runEndRecord(run.sourceRunId, ended, "incomplete"));
      byRun.set(run.sourceRunId, records);
      run.endedAtUtcMicros = ended;
      run.state = "incomplete";
    }
    for (const [runId, records] of byRun) this.#appendRecords(runId, records);
  }

  async #loadCatalog(): Promise<void> {
    const entries = (await readdir(this.#eventsRoot, { withFileTypes: true }))
      .filter((entry) => entry.isFile() && entry.name.endsWith(".txt"))
      .sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      this.#updateSegmentSequence(entry.name);
      const path = join(this.#eventsRoot, entry.name);
      let bytes = await readFile(path);
      const lastNewline = bytes.lastIndexOf(0x0a);
      const completeLength = lastNewline < 0 ? 0 : lastNewline + 1;
      if (completeLength !== bytes.byteLength) {
        const descriptor = openSync(path, "r+");
        try {
          ftruncateSync(descriptor, completeLength);
        } finally {
          closeSync(descriptor);
        }
        bytes = bytes.subarray(0, completeLength);
      }
      if (bytes.byteLength === 0) continue;
      for (const line of bytes.toString("utf8").split("\n")) {
        if (line.length === 0) continue;
        try {
          const value: unknown = JSON.parse(line);
          if (isRecord(value)) this.#applyRecord(value, true, Buffer.byteLength(`${line}\n`));
        } catch {
          // One malformed complete line cannot make later segments unreadable.
        }
      }
    }
  }

  #applyRecord(record: TextRecord, fromDisk: boolean, lineBytes = 0): void {
    if (record.textFormatVersion !== textFormatVersion) return;
    switch (record.recordType) {
      case "run.start": {
        const sourceRunId = readString(record, "sourceRunId");
        this.#runs.set(sourceRunId, {
          attachmentCount: 0,
          eventCount: 0,
          sourceRunId,
          startedAtUtcMicros: readInteger(record, "startedAtUtcMicros"),
          state: "active",
          storedBytes: 0,
        });
        return;
      }
      case "run.end": {
        const run = this.#runs.get(readString(record, "sourceRunId"));
        if (run !== undefined) {
          run.endedAtUtcMicros = readInteger(record, "endedAtUtcMicros");
          const state = readString(record, "state");
          run.state = state === "completed" ? "completed" : "incomplete";
        }
        return;
      }
      case "session.start": {
        const session = decodeSessionStart(record);
        this.#sessions.set(session.session.sessionId, session);
        return;
      }
      case "session.end": {
        const session = this.#sessions.get(readString(record, "sessionId"));
        if (session !== undefined) {
          session.session = updateSession(session.session, {
            endedAtUtcMicros: readInteger(record, "endedAtUtcMicros"),
            state: decodeSessionState(readString(record, "state")),
          });
        }
        return;
      }
      case "event": {
        const event = decodeEvent(record.event);
        this.#events.set(event.eventId, event);
        const run = this.#runs.get(event.sourceRunId);
        if (run !== undefined) {
          run.eventCount += 1;
          run.storedBytes += lineBytes;
        }
        const session = this.#sessions.get(event.captureSessionId);
        if (session !== undefined) {
          session.session = updateSession(session.session, {
            eventCount: session.session.eventCount + 1,
            storedBytes: session.session.storedBytes + lineBytes,
          });
        }
        return;
      }
      case "attachment": {
        let descriptor = decodeAttachment(record.descriptor);
        const persisted = record.persisted === true;
        let detailKey = typeof record.detailKey === "string" ? record.detailKey : undefined;
        if (fromDisk && !persisted && descriptor.storedByteLength > 0) {
          descriptor = failedExpiredMemoryDescriptor(descriptor);
          detailKey = undefined;
        }
        const attachment: AttachmentRecord = {
          descriptor,
          ...(detailKey === undefined ? {} : { detailKey }),
          persisted,
        };
        this.#attachments.set(descriptor.attachmentId, attachment);
        const event = this.#events.get(descriptor.eventId);
        if (event !== undefined) {
          this.#events.set(event.eventId, Object.freeze({
            ...event,
            attachmentCount: event.attachmentCount + 1,
            capturedBytes: event.capturedBytes + descriptor.storedByteLength,
          }));
          const run = this.#runs.get(event.sourceRunId);
          if (run !== undefined) {
            run.attachmentCount += 1;
            run.storedBytes += descriptor.storedByteLength;
          }
          const session = this.#sessions.get(event.captureSessionId);
          if (session !== undefined) {
            session.session = updateSession(session.session, {
              attachmentCount: session.session.attachmentCount + 1,
              storedBytes: session.session.storedBytes + descriptor.storedByteLength,
            });
          }
        }
      }
    }
  }

  #appendRecords(sourceRunId: string, records: readonly TextRecord[]): void {
    this.#appendLines(sourceRunId, records.map(encodeRecord));
  }

  #appendLines(sourceRunId: string, lines: readonly string[]): void {
    let bufferedPath: string | undefined;
    let buffer = "";
    const flush = (): void => {
      if (bufferedPath === undefined || buffer.length === 0) return;
      appendFileSync(bufferedPath, buffer, { encoding: "utf8", mode: 0o600 });
      buffer = "";
    };
    for (const line of lines) {
      const bytes = Buffer.byteLength(`${line}\n`, "utf8");
      if (this.#activeSegmentPath === undefined ||
        this.#activeSegmentRunId !== sourceRunId ||
        this.#activeSegmentBytes + bytes > maximumSegmentBytes) {
        flush();
        this.#activateNextSegment(sourceRunId);
      }
      if (bufferedPath !== undefined && bufferedPath !== this.#activeSegmentPath) flush();
      bufferedPath = this.#activeSegmentPath;
      buffer += `${line}\n`;
      this.#activeSegmentBytes += bytes;
    }
    flush();
  }

  #activateNextSegment(sourceRunId: string): void {
    const next = (this.#segmentSequenceByRun.get(sourceRunId) ?? 0) + 1;
    this.#segmentSequenceByRun.set(sourceRunId, next);
    const path = join(
      this.#eventsRoot,
      `run-${sourceRunId}-${next.toString().padStart(6, "0")}.txt`,
    );
    if (!existsSync(path)) writeFileSync(path, "", { encoding: "utf8", mode: 0o600 });
    this.#activeSegmentPath = path;
    this.#activeSegmentRunId = sourceRunId;
    this.#activeSegmentBytes = 0;
  }

  #updateSegmentSequence(name: string): void {
    const match = /^run-(.+)-(\d{6})\.txt$/.exec(name);
    if (match === null) return;
    const runId = match[1];
    const sequenceText = match[2];
    if (runId === undefined || sequenceText === undefined) return;
    const sequence = Number.parseInt(sequenceText, 10);
    this.#segmentSequenceByRun.set(
      runId,
      Math.max(sequence, this.#segmentSequenceByRun.get(runId) ?? 0),
    );
  }

  async #compactCatalog(): Promise<void> {
    const records: TextRecord[] = [];
    const runs = [...this.#runs.values()]
      .sort((left, right) => left.startedAtUtcMicros - right.startedAtUtcMicros);
    for (const run of runs) {
      records.push(runStartRecord(run));
      const sessions = [...this.#sessions.values()]
        .filter((item) => item.session.sourceRunId === run.sourceRunId)
        .sort((left, right) =>
          left.session.startedAtUtcMicros - right.session.startedAtUtcMicros);
      records.push(...sessions.map(sessionStartRecord));
      const events = [...this.#events.values()]
        .filter((event) => event.sourceRunId === run.sourceRunId)
        .sort((left, right) => left.sourceSequence - right.sourceSequence);
      for (const event of events) {
        records.push({
          event: Object.freeze({ ...event, attachmentCount: 0, capturedBytes: 0 }),
          ...baseRecord("event"),
        });
        records.push(
          ...[...this.#attachments.values()]
            .filter((item) => item.descriptor.eventId === event.eventId)
            .map(attachmentRecord),
        );
      }
      for (const session of sessions) {
        if (session.session.endedAtUtcMicros !== undefined) {
          records.push(sessionEndRecord(
            session.session.sessionId,
            session.session.endedAtUtcMicros,
            session.session.state,
          ));
        }
      }
      if (run.endedAtUtcMicros !== undefined) {
        records.push(runEndRecord(run.sourceRunId, run.endedAtUtcMicros, run.state));
      }
    }
    const stagingRoot = join(this.#diagnosticsRoot, "staging");
    const staged: string[] = [];
    let segment = 1;
    let buffer = "";
    let bufferBytes = 0;
    const flush = async (): Promise<void> => {
      if (buffer.length === 0) return;
      const path = join(stagingRoot, `rewrite-${segment.toString().padStart(6, "0")}.partial.txt`);
      await writeFile(path, buffer, { encoding: "utf8", mode: 0o600 });
      staged.push(path);
      segment += 1;
      buffer = "";
      bufferBytes = 0;
    };
    for (const record of records) {
      const line = `${encodeRecord(record)}\n`;
      const bytes = Buffer.byteLength(line, "utf8");
      if (bufferBytes > 0 && bufferBytes + bytes > maximumSegmentBytes) await flush();
      buffer += line;
      bufferBytes += bytes;
    }
    await flush();
    const entries = await readdir(this.#eventsRoot, { withFileTypes: true });
    await Promise.all(entries
      .filter((entry) => entry.isFile() && entry.name.endsWith(".txt"))
      .map((entry) => rm(join(this.#eventsRoot, entry.name), { force: true })));
    const names: string[] = [];
    for (let index = 0; index < staged.length; index += 1) {
      const source = staged[index];
      if (source === undefined) continue;
      const name = `run-compacted-${(index + 1).toString().padStart(6, "0")}.txt`;
      await rename(source, join(this.#eventsRoot, name));
      names.push(name);
    }
    this.#activeSegmentPath = undefined;
    this.#activeSegmentRunId = undefined;
    this.#activeSegmentBytes = 0;
    this.#segmentSequenceByRun.clear();
    for (const name of names) this.#updateSegmentSequence(name);
  }

  #ensureOpen(): void {
    if (this.#closed) throw new Error("Runtime diagnostics store is closed.");
  }
}
