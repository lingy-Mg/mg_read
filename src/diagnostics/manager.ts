import { randomUUID } from "node:crypto";
import { setImmediate as scheduleImmediate } from "node:timers";

import {
  runtimeDiagnosticEnvelopeVersion,
  type RuntimeDiagnosticCapturePolicy,
  type RuntimeDiagnosticEvent,
  type RuntimeDiagnosticEventDefinition,
  type RuntimeDiagnosticEventFlag,
  type RuntimeDiagnosticObjectValue,
  type RuntimeDiagnosticOutcome,
  type RuntimeDiagnosticPayloadKind,
  type RuntimeDiagnosticPhase,
  type RuntimeDiagnosticSeverity,
  type RuntimeDiagnosticTraceContext,
  runtimeDiagnosticValue,
  validateRuntimeDiagnosticValue,
} from "./contracts.js";
import {
  runtimeDiagnosticEvents,
  validateRegisteredRuntimeDiagnosticEvent,
} from "./registry.js";

export interface RuntimeDiagnosticEventWriter {
  readonly defaultSessionId: string;
  readonly sourceRunId: string;
  appendEvents(events: readonly RuntimeDiagnosticEvent[]): void;
}

export interface RuntimeDiagnosticsManagerConfiguration {
  readonly batchSize?: number;
  readonly flushTimeoutMillis?: number;
  readonly maxBatchDelayMillis?: number;
  readonly maxQueueBytes?: number;
  readonly maxQueueEvents?: number;
  readonly minimumSeverity?: RuntimeDiagnosticSeverity;
  readonly priorityReservedBytes?: number;
  readonly priorityReservedEvents?: number;
  readonly traceComponents?: ReadonlySet<string>;
}

export interface RuntimeDiagnosticWriterStatistics {
  readonly acceptedEvents: number;
  readonly committedEvents: number;
  readonly droppedEvents: number;
  readonly flushTimeouts: number;
  readonly lastBatchSize: number;
  readonly lastCommitMicros: number;
  readonly lastWriterFailureType?: string;
  readonly queueByteHighWater: number;
  readonly queueBytes: number;
  readonly queueDepth: number;
  readonly queueHighWater: number;
  readonly writerErrors: number;
}

export interface RuntimeDiagnosticEmitOptions {
  readonly attributes?: () => RuntimeDiagnosticObjectValue;
  readonly captureOrigin?: string;
  readonly definition: RuntimeDiagnosticEventDefinition;
  readonly durationMicros?: number;
  readonly flags?: ReadonlySet<RuntimeDiagnosticEventFlag>;
  readonly outcome?: RuntimeDiagnosticOutcome;
  readonly phase?: RuntimeDiagnosticPhase;
  readonly severity?: RuntimeDiagnosticSeverity;
  readonly trace?: RuntimeDiagnosticTraceContext;
}

export interface RuntimeDiagnosticSpanOptions {
  readonly attributes?: () => RuntimeDiagnosticObjectValue;
  readonly captureOrigin?: string;
  readonly definition: RuntimeDiagnosticEventDefinition;
  readonly parent?: RuntimeDiagnosticTraceContext;
  readonly severity?: RuntimeDiagnosticSeverity;
  readonly traceId?: string;
}

interface ActiveCapture {
  readonly expiresAtUnixMillis: number;
  readonly policy: RuntimeDiagnosticCapturePolicy;
  readonly sessionId: string;
}

interface QueuedEvent {
  readonly estimatedBytes: number;
  readonly event: RuntimeDiagnosticEvent;
}

type MaterializedRuntimeDiagnosticEmitOptions = Omit<
  RuntimeDiagnosticEmitOptions,
  "attributes" | "severity"
> & {
  readonly attributes: RuntimeDiagnosticObjectValue;
  readonly severity: RuntimeDiagnosticSeverity;
};

const severityOrder = Object.freeze([
  "trace",
  "debug",
  "info",
  "warn",
  "error",
  "fatal",
] satisfies readonly RuntimeDiagnosticSeverity[]);

/**
 * Fast, bounded Runtime event manager. TXT encoding and append happen only from
 * scheduled writer drains; emit never waits for persistence.
 */
export class RuntimeDiagnosticsManager {
  readonly #batchSize: number;
  readonly #clock: () => Date;
  readonly #flushTimeoutMillis: number;
  readonly #maxBatchDelayMillis: number;
  readonly #maxQueueBytes: number;
  readonly #maxQueueEvents: number;
  readonly #minimumSeverity: RuntimeDiagnosticSeverity;
  readonly #monotonicOrigin = process.hrtime.bigint();
  readonly #normalQueue: QueuedEvent[] = [];
  readonly #openSpans = new Set<RuntimeDiagnosticSpan>();
  readonly #priorityQueue: QueuedEvent[] = [];
  readonly #priorityReservedBytes: number;
  readonly #priorityReservedEvents: number;
  readonly #traceComponents: ReadonlySet<string>;
  readonly #writer: RuntimeDiagnosticEventWriter;
  #acceptedEvents = 0;
  #activeCapture: ActiveCapture | undefined;
  #closed = false;
  #closing = false;
  #committedEvents = 0;
  #drainScheduled = false;
  #droppedEvents = 0;
  #dropWindowStarted = process.hrtime.bigint();
  #flushTimeouts = 0;
  #lastBatchSize = 0;
  #lastCommitMicros = 0;
  #lastDropReason = "queuePressure";
  #lastWriterFailureType: string | undefined;
  #normalQueueBytes = 0;
  #pendingDropCount = 0;
  #queueByteHighWater = 0;
  #queueBytes = 0;
  #queueHighWater = 0;
  #sequence = 0;
  #timer: NodeJS.Timeout | undefined;
  #writerErrors = 0;

  constructor(
    writer: RuntimeDiagnosticEventWriter,
    configuration: RuntimeDiagnosticsManagerConfiguration = {},
    clock: () => Date = () => new Date(),
  ) {
    this.#writer = writer;
    this.#clock = clock;
    this.#batchSize = configuration.batchSize ?? 128;
    this.#flushTimeoutMillis = configuration.flushTimeoutMillis ?? 2_000;
    this.#maxBatchDelayMillis = configuration.maxBatchDelayMillis ?? 50;
    this.#maxQueueBytes = configuration.maxQueueBytes ?? 4 * 1024 * 1024;
    this.#maxQueueEvents = configuration.maxQueueEvents ?? 4_096;
    this.#minimumSeverity = configuration.minimumSeverity ?? "debug";
    this.#priorityReservedBytes = configuration.priorityReservedBytes ?? 512 * 1024;
    this.#priorityReservedEvents = configuration.priorityReservedEvents ?? 256;
    this.#traceComponents = configuration.traceComponents ?? new Set<string>();
    this.#validateConfiguration();
  }

  get statistics(): RuntimeDiagnosticWriterStatistics {
    return Object.freeze({
      acceptedEvents: this.#acceptedEvents,
      committedEvents: this.#committedEvents,
      droppedEvents: this.#droppedEvents,
      flushTimeouts: this.#flushTimeouts,
      lastBatchSize: this.#lastBatchSize,
      lastCommitMicros: this.#lastCommitMicros,
      ...(this.#lastWriterFailureType === undefined
        ? {}
        : { lastWriterFailureType: this.#lastWriterFailureType }),
      queueByteHighWater: this.#queueByteHighWater,
      queueBytes: this.#queueBytes,
      queueDepth: this.#queueDepth,
      queueHighWater: this.#queueHighWater,
      writerErrors: this.#writerErrors,
    });
  }

  get activeCaptureSessionId(): string | undefined {
    this.#expireCaptureIfNeeded();
    return this.#activeCapture?.sessionId;
  }

  isEnabled(
    component: string,
    severity: RuntimeDiagnosticSeverity,
    payloadKind: RuntimeDiagnosticPayloadKind = "metadataOnly",
    origin?: string,
  ): boolean {
    if (this.#closing || this.#closed) return false;
    if (severity === "trace" && !this.#traceComponents.has(component)) return false;
    if (severityOrder.indexOf(severity) < severityOrder.indexOf(this.#minimumSeverity)) return false;
    if (payloadKind === "restrictedRaw") return false;
    if (payloadKind === "metadataOnly") return true;
    const capture = this.#eligibleCapture(component, origin);
    if (capture === undefined) return false;
    return capture.policy.payloadKind === payloadKind ||
      (capture.policy.payloadKind === "contentPayload" && payloadKind === "safeStructured");
  }

  emit(options: RuntimeDiagnosticEmitOptions): RuntimeDiagnosticEvent | undefined {
    const severity = options.severity ?? options.definition.defaultSeverity;
    if (!this.isEnabled(options.definition.component, severity, "metadataOnly")) return undefined;
    try {
      const attributes = options.attributes?.() ?? runtimeDiagnosticValue.object({});
      validateRegisteredRuntimeDiagnosticEvent(options.definition, attributes);
      const event = this.#createEvent({
        ...options,
        attributes,
        severity,
      } as MaterializedRuntimeDiagnosticEmitOptions);
      return this.#enqueue(event) ? event : undefined;
    } catch {
      this.#recordDrop("draftValidation");
      return undefined;
    }
  }

  startSpan(options: RuntimeDiagnosticSpanOptions): RuntimeDiagnosticSpan {
    const traceId = options.parent?.traceId ?? options.traceId ?? opaqueId("trace");
    const spanId = opaqueId("span");
    const trace: RuntimeDiagnosticTraceContext = Object.freeze({
      ...(options.parent === undefined ? {} : { parentSpanId: options.parent.spanId }),
      spanId,
      traceId,
    });
    const startedAt = process.hrtime.bigint();
    const span = new RuntimeDiagnosticSpan(this, options, trace, startedAt);
    this.#openSpans.add(span);
    const startEvent = this.emit({
      ...(options.attributes === undefined ? {} : { attributes: options.attributes }),
      ...(options.captureOrigin === undefined
        ? {}
        : { captureOrigin: options.captureOrigin }),
      definition: options.definition,
      phase: "start",
      ...(options.severity === undefined ? {} : { severity: options.severity }),
      trace,
    });
    span.setStartEventId(startEvent?.eventId);
    return span;
  }

  setActiveCapture(
    sessionId: string,
    policy: RuntimeDiagnosticCapturePolicy,
  ): void {
    this.#activeCapture = Object.freeze({
      expiresAtUnixMillis: this.#clock().getTime() + policy.durationMillis,
      policy,
      sessionId,
    });
  }

  clearActiveCapture(sessionId: string): void {
    if (this.#activeCapture?.sessionId === sessionId) this.#activeCapture = undefined;
  }

  async flush(timeoutMillis = this.#flushTimeoutMillis): Promise<void> {
    if (this.#closed) return;
    if (!Number.isSafeInteger(timeoutMillis) || timeoutMillis <= 0) {
      throw new RangeError("Diagnostics flush timeout must be positive.");
    }
    if (this.#timer !== undefined) {
      clearTimeout(this.#timer);
      this.#timer = undefined;
      this.#drainScheduled = false;
    }
    const deadline = Date.now() + timeoutMillis;
    while (this.#queueDepth > 0 && Date.now() <= deadline) {
      this.#drainOneBatch();
      if (this.#queueDepth > 0) await new Promise<void>((resolve) => scheduleImmediate(resolve));
    }
    if (this.#queueDepth > 0) {
      this.#flushTimeouts += 1;
      this.#dropAllQueued("flushTimeout");
    }
  }

  async close(timeoutMillis = this.#flushTimeoutMillis): Promise<void> {
    if (this.#closed) return;
    this.#activeCapture = undefined;
    for (const span of [...this.#openSpans]) {
      span.end("incomplete", {
        flags: new Set<RuntimeDiagnosticEventFlag>(["incomplete"]),
      });
    }
    this.emit({
      attributes: () => runtimeDiagnosticValue.object({ state: runtimeDiagnosticValue.string("stopping") }),
      definition: runtimeDiagnosticEvents.writer,
      phase: "terminal",
      outcome: "success",
    });
    this.#closing = true;
    await this.flush(timeoutMillis);
    this.#closed = true;
  }

  /** Called only by RuntimeDiagnosticSpan; duplicate terminals are rejected. */
  endSpan(
    span: RuntimeDiagnosticSpan,
    outcome: RuntimeDiagnosticOutcome,
    options: RuntimeDiagnosticSpanEndOptions,
  ): RuntimeDiagnosticEvent | undefined {
    if (!this.#openSpans.delete(span)) {
      throw new Error("A Runtime diagnostic span can end exactly once.");
    }
    const durationMicros = Number((process.hrtime.bigint() - span.startedAt) / 1_000n);
    const severity = options.severity ?? span.severity;
    return this.emit({
      ...(options.attributes === undefined ? {} : { attributes: options.attributes }),
      ...(span.captureOrigin === undefined
        ? {}
        : { captureOrigin: span.captureOrigin }),
      definition: span.definition,
      durationMicros,
      ...(options.flags === undefined ? {} : { flags: options.flags }),
      outcome,
      phase: "terminal",
      ...(severity === undefined ? {} : { severity }),
      trace: span.trace,
    });
  }

  get #queueDepth(): number {
    return this.#normalQueue.length + this.#priorityQueue.length;
  }

  #createEvent(
    options: MaterializedRuntimeDiagnosticEmitOptions,
  ): RuntimeDiagnosticEvent {
    const phase = options.phase ?? "instant";
    if ((phase === "terminal") !== (options.outcome !== undefined)) {
      throw new TypeError("Only terminal diagnostic events have an outcome.");
    }
    if (options.durationMicros !== undefined &&
      (!Number.isSafeInteger(options.durationMicros) || options.durationMicros < 0)) {
      throw new RangeError("Diagnostic duration must be a safe non-negative integer.");
    }
    this.#sequence += 1;
    const capture = this.#eligibleCapture(options.definition.component, options.captureOrigin);
    return Object.freeze({
      attachmentCount: 0,
      attributes: options.attributes,
      capturedBytes: 0,
      captureSessionId: capture?.sessionId ?? this.#writer.defaultSessionId,
      component: options.definition.component,
      ...(options.durationMicros === undefined ? {} : { durationMicros: options.durationMicros }),
      envelopeVersion: runtimeDiagnosticEnvelopeVersion,
      eventId: opaqueId("event"),
      eventName: options.definition.eventName,
      eventSchemaVersion: options.definition.eventSchemaVersion,
      flags: Object.freeze([...(options.flags ?? [])]),
      monotonicOffsetMicros: Number((process.hrtime.bigint() - this.#monotonicOrigin) / 1_000n),
      occurredAtUtcMicros: this.#clock().getTime() * 1_000,
      ...(options.outcome === undefined ? {} : { outcome: options.outcome }),
      ...(options.trace?.parentSpanId === undefined
        ? {}
        : { parentSpanId: options.trace.parentSpanId }),
      phase,
      severity: options.severity,
      source: "runtime",
      sourceRunId: this.#writer.sourceRunId,
      sourceSequence: this.#sequence,
      ...(options.trace === undefined ? {} : { spanId: options.trace.spanId }),
      summary: options.definition.summary,
      ...(options.trace === undefined ? {} : { traceId: options.trace.traceId }),
    });
  }

  #enqueue(event: RuntimeDiagnosticEvent): boolean {
    const estimatedBytes = estimateEventBytes(event);
    const priority = severityOrder.indexOf(event.severity) >= severityOrder.indexOf("warn");
    if (priority) {
      while (!this.#fitsPriority(estimatedBytes) && this.#normalQueue.length > 0) {
        const dropped = this.#normalQueue.shift();
        if (dropped !== undefined) this.#dropQueued(dropped, "priorityReservation");
      }
      if (!this.#fitsPriority(estimatedBytes)) {
        this.#recordDrop("priorityQueueFull");
        return false;
      }
      this.#priorityQueue.push({ estimatedBytes, event });
    } else {
      const normalEventLimit = this.#maxQueueEvents - this.#priorityReservedEvents;
      const normalByteLimit = this.#maxQueueBytes - this.#priorityReservedBytes;
      if (
        this.#normalQueue.length >= normalEventLimit ||
        this.#normalQueueBytes + estimatedBytes > normalByteLimit ||
        this.#queueDepth >= this.#maxQueueEvents ||
        this.#queueBytes + estimatedBytes > this.#maxQueueBytes
      ) {
        this.#recordDrop("normalQueueFull");
        return false;
      }
      this.#normalQueue.push({ estimatedBytes, event });
      this.#normalQueueBytes += estimatedBytes;
    }
    this.#queueBytes += estimatedBytes;
    this.#acceptedEvents += 1;
    this.#queueHighWater = Math.max(this.#queueHighWater, this.#queueDepth);
    this.#queueByteHighWater = Math.max(this.#queueByteHighWater, this.#queueBytes);
    this.#scheduleDrain(this.#queueDepth >= this.#batchSize);
    return true;
  }

  #fitsPriority(estimatedBytes: number): boolean {
    return this.#queueDepth < this.#maxQueueEvents &&
      this.#queueBytes + estimatedBytes <= this.#maxQueueBytes;
  }

  #scheduleDrain(immediate: boolean): void {
    if (this.#drainScheduled || this.#closed) return;
    this.#drainScheduled = true;
    if (immediate) {
      scheduleImmediate(() => {
        this.#drainScheduled = false;
        this.#drainOneBatch();
      });
      return;
    }
    this.#timer = setTimeout(() => {
      this.#timer = undefined;
      this.#drainScheduled = false;
      this.#drainOneBatch();
    }, this.#maxBatchDelayMillis);
    this.#timer.unref();
  }

  #drainOneBatch(): void {
    if (this.#closed || this.#queueDepth === 0) return;
    const batch: RuntimeDiagnosticEvent[] = [];
    while (batch.length < this.#batchSize && this.#queueDepth > 0) {
      const fromPriority = this.#priorityQueue.length > 0;
      const queued = fromPriority
        ? this.#priorityQueue.shift()
        : this.#normalQueue.shift();
      if (queued === undefined) break;
      if (!fromPriority) {
        this.#normalQueueBytes = Math.max(0, this.#normalQueueBytes - queued.estimatedBytes);
      }
      this.#queueBytes = Math.max(0, this.#queueBytes - queued.estimatedBytes);
      try {
        validateRuntimeDiagnosticValue(queued.event.attributes);
        batch.push(queued.event);
      } catch {
        this.#recordDrop("valueValidation");
      }
    }
    if (this.#pendingDropCount > 0 && batch.length < this.#batchSize) {
      const dropped = this.#makeDropSummary();
      if (dropped !== undefined) batch.push(dropped);
    }
    if (batch.length > 0) {
      const started = process.hrtime.bigint();
      try {
        this.#writer.appendEvents(batch);
        this.#committedEvents += batch.length;
        this.#lastBatchSize = batch.length;
        this.#lastCommitMicros = Number((process.hrtime.bigint() - started) / 1_000n);
        this.#lastWriterFailureType = undefined;
      } catch (error) {
        this.#writerErrors += 1;
        this.#droppedEvents += batch.length;
        this.#pendingDropCount += batch.length;
        this.#lastDropReason = "writerFailure";
        this.#lastWriterFailureType = error instanceof Error ? error.name : typeof error;
      }
    }
    if (this.#queueDepth > 0) this.#scheduleDrain(true);
  }

  #makeDropSummary(): RuntimeDiagnosticEvent | undefined {
    const count = this.#pendingDropCount;
    if (count === 0) return undefined;
    const now = process.hrtime.bigint();
    const windowMicros = Number((now - this.#dropWindowStarted) / 1_000n);
    this.#pendingDropCount = 0;
    this.#dropWindowStarted = now;
    const attributes = runtimeDiagnosticValue.object({
      count: runtimeDiagnosticValue.int64(BigInt(count)),
      reason: runtimeDiagnosticValue.string(this.#lastDropReason),
      windowMicros: runtimeDiagnosticValue.int64(BigInt(windowMicros)),
    });
    return this.#createEvent({
      attributes,
      definition: runtimeDiagnosticEvents.eventsDropped,
      phase: "instant",
      severity: "warn",
    });
  }

  #recordDrop(reason: string): void {
    this.#droppedEvents += 1;
    this.#pendingDropCount += 1;
    this.#lastDropReason = reason;
  }

  #dropQueued(queued: QueuedEvent, reason: string): void {
    this.#queueBytes = Math.max(0, this.#queueBytes - queued.estimatedBytes);
    this.#normalQueueBytes = Math.max(0, this.#normalQueueBytes - queued.estimatedBytes);
    this.#recordDrop(reason);
  }

  #dropAllQueued(reason: string): void {
    for (const queued of this.#normalQueue.splice(0)) this.#dropQueued(queued, reason);
    for (const queued of this.#priorityQueue.splice(0)) {
      this.#queueBytes = Math.max(0, this.#queueBytes - queued.estimatedBytes);
      this.#recordDrop(reason);
    }
  }

  #eligibleCapture(component: string, origin?: string): ActiveCapture | undefined {
    this.#expireCaptureIfNeeded();
    const capture = this.#activeCapture;
    if (capture === undefined) return undefined;
    const componentAllowed = capture.policy.components.size === 0 || capture.policy.components.has(component);
    const originAllowed = capture.policy.origins.size === 0 ||
      (origin !== undefined && capture.policy.origins.has(origin));
    return componentAllowed && originAllowed ? capture : undefined;
  }

  #expireCaptureIfNeeded(): void {
    if (
      this.#activeCapture !== undefined &&
      this.#activeCapture.expiresAtUnixMillis <= this.#clock().getTime()
    ) {
      this.#activeCapture = undefined;
    }
  }

  #validateConfiguration(): void {
    if (
      this.#batchSize <= 0 || this.#batchSize > 128 ||
      this.#flushTimeoutMillis <= 0 || this.#maxBatchDelayMillis <= 0 ||
      this.#maxQueueBytes <= 0 || this.#maxQueueEvents <= 0 ||
      this.#priorityReservedBytes < 0 || this.#priorityReservedBytes >= this.#maxQueueBytes ||
      this.#priorityReservedEvents < 0 || this.#priorityReservedEvents >= this.#maxQueueEvents
    ) {
      throw new RangeError("Runtime diagnostics manager configuration is invalid.");
    }
  }
}

export interface RuntimeDiagnosticSpanEndOptions {
  readonly attributes?: () => RuntimeDiagnosticObjectValue;
  readonly flags?: ReadonlySet<RuntimeDiagnosticEventFlag>;
  readonly severity?: RuntimeDiagnosticSeverity;
}

/** Owner span handle with a single, explicit terminal transition. */
export class RuntimeDiagnosticSpan {
  readonly captureOrigin: string | undefined;
  readonly definition: RuntimeDiagnosticEventDefinition;
  readonly severity: RuntimeDiagnosticSeverity | undefined;
  readonly startedAt: bigint;
  readonly trace: RuntimeDiagnosticTraceContext;
  readonly #manager: RuntimeDiagnosticsManager;
  #ended = false;
  #startEventId: string | undefined;

  constructor(
    manager: RuntimeDiagnosticsManager,
    options: RuntimeDiagnosticSpanOptions,
    trace: RuntimeDiagnosticTraceContext,
    startedAt: bigint,
  ) {
    this.#manager = manager;
    this.captureOrigin = options.captureOrigin;
    this.definition = options.definition;
    this.severity = options.severity;
    this.trace = trace;
    this.startedAt = startedAt;
  }

  get isEnded(): boolean {
    return this.#ended;
  }

  get startEventId(): string | undefined {
    return this.#startEventId;
  }

  setStartEventId(eventId: string | undefined): void {
    this.#startEventId = eventId;
  }

  end(
    outcome: RuntimeDiagnosticOutcome,
    options: RuntimeDiagnosticSpanEndOptions = {},
  ): RuntimeDiagnosticEvent | undefined {
    if (this.#ended) throw new Error("A Runtime diagnostic span can end exactly once.");
    this.#ended = true;
    return this.#manager.endSpan(this, outcome, options);
  }
}

function estimateEventBytes(event: RuntimeDiagnosticEvent): number {
  let estimate = 384 + event.summary.length * 2;
  for (const [key, value] of Object.entries(event.attributes.fields)) {
    estimate += key.length * 2 + 32;
    if (value.type === "string" || value.type === "int64") estimate += value.value.length * 2;
  }
  return Math.min(estimate, 32 * 1024);
}

function opaqueId(prefix: string): string {
  return `${prefix}-${randomUUID()}`;
}
