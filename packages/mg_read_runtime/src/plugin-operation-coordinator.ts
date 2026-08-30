/**
 * Per-plugin shared/exclusive operation coordinator.
 *
 * Responsibilities:
 * - allow bounded concurrent source invocations for one plugin;
 * - make cache cleanup exclusive without serializing ordinary capabilities;
 * - remove cancelled or expired waiters so a stalled plugin cannot grow an
 *   unbounded Promise tail.
 *
 * Boundaries:
 * - this coordinates work in the one Runtime VM; it cannot preempt synchronous
 *   plugin JavaScript or terminate a Promise that ignores cancellation;
 * - an acquired lease is released only when the underlying plugin work settles,
 *   even if its caller has already received cancellation or timeout.
 */
import { PluginManagerError } from "./plugin-manager-contract.js";

export const defaultPluginMaxActiveInvocations = 32;
export const defaultPluginMaxQueuedOperations = 256;

type PluginOperationMode = "exclusive" | "shared";
type PluginOperationRelease = () => void;

interface PluginOperationWaiter {
  readonly deadlineUnixMs: number;
  readonly mode: PluginOperationMode;
  readonly reject: (error: PluginManagerError) => void;
  readonly resolve: (release: PluginOperationRelease) => void;
  readonly signal: AbortSignal;
  abortListener: (() => void) | undefined;
  deadlineTimer: ReturnType<typeof setTimeout> | undefined;
  settled: boolean;
}

interface PluginOperationState {
  activeShared: number;
  exclusiveActive: boolean;
  readonly queue: PluginOperationWaiter[];
}

export interface PluginOperationCoordinatorOptions {
  readonly maxActiveInvocations?: number;
  readonly maxQueuedOperations?: number;
}

/** A fair, bounded reader/writer gate keyed by stable plugin id. */
export class PluginOperationCoordinator {
  readonly #maxActiveInvocations: number;
  readonly #maxQueuedOperations: number;
  readonly #states = new Map<string, PluginOperationState>();

  constructor(options: PluginOperationCoordinatorOptions = {}) {
    this.#maxActiveInvocations = positiveInteger(
      options.maxActiveInvocations,
      defaultPluginMaxActiveInvocations,
    );
    this.#maxQueuedOperations = positiveInteger(
      options.maxQueuedOperations,
      defaultPluginMaxQueuedOperations,
    );
  }

  acquireInvocation(
    pluginId: string,
    signal: AbortSignal,
    deadlineUnixMs: string,
  ): Promise<PluginOperationRelease> {
    return this.#acquire(pluginId, "shared", signal, deadlineUnixMs);
  }

  acquireCacheClear(
    pluginId: string,
    signal: AbortSignal,
    deadlineUnixMs: string,
  ): Promise<PluginOperationRelease> {
    return this.#acquire(pluginId, "exclusive", signal, deadlineUnixMs);
  }

  #acquire(
    pluginId: string,
    mode: PluginOperationMode,
    signal: AbortSignal,
    deadlineUnixMs: string,
  ): Promise<PluginOperationRelease> {
    const deadline = Number(deadlineUnixMs);
    if (!Number.isFinite(deadline)) {
      return Promise.reject(new PluginManagerError("invalid_request"));
    }
    if (signal.aborted) {
      return Promise.reject(new PluginManagerError("cancelled"));
    }
    if (deadline <= Date.now()) {
      return Promise.reject(new PluginManagerError("timeout"));
    }

    const state = this.#stateFor(pluginId);
    if (state.queue.length === 0 && this.#canGrant(state, mode)) {
      return Promise.resolve(this.#grant(pluginId, state, mode));
    }
    if (state.queue.length >= this.#maxQueuedOperations) {
      this.#cleanupState(pluginId, state);
      return Promise.reject(new PluginManagerError("overloaded"));
    }

    return new Promise<PluginOperationRelease>((resolve, reject) => {
      const waiter: PluginOperationWaiter = {
        deadlineUnixMs: deadline,
        mode,
        reject,
        resolve,
        signal,
        abortListener: undefined,
        deadlineTimer: undefined,
        settled: false,
      };
      waiter.abortListener = () => {
        this.#rejectWaiter(pluginId, state, waiter, "cancelled");
      };
      signal.addEventListener("abort", waiter.abortListener, { once: true });
      waiter.deadlineTimer = setTimeout(
        () => this.#rejectWaiter(pluginId, state, waiter, "timeout"),
        boundedTimerDelay(deadline - Date.now()),
      );
      state.queue.push(waiter);
    });
  }

  #stateFor(pluginId: string): PluginOperationState {
    let state = this.#states.get(pluginId);
    if (state === undefined) {
      state = { activeShared: 0, exclusiveActive: false, queue: [] };
      this.#states.set(pluginId, state);
    }
    return state;
  }

  #canGrant(state: PluginOperationState, mode: PluginOperationMode): boolean {
    if (state.exclusiveActive) return false;
    return mode === "shared"
      ? state.activeShared < this.#maxActiveInvocations
      : state.activeShared === 0;
  }

  #grant(
    pluginId: string,
    state: PluginOperationState,
    mode: PluginOperationMode,
  ): PluginOperationRelease {
    if (mode === "shared") {
      state.activeShared += 1;
    } else {
      state.exclusiveActive = true;
    }
    let released = false;
    return () => {
      if (released) return;
      released = true;
      if (mode === "shared") {
        state.activeShared = Math.max(0, state.activeShared - 1);
      } else {
        state.exclusiveActive = false;
      }
      this.#drain(pluginId, state);
    };
  }

  #drain(pluginId: string, state: PluginOperationState): void {
    if (state.exclusiveActive) return;
    while (state.queue.length > 0) {
      const waiter = state.queue[0]!;
      if (waiter.signal.aborted || waiter.deadlineUnixMs <= Date.now()) {
        state.queue.shift();
        waiter.settled = true;
        this.#cleanupWaiter(waiter);
        waiter.reject(new PluginManagerError(waiter.signal.aborted ? "cancelled" : "timeout"));
        continue;
      }
      if (!this.#canGrant(state, waiter.mode)) break;
      state.queue.shift();
      this.#cleanupWaiter(waiter);
      waiter.settled = true;
      waiter.resolve(this.#grant(pluginId, state, waiter.mode));
      if (waiter.mode === "exclusive") break;
    }
    this.#cleanupState(pluginId, state);
  }

  #rejectWaiter(
    pluginId: string,
    state: PluginOperationState,
    waiter: PluginOperationWaiter,
    code: "cancelled" | "timeout",
  ): void {
    if (waiter.settled) return;
    const index = state.queue.indexOf(waiter);
    if (index < 0) return;
    state.queue.splice(index, 1);
    waiter.settled = true;
    this.#cleanupWaiter(waiter);
    waiter.reject(new PluginManagerError(code));
    this.#drain(pluginId, state);
  }

  #cleanupWaiter(waiter: PluginOperationWaiter): void {
    if (waiter.abortListener !== undefined) {
      waiter.signal.removeEventListener("abort", waiter.abortListener);
      waiter.abortListener = undefined;
    }
    if (waiter.deadlineTimer !== undefined) {
      clearTimeout(waiter.deadlineTimer);
      waiter.deadlineTimer = undefined;
    }
  }

  #cleanupState(pluginId: string, state: PluginOperationState): void {
    if (
      state.activeShared === 0 &&
      !state.exclusiveActive &&
      state.queue.length === 0 &&
      this.#states.get(pluginId) === state
    ) {
      this.#states.delete(pluginId);
    }
  }
}

function positiveInteger(value: number | undefined, fallback: number): number {
  return value === undefined || !Number.isInteger(value) || value <= 0 ? fallback : value;
}

function boundedTimerDelay(value: number): number {
  return Math.max(1, Math.min(2_147_483_647, value));
}
