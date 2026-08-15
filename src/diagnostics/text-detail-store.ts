import { createHash } from "node:crypto";
import {
  chmod,
  mkdir,
  open,
  readdir,
  rename,
  rm,
  stat,
  type FileHandle,
} from "node:fs/promises";
import { join } from "node:path";

import {
  type RuntimeDiagnosticAttachmentRange,
  type RuntimeDiagnosticCaptureState,
  type RuntimeDiagnosticPrivacyClass,
  validateRuntimeDiagnosticOpaqueId,
} from "./contracts.js";
import { redactRuntimeDiagnosticText } from "./privacy.js";

export interface RuntimeDiagnosticStoredTextDetail {
  readonly captureState: RuntimeDiagnosticCaptureState;
  readonly detailKey: string;
  readonly persisted: boolean;
  readonly rawByteLength: number;
  readonly sha256: string;
  readonly storedByteLength: number;
  readonly truncationReason?: string;
}

export interface RuntimeDiagnosticTextDetailStatistics {
  readonly detailCount: number;
  readonly detailTextBytes: number;
  readonly memoryDetailBytes: number;
}

interface StoreStreamOptions {
  readonly maxStoredBytes: number;
  readonly persistToText: boolean;
  readonly privacyClass: RuntimeDiagnosticPrivacyClass;
  readonly sanitizeText: boolean;
}

// Minified JSON/HTML commonly has no newline. This buffer exists only after an
// explicit detail-capture gate and is bounded to the same 8 MiB ceiling as one
// stored attachment, so ordinary Runtime operation never pays this cost.
const maximumTextLineCodeUnits = 8 * 1024 * 1024;
const maximumInputChunkBytes = 64 * 1024;

/** Debug-only text detail storage with an 8 MiB global memory ceiling. */
export class RuntimeDiagnosticTextDetailStore {
  readonly #detailsRoot: string;
  readonly #maxMemoryBytes: number;
  readonly #memory = new Map<string, Uint8Array>();
  readonly #stagingRoot: string;
  #memoryBytes = 0;

  private constructor(diagnosticsRoot: string, maxMemoryBytes: number) {
    this.#detailsRoot = join(diagnosticsRoot, "details");
    this.#stagingRoot = join(diagnosticsRoot, "staging");
    this.#maxMemoryBytes = maxMemoryBytes;
  }

  static async open(
    diagnosticsRoot: string,
    maxMemoryBytes = 8 * 1024 * 1024,
  ): Promise<RuntimeDiagnosticTextDetailStore> {
    if (!Number.isSafeInteger(maxMemoryBytes) || maxMemoryBytes <= 0) {
      throw new RangeError("Runtime diagnostic memory detail limit must be positive.");
    }
    const store = new RuntimeDiagnosticTextDetailStore(diagnosticsRoot, maxMemoryBytes);
    await mkdir(store.#detailsRoot, { recursive: true });
    await mkdir(store.#stagingRoot, { recursive: true });
    await store.cleanStaging();
    return store;
  }

  async writeStream(
    detailKey: string,
    chunks: AsyncIterable<Uint8Array>,
    options: StoreStreamOptions,
  ): Promise<RuntimeDiagnosticStoredTextDetail> {
    validateRuntimeDiagnosticOpaqueId(detailKey, "detailKey");
    if (!Number.isSafeInteger(options.maxStoredBytes) || options.maxStoredBytes <= 0) {
      throw new RangeError("Diagnostic detail byte limit must be positive.");
    }
    if (options.privacyClass === "secret" || options.privacyClass === "restricted") {
      throw new Error("Secret and restricted diagnostic details are unavailable.");
    }
    const memoryRemaining = this.#maxMemoryBytes - this.#memoryBytes;
    if (!options.persistToText && memoryRemaining <= 0) {
      return Object.freeze({
        captureState: "pressureDropped",
        detailKey,
        persisted: false,
        rawByteLength: 0,
        sha256: createHash("sha256").digest("hex"),
        storedByteLength: 0,
        truncationReason: "detailMemoryPressure",
      });
    }
    const byteLimit = options.persistToText
      ? options.maxStoredBytes
      : Math.min(options.maxStoredBytes, memoryRemaining);
    const stagingPath = join(this.#stagingRoot, `${detailKey}.partial.txt`);
    const handle = options.persistToText ? await open(stagingPath, "wx", 0o600) : undefined;
    const parts: Uint8Array[] = [];
    const hash = createHash("sha256");
    const redactor = options.sanitizeText ? new BoundedTextRedactor() : undefined;
    let rawByteLength = 0;
    let storedByteLength = 0;
    let truncationReason: string | undefined;

    const persist = async (value: Uint8Array): Promise<void> => {
      if (value.byteLength === 0 || truncationReason !== undefined) return;
      const remaining = byteLimit - storedByteLength;
      if (remaining <= 0) {
        truncationReason = options.persistToText ? "sizeLimit" : "detailMemoryPressure";
        return;
      }
      const accepted = value.byteLength <= remaining ? value : value.subarray(0, remaining);
      if (handle === undefined) parts.push(Uint8Array.from(accepted));
      else await handle.write(accepted);
      hash.update(accepted);
      storedByteLength += accepted.byteLength;
      if (accepted.byteLength !== value.byteLength) {
        truncationReason = options.persistToText ? "sizeLimit" : "detailMemoryPressure";
      }
    };

    try {
      for await (const suppliedChunk of chunks) {
        const chunk = suppliedChunk instanceof Uint8Array
          ? suppliedChunk
          : new Uint8Array(suppliedChunk);
        rawByteLength += chunk.byteLength;
        for (let offset = 0; offset < chunk.byteLength; offset += maximumInputChunkBytes) {
          const bounded = chunk.subarray(
            offset,
            Math.min(offset + maximumInputChunkBytes, chunk.byteLength),
          );
          if (redactor === undefined) await persist(bounded);
          else for (const output of redactor.push(bounded, false)) await persist(output);
        }
      }
      if (redactor !== undefined) {
        for (const output of redactor.push(new Uint8Array(), true)) await persist(output);
      }
      await handle?.sync();
    } catch (error) {
      await closeQuietly(handle);
      if (handle !== undefined) await rm(stagingPath, { force: true });
      throw error;
    }
    await handle?.close();

    if (options.persistToText) {
      const destination = this.#pathFor(detailKey);
      await rm(destination, { force: true });
      await rename(stagingPath, destination);
      await chmod(destination, 0o600).catch(() => undefined);
    } else {
      const stored = concatParts(parts, storedByteLength);
      this.#memory.set(detailKey, stored);
      this.#memoryBytes += stored.byteLength;
    }
    return Object.freeze({
      captureState: truncationReason === undefined ? "captured" : "truncated",
      detailKey,
      persisted: options.persistToText,
      rawByteLength,
      sha256: hash.digest("hex"),
      storedByteLength,
      ...(truncationReason === undefined ? {} : { truncationReason }),
    });
  }

  async readRange(
    detailKey: string,
    range: RuntimeDiagnosticAttachmentRange,
  ): Promise<{ readonly bytes: Uint8Array; readonly totalBytes: number }> {
    validateRuntimeDiagnosticOpaqueId(detailKey, "detailKey");
    validateRange(range);
    const memory = this.#memory.get(detailKey);
    if (memory !== undefined) {
      const end = Math.min(memory.byteLength, range.offset + range.length);
      return Object.freeze({
        bytes: memory.subarray(Math.min(range.offset, memory.byteLength), end),
        totalBytes: memory.byteLength,
      });
    }
    let file: FileHandle;
    try {
      file = await open(this.#pathFor(detailKey), "r");
    } catch (error) {
      if (isMissingFile(error)) {
        throw new Error("Diagnostic detail payload does not exist.");
      }
      throw error;
    }
    try {
      const metadata = await file.stat();
      const available = Math.max(0, metadata.size - range.offset);
      const length = Math.min(range.length, available);
      const buffer = Buffer.allocUnsafe(length);
      const { bytesRead } = await file.read(buffer, 0, length, range.offset);
      return Object.freeze({
        bytes: buffer.subarray(0, bytesRead),
        totalBytes: metadata.size,
      });
    } finally {
      await file.close();
    }
  }

  async delete(detailKey: string): Promise<boolean> {
    validateRuntimeDiagnosticOpaqueId(detailKey, "detailKey");
    const memory = this.#memory.get(detailKey);
    if (memory !== undefined) {
      this.#memory.delete(detailKey);
      this.#memoryBytes -= memory.byteLength;
      return true;
    }
    try {
      await rm(this.#pathFor(detailKey));
      return true;
    } catch (error) {
      if (isMissingFile(error)) return false;
      throw error;
    }
  }

  clearMemory(detailKeys: Iterable<string>): void {
    for (const key of detailKeys) {
      const memory = this.#memory.get(key);
      if (memory === undefined) continue;
      this.#memory.delete(key);
      this.#memoryBytes -= memory.byteLength;
    }
  }

  clearAllMemory(): void {
    this.#memory.clear();
    this.#memoryBytes = 0;
  }

  async listDetailKeys(): Promise<ReadonlySet<string>> {
    const result = new Set(this.#memory.keys());
    const entries = await readdir(this.#detailsRoot, { withFileTypes: true }).catch(
      (error: unknown) => {
        if (isMissingFile(error)) return [];
        throw error;
      },
    );
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".txt")) continue;
      const key = entry.name.slice(0, -4);
      validateRuntimeDiagnosticOpaqueId(key, "detailKey");
      result.add(key);
    }
    return result;
  }

  async getStatistics(): Promise<RuntimeDiagnosticTextDetailStatistics> {
    let detailCount = this.#memory.size;
    let detailTextBytes = 0;
    const entries = await readdir(this.#detailsRoot, { withFileTypes: true }).catch(
      (error: unknown) => {
        if (isMissingFile(error)) return [];
        throw error;
      },
    );
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".txt")) continue;
      detailCount += 1;
      detailTextBytes += (await stat(join(this.#detailsRoot, entry.name))).size;
    }
    return Object.freeze({
      detailCount,
      detailTextBytes,
      memoryDetailBytes: this.#memoryBytes,
    });
  }

  async cleanStaging(): Promise<void> {
    const entries = await readdir(this.#stagingRoot, { withFileTypes: true }).catch(
      (error: unknown) => {
        if (isMissingFile(error)) return [];
        throw error;
      },
    );
    await Promise.all(
      entries
        .filter((entry) => entry.isFile() && entry.name.endsWith(".partial.txt"))
        .map((entry) => rm(join(this.#stagingRoot, entry.name), { force: true })),
    );
  }

  #pathFor(detailKey: string): string {
    validateRuntimeDiagnosticOpaqueId(detailKey, "detailKey");
    return join(this.#detailsRoot, `${detailKey}.txt`);
  }
}

/** Bounded UTF-8 line sanitizer for content payload streams. */
class BoundedTextRedactor {
  readonly #decoder = new TextDecoder("utf-8", { fatal: false });
  readonly #encoder = new TextEncoder();
  #buffer = "";
  #discardLongLine = false;

  push(chunk: Uint8Array, final: boolean): readonly Uint8Array[] {
    const decoded = this.#decoder.decode(chunk, { stream: !final });
    this.#buffer += decoded;
    const output: Uint8Array[] = [];
    while (true) {
      const newline = this.#buffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.#buffer.slice(0, newline + 1);
      this.#buffer = this.#buffer.slice(newline + 1);
      if (this.#discardLongLine) {
        output.push(this.#encoder.encode("<redacted-long-line>\n"));
        this.#discardLongLine = false;
      } else {
        output.push(this.#encoder.encode(redactRuntimeDiagnosticText(line)));
      }
    }
    if (this.#buffer.length > maximumTextLineCodeUnits) {
      this.#buffer = "";
      this.#discardLongLine = true;
    }
    if (final && (this.#buffer.length > 0 || this.#discardLongLine)) {
      output.push(
        this.#encoder.encode(
          this.#discardLongLine
            ? "<redacted-long-line>"
            : redactRuntimeDiagnosticText(this.#buffer),
        ),
      );
      this.#buffer = "";
      this.#discardLongLine = false;
    }
    return output;
  }
}

function concatParts(parts: readonly Uint8Array[], totalBytes: number): Uint8Array {
  const result = new Uint8Array(totalBytes);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.byteLength;
  }
  return result;
}

function validateRange(range: RuntimeDiagnosticAttachmentRange): void {
  if (
    !Number.isSafeInteger(range.offset) ||
    range.offset < 0 ||
    !Number.isSafeInteger(range.length) ||
    range.length <= 0 ||
    range.length > 64 * 1024
  ) {
    throw new RangeError("Diagnostic attachment ranges are limited to 64 KiB.");
  }
}

async function closeQuietly(handle: FileHandle | undefined): Promise<void> {
  await handle?.close().catch(() => undefined);
}

function isMissingFile(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "ENOENT"
  );
}
