import type { RuntimeDiagnosticCaptureState } from "./contracts.js";

export interface RuntimeDiagnosticSpoolCompletion {
  readonly captureState?: RuntimeDiagnosticCaptureState;
  readonly rawByteLength: number;
  readonly truncationReason?: string;
}

/**
 * Non-blocking diagnostic branch for a business byte stream.
 *
 * Producers only copy into a fixed byte window. When the writer falls behind,
 * the branch closes and marks pressureDropped while the business consumer keeps
 * receiving the original chunks.
 */
export class RuntimeDiagnosticAttachmentSpool implements AsyncIterable<Uint8Array> {
  readonly #maxQueuedBytes: number;
  readonly #queue: Uint8Array[] = [];
  #closed = false;
  #consumed = false;
  #queueBytes = 0;
  #queueHighWater = 0;
  #rawByteLength = 0;
  #terminalState: RuntimeDiagnosticCaptureState | undefined;
  #truncationReason: string | undefined;
  #wake: (() => void) | undefined;

  constructor(maxQueuedBytes = 256 * 1024) {
    if (!Number.isSafeInteger(maxQueuedBytes) || maxQueuedBytes <= 0) {
      throw new RangeError("Diagnostic attachment spool limit must be positive.");
    }
    this.#maxQueuedBytes = maxQueuedBytes;
  }

  get queueHighWater(): number {
    return this.#queueHighWater;
  }

  get completion(): RuntimeDiagnosticSpoolCompletion {
    return Object.freeze({
      ...(this.#terminalState === undefined ? {} : { captureState: this.#terminalState }),
      rawByteLength: this.#rawByteLength,
      ...(this.#truncationReason === undefined
        ? {}
        : { truncationReason: this.#truncationReason }),
    });
  }

  offer(chunk: Uint8Array): boolean {
    this.#rawByteLength += chunk.byteLength;
    if (this.#closed || this.#terminalState !== undefined) return false;
    if (chunk.byteLength > this.#maxQueuedBytes ||
      this.#queueBytes + chunk.byteLength > this.#maxQueuedBytes) {
      this.#terminalState = "pressureDropped";
      this.#truncationReason = "spoolPressure";
      this.#closed = true;
      this.#notify();
      return false;
    }
    const owned = Uint8Array.from(chunk);
    this.#queue.push(owned);
    this.#queueBytes += owned.byteLength;
    this.#queueHighWater = Math.max(this.#queueHighWater, this.#queueBytes);
    this.#notify();
    return true;
  }

  finish(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#notify();
  }

  truncate(reason: string): void {
    if (this.#closed) return;
    this.#terminalState = "truncated";
    this.#truncationReason = reason;
    this.#closed = true;
    this.#notify();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<Uint8Array> {
    if (this.#consumed) throw new Error("A diagnostic attachment spool has one consumer.");
    this.#consumed = true;
    while (true) {
      const chunk = this.#queue.shift();
      if (chunk !== undefined) {
        this.#queueBytes -= chunk.byteLength;
        yield chunk;
        continue;
      }
      if (this.#closed) return;
      await new Promise<void>((resolve) => {
        this.#wake = resolve;
      });
    }
  }

  #notify(): void {
    const wake = this.#wake;
    this.#wake = undefined;
    wake?.();
  }
}
