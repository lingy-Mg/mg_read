import { randomUUID } from "node:crypto";
import { setImmediate as scheduleImmediate } from "node:timers";

import { RuntimeDiagnosticAttachmentSpool } from "./attachment-spool.js";
import {
  type RuntimeDiagnosticAttachmentDescriptor,
  type RuntimeDiagnosticAttachmentRange,
  type RuntimeDiagnosticCapturePolicy,
  type RuntimeDiagnosticEvent,
  type RuntimeDiagnosticEventFilter,
  type RuntimeDiagnosticPage,
  type RuntimeDiagnosticPrivacyClass,
  type RuntimeDiagnosticSession,
  type RuntimeDiagnosticSessionFilter,
  type RuntimeDiagnosticTraceContext,
  runtimeDiagnosticValue,
  validateRuntimeDiagnosticCapturePolicy,
} from "./contracts.js";
import {
  RuntimeDiagnosticsManager,
  type RuntimeDiagnosticsManagerConfiguration,
  type RuntimeDiagnosticSpan,
  type RuntimeDiagnosticWriterStatistics,
} from "./manager.js";
import { serializeRuntimeDiagnosticTree } from "./privacy.js";
import { runtimeDiagnosticEvents } from "./registry.js";
import {
  RuntimeDiagnosticsStore,
  type RuntimeDiagnosticAttachmentWrite,
  type RuntimeDiagnosticsMaintenanceResult,
  type RuntimeDiagnosticsRetentionPolicy,
  type RuntimeDiagnosticsStorageStatistics,
} from "./text-store.js";

export type RuntimeDiagnosticsErrorCode =
  | "attachment_capture_failed"
  | "capture_already_active"
  | "capture_mode_unsupported"
  | "capture_not_active"
  | "diagnostics_closed"
  | "diagnostics_query_failed"
  | "diagnostics_store_failed";

export class RuntimeDiagnosticsError extends Error {
  constructor(readonly code: RuntimeDiagnosticsErrorCode) {
    super(code);
    this.name = "RuntimeDiagnosticsError";
  }
}

export interface RuntimeDiagnosticsServiceOptions {
  readonly clock?: () => Date;
  readonly dataRoot: string;
  readonly manager?: RuntimeDiagnosticsManagerConfiguration;
}

export interface RuntimeTextAttachmentOptions {
  readonly captureOrigin?: string;
  readonly charset?: string;
  readonly eventId: string;
  readonly formatId: "json" | "raw-bytes" | "text";
  readonly kind: string;
  readonly mediaType: string;
  readonly privacyClass: "content" | "internal" | "public";
  readonly schemaId?: string;
  readonly schemaVersion?: number;
  readonly trace?: RuntimeDiagnosticTraceContext;
}

export interface RuntimeStructuredAttachmentOptions {
  readonly eventId: string;
  readonly kind: string;
  readonly privacyClass?: "internal" | "public";
  readonly schemaId?: string;
  readonly schemaVersion?: number;
  readonly trace?: RuntimeDiagnosticTraceContext;
  readonly value: unknown;
}

export const defaultRuntimeDiagnosticsRetentionPolicy = Object.freeze({
  captureBytes: 256 * 1024 * 1024,
  captureMaxAgeMicros: 24 * 60 * 60 * 1_000_000,
  globalHardBytes: 512 * 1024 * 1024,
  regularEventBytes: 32 * 1024 * 1024,
  regularEventMaxAgeMicros: 3 * 24 * 60 * 60 * 1_000_000,
} satisfies RuntimeDiagnosticsRetentionPolicy);

/** Process-scoped owner of Runtime event TXT and explicit debug details. */
export class RuntimeDiagnosticsService {
  readonly #clock: () => Date;
  readonly #manager: RuntimeDiagnosticsManager;
  readonly #store: RuntimeDiagnosticsStore;
  #captureExpiryTimer: NodeJS.Timeout | undefined;
  #captureSpan: RuntimeDiagnosticSpan | undefined;
  #closePromise: Promise<void> | undefined;
  #closed = false;

  private constructor(
    store: RuntimeDiagnosticsStore,
    manager: RuntimeDiagnosticsManager,
    clock: () => Date,
  ) {
    this.#store = store;
    this.#manager = manager;
    this.#clock = clock;
  }

  static async open(options: RuntimeDiagnosticsServiceOptions): Promise<RuntimeDiagnosticsService> {
    const clock = options.clock ?? (() => new Date());
    const store = await RuntimeDiagnosticsStore.open({
      clock,
      dataRoot: options.dataRoot,
      sourceRunId: `runtime-${randomUUID()}`,
    });
    const manager = new RuntimeDiagnosticsManager(store, options.manager, clock);
    const service = new RuntimeDiagnosticsService(store, manager, clock);
    manager.emit({
      attributes: () => runtimeDiagnosticValue.object({
        state: runtimeDiagnosticValue.string("ready"),
      }),
      definition: runtimeDiagnosticEvents.writer,
      phase: "start",
    });
    return service;
  }

  get manager(): RuntimeDiagnosticsManager {
    return this.#manager;
  }

  get writerStatistics(): RuntimeDiagnosticWriterStatistics {
    return this.#manager.statistics;
  }

  async startCapture(policy: RuntimeDiagnosticCapturePolicy): Promise<RuntimeDiagnosticSession> {
    this.#ensureOpen();
    try {
      validateRuntimeDiagnosticCapturePolicy(policy);
    } catch (error) {
      if (policy.payloadKind === "restrictedRaw") {
        throw new RuntimeDiagnosticsError("capture_mode_unsupported");
      }
      throw error;
    }
    if (this.#manager.activeCaptureSessionId !== undefined) {
      throw new RuntimeDiagnosticsError("capture_already_active");
    }
    const span = this.#manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        maxStoredBytes: runtimeDiagnosticValue.int64(BigInt(policy.maxStoredBytes)),
        payloadKind: runtimeDiagnosticValue.string(policy.payloadKind),
        sessionState: runtimeDiagnosticValue.string("starting"),
      }),
      definition: runtimeDiagnosticEvents.capture,
    });
    try {
      const session = this.#store.createCaptureSession(
        `capture-${randomUUID()}`,
        policy,
      );
      this.#manager.setActiveCapture(session.sessionId, policy);
      this.#captureSpan = span;
      this.#captureExpiryTimer = setTimeout(() => {
        void this.#stopCapture(session.sessionId, "expired").catch(() => undefined);
      }, policy.durationMillis);
      this.#captureExpiryTimer.unref();
      return session;
    } catch (error) {
      span.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("capture_start_failed"),
          payloadKind: runtimeDiagnosticValue.string(policy.payloadKind),
          sessionState: runtimeDiagnosticValue.string("failed"),
        }),
        severity: "error",
      });
      throw error;
    }
  }

  stopCapture(sessionId: string): Promise<void> {
    return this.#stopCapture(sessionId, "ended");
  }

  beginTextAttachment(
    options: RuntimeTextAttachmentOptions,
    maxQueuedBytes = 256 * 1024,
  ): RuntimeDiagnosticAttachmentCapture | undefined {
    this.#ensureOpen();
    const payloadKind = options.privacyClass === "content"
      ? "contentPayload"
      : "safeStructured";
    if (!this.#manager.isEnabled(
      "runtime.http",
      "debug",
      payloadKind,
      options.captureOrigin,
    )) {
      return undefined;
    }
    const spool = new RuntimeDiagnosticAttachmentSpool(maxQueuedBytes);
    const span = this.#manager.startSpan({
      ...(options.captureOrigin === undefined
        ? {}
        : { captureOrigin: options.captureOrigin }),
      definition: runtimeDiagnosticEvents.attachment,
      ...(options.trace === undefined ? {} : { parent: options.trace }),
    });
    const result = this.#captureSpool(options, spool, span);
    return new RuntimeDiagnosticAttachmentCapture(spool, result);
  }

  async captureStructuredAttachment(
    options: RuntimeStructuredAttachmentOptions,
  ): Promise<RuntimeDiagnosticAttachmentDescriptor | undefined> {
    this.#ensureOpen();
    if (!this.#manager.isEnabled("runtime.diagnostics", "debug", "safeStructured")) {
      return undefined;
    }
    const span = this.#manager.startSpan({
      definition: runtimeDiagnosticEvents.attachment,
      ...(options.trace === undefined ? {} : { parent: options.trace }),
    });
    try {
      await yieldToEventLoop();
      const bytes = serializeRuntimeDiagnosticTree(options.value);
      await this.#manager.flush();
      const descriptor = await this.#store.captureAttachment({
        chunks: singleChunk(bytes),
        eventId: options.eventId,
        formatId: "mgread.diagnostic-tree",
        formatVersion: 1,
        kind: options.kind,
        mediaType: "application/vnd.mgread.diagnostic-tree+json",
        privacyClass: options.privacyClass ?? "internal",
        redactionVersion: 1,
        sanitizeText: false,
        ...(options.schemaId === undefined ? {} : { schemaId: options.schemaId }),
        ...(options.schemaVersion === undefined
          ? {}
          : { schemaVersion: options.schemaVersion }),
      });
      span.end("success", {
        attributes: () => attachmentAttributes(descriptor),
      });
      return descriptor;
    } catch {
      span.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          captureState: runtimeDiagnosticValue.string("failed"),
          capturedBytes: runtimeDiagnosticValue.int64(0n),
          kind: runtimeDiagnosticValue.string(options.kind),
          privacyClass: runtimeDiagnosticValue.string(options.privacyClass ?? "internal"),
          truncationReason: runtimeDiagnosticValue.string("captureFailure"),
        }),
        severity: "error",
      });
      return failedAttachment(options.eventId, options.kind, options.privacyClass ?? "internal");
    }
  }

  async listSessions(
    filter: RuntimeDiagnosticSessionFilter = {},
    cursor?: string,
    limit = 100,
  ): Promise<RuntimeDiagnosticPage<RuntimeDiagnosticSession>> {
    return this.#query("sessions", limit, () => this.#store.listSessions(filter, cursor, limit));
  }

  async listEvents(
    filter: RuntimeDiagnosticEventFilter,
    cursor?: string,
    limit = 100,
  ): Promise<RuntimeDiagnosticPage<RuntimeDiagnosticEvent>> {
    return this.#query("events", limit, () => this.#store.listEvents(filter, cursor, limit));
  }

  async getEvent(eventId: string): Promise<RuntimeDiagnosticEvent | undefined> {
    this.#ensureOpen();
    await yieldToEventLoop();
    return this.#store.getEvent(eventId);
  }

  async listAttachments(
    eventId: string,
  ): Promise<readonly RuntimeDiagnosticAttachmentDescriptor[]> {
    this.#ensureOpen();
    await yieldToEventLoop();
    return this.#store.listAttachments(eventId);
  }

  async readAttachment(
    attachmentId: string,
    range: RuntimeDiagnosticAttachmentRange,
  ) {
    this.#ensureOpen();
    await yieldToEventLoop();
    return this.#store.readAttachment(attachmentId, range);
  }

  async enforceRetention(
    policy: RuntimeDiagnosticsRetentionPolicy = defaultRuntimeDiagnosticsRetentionPolicy,
  ): Promise<RuntimeDiagnosticsMaintenanceResult> {
    this.#ensureOpen();
    const span = this.#manager.startSpan({ definition: runtimeDiagnosticEvents.retention });
    try {
      await this.#manager.flush();
      const result = await this.#store.enforceRetention(policy);
      span.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          deletedEvents: runtimeDiagnosticValue.int64(BigInt(result.deletedEvents)),
          deletedObjects: runtimeDiagnosticValue.int64(BigInt(result.deletedObjects)),
          deletedSessions: runtimeDiagnosticValue.int64(BigInt(result.deletedSessions)),
          reclaimedBytes: runtimeDiagnosticValue.int64(BigInt(result.reclaimedBytes)),
        }),
      });
      return result;
    } catch (error) {
      span.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("retention_failed"),
        }),
        severity: "error",
      });
      throw error;
    }
  }

  async deleteSession(
    sessionId: string,
  ): Promise<RuntimeDiagnosticsMaintenanceResult> {
    this.#ensureOpen();
    const span = this.#manager.startSpan({ definition: runtimeDiagnosticEvents.retention });
    try {
      await this.#manager.flush();
      const result = await this.#store.deleteSession(sessionId);
      span.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          deletedEvents: runtimeDiagnosticValue.int64(BigInt(result.deletedEvents)),
          deletedObjects: runtimeDiagnosticValue.int64(BigInt(result.deletedObjects)),
          deletedSessions: runtimeDiagnosticValue.int64(BigInt(result.deletedSessions)),
          reclaimedBytes: runtimeDiagnosticValue.int64(BigInt(result.reclaimedBytes)),
        }),
      });
      return result;
    } catch (error) {
      span.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("session_delete_failed"),
        }),
        severity: "error",
      });
      throw error;
    }
  }

  async getStorageStatistics(): Promise<RuntimeDiagnosticsStorageStatistics> {
    this.#ensureOpen();
    await this.#manager.flush();
    return this.#store.getStatistics();
  }

  close(): Promise<void> {
    return this.#closePromise ??= this.#close();
  }

  async #close(): Promise<void> {
    if (this.#closed) return;
    this.#captureExpiryTimer?.close();
    this.#captureExpiryTimer = undefined;
    const captureSessionId = this.#manager.activeCaptureSessionId;
    if (captureSessionId !== undefined) {
      await this.#stopCapture(captureSessionId, "ended").catch(() => undefined);
    }
    await this.#manager.close();
    try {
      this.#store.close("completed");
    } catch {
      // Diagnostics shutdown remains best effort and never fails Runtime stop.
    }
    this.#closed = true;
  }

  async #stopCapture(
    sessionId: string,
    state: "ended" | "expired",
  ): Promise<void> {
    this.#ensureOpen();
    if (this.#manager.activeCaptureSessionId !== sessionId) {
      throw new RuntimeDiagnosticsError("capture_not_active");
    }
    this.#captureExpiryTimer?.close();
    this.#captureExpiryTimer = undefined;
    this.#manager.clearActiveCapture(sessionId);
    try {
      this.#store.stopCaptureSession(sessionId, state);
      this.#captureSpan?.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          payloadKind: runtimeDiagnosticValue.string("metadataOnly"),
          sessionState: runtimeDiagnosticValue.string(state),
        }),
      });
    } catch (error) {
      this.#captureSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("capture_stop_failed"),
          sessionState: runtimeDiagnosticValue.string("failed"),
        }),
        severity: "error",
      });
      throw error;
    } finally {
      this.#captureSpan = undefined;
    }
  }

  async #captureSpool(
    options: RuntimeTextAttachmentOptions,
    spool: RuntimeDiagnosticAttachmentSpool,
    span: RuntimeDiagnosticSpan,
  ): Promise<RuntimeDiagnosticAttachmentDescriptor> {
    try {
      await this.#manager.flush();
      const write: RuntimeDiagnosticAttachmentWrite = {
        ...(options.charset === undefined ? {} : { charset: options.charset }),
        chunks: spool,
        completion: () => spool.completion,
        eventId: options.eventId,
        formatId: options.formatId,
        formatVersion: 1,
        kind: options.kind,
        mediaType: options.mediaType,
        privacyClass: options.privacyClass,
        redactionVersion: 1,
        sanitizeText: true,
        ...(options.schemaId === undefined ? {} : { schemaId: options.schemaId }),
        ...(options.schemaVersion === undefined
          ? {}
          : { schemaVersion: options.schemaVersion }),
      };
      const descriptor = await this.#store.captureAttachment(write);
      span.end(
        descriptor.captureState === "pressureDropped" ? "overloaded" : "success",
        {
          attributes: () => attachmentAttributes(descriptor),
          ...(descriptor.captureState === "captured" ? {} : { severity: "warn" }),
        },
      );
      return descriptor;
    } catch {
      span.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          captureState: runtimeDiagnosticValue.string("failed"),
          capturedBytes: runtimeDiagnosticValue.int64(0n),
          kind: runtimeDiagnosticValue.string(options.kind),
          privacyClass: runtimeDiagnosticValue.string(options.privacyClass),
          truncationReason: runtimeDiagnosticValue.string("captureFailure"),
        }),
        severity: "error",
      });
      return failedAttachment(options.eventId, options.kind, options.privacyClass);
    }
  }

  async #query<T>(
    queryKind: string,
    limit: number,
    query: () => RuntimeDiagnosticPage<T>,
  ): Promise<RuntimeDiagnosticPage<T>> {
    this.#ensureOpen();
    const span = this.#manager.startSpan({ definition: runtimeDiagnosticEvents.diagnosticsQuery });
    try {
      await this.#manager.flush();
      const page = query();
      span.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          itemCount: runtimeDiagnosticValue.int64(BigInt(page.items.length)),
          limit: runtimeDiagnosticValue.int64(BigInt(limit)),
          queryKind: runtimeDiagnosticValue.string(queryKind),
        }),
      });
      return page;
    } catch (error) {
      span.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("query_failed"),
          limit: runtimeDiagnosticValue.int64(BigInt(limit)),
          queryKind: runtimeDiagnosticValue.string(queryKind),
        }),
        severity: "error",
      });
      throw error;
    }
  }

  #ensureOpen(): void {
    if (this.#closed) throw new RuntimeDiagnosticsError("diagnostics_closed");
  }
}

/** Producer-facing handle; offer never waits on filesystem persistence. */
export class RuntimeDiagnosticAttachmentCapture {
  readonly #spool: RuntimeDiagnosticAttachmentSpool;
  readonly result: Promise<RuntimeDiagnosticAttachmentDescriptor>;

  constructor(
    spool: RuntimeDiagnosticAttachmentSpool,
    result: Promise<RuntimeDiagnosticAttachmentDescriptor>,
  ) {
    this.#spool = spool;
    this.result = result;
  }

  get queueHighWater(): number {
    return this.#spool.queueHighWater;
  }

  offer(chunk: Uint8Array): boolean {
    return this.#spool.offer(chunk);
  }

  finish(): void {
    this.#spool.finish();
  }

  truncate(reason: string): void {
    this.#spool.truncate(reason);
  }
}

function attachmentAttributes(
  descriptor: RuntimeDiagnosticAttachmentDescriptor,
) {
  return runtimeDiagnosticValue.object({
    captureState: runtimeDiagnosticValue.string(descriptor.captureState),
    capturedBytes: runtimeDiagnosticValue.int64(BigInt(descriptor.storedByteLength)),
    kind: runtimeDiagnosticValue.string(descriptor.kind),
    privacyClass: runtimeDiagnosticValue.string(descriptor.privacyClass),
    ...(descriptor.truncationReason === undefined
      ? {}
      : { truncationReason: runtimeDiagnosticValue.string(descriptor.truncationReason) }),
  });
}

function failedAttachment(
  eventId: string,
  kind: string,
  privacyClass: RuntimeDiagnosticPrivacyClass,
): RuntimeDiagnosticAttachmentDescriptor {
  return Object.freeze({
    attachmentId: `attachment-${randomUUID()}`,
    captureState: "failed",
    eventId,
    formatId: "raw-bytes",
    formatVersion: 1,
    kind,
    mediaType: "application/octet-stream",
    privacyClass,
    rawByteLength: 0,
    redactionVersion: 1,
    storageCodec: "identity",
    storedByteLength: 0,
    truncationReason: "captureFailure",
  });
}

async function* singleChunk(bytes: Uint8Array): AsyncGenerator<Uint8Array> {
  yield bytes;
}

function yieldToEventLoop(): Promise<void> {
  return new Promise<void>((resolve) => scheduleImmediate(resolve));
}
