import { createHash, randomUUID } from "node:crypto";
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
import { dirname, join, relative, sep } from "node:path";

import {
  type RuntimeDiagnosticAttachmentRange,
  type RuntimeDiagnosticCaptureState,
  type RuntimeDiagnosticPrivacyClass,
} from "./contracts.js";
import { redactRuntimeDiagnosticText } from "./privacy.js";

export interface RuntimeDiagnosticStoredObject {
  readonly captureState: RuntimeDiagnosticCaptureState;
  readonly objectKey: string;
  readonly rawByteLength: number;
  readonly sha256: string;
  readonly storedByteLength: number;
  readonly truncationReason?: string;
}

interface StoreStreamOptions {
  readonly maxStoredBytes: number;
  readonly privacyClass: RuntimeDiagnosticPrivacyClass;
  readonly sanitizeText: boolean;
}

const maximumTextLineCodeUnits = 64 * 1024;
const maximumInputChunkBytes = 64 * 1024;

/** Immutable content-addressed object files owned only by Runtime diagnostics. */
export class RuntimeDiagnosticObjectStore {
  readonly #diagnosticsRoot: string;
  readonly #objectsRoot: string;
  readonly #stagingRoot: string;

  private constructor(diagnosticsRoot: string) {
    this.#diagnosticsRoot = diagnosticsRoot;
    this.#objectsRoot = join(diagnosticsRoot, "objects");
    this.#stagingRoot = join(diagnosticsRoot, "staging");
  }

  static async open(diagnosticsRoot: string): Promise<RuntimeDiagnosticObjectStore> {
    const store = new RuntimeDiagnosticObjectStore(diagnosticsRoot);
    await mkdir(store.#objectsRoot, { recursive: true });
    await mkdir(store.#stagingRoot, { recursive: true });
    await store.cleanStaging();
    return store;
  }

  async writeBytes(
    bytes: Uint8Array,
    options: Omit<StoreStreamOptions, "sanitizeText">,
  ): Promise<RuntimeDiagnosticStoredObject> {
    return this.writeStream(
      (async function* (): AsyncGenerator<Uint8Array> {
        yield bytes;
      })(),
      { ...options, sanitizeText: false },
    );
  }

  /**
   * Streams into staging with a hard byte bound. Text is redacted line by line;
   * an attacker-controlled unbounded line is replaced, never retained in RAM.
   */
  async writeStream(
    chunks: AsyncIterable<Uint8Array>,
    options: StoreStreamOptions,
  ): Promise<RuntimeDiagnosticStoredObject> {
    if (!Number.isSafeInteger(options.maxStoredBytes) || options.maxStoredBytes <= 0) {
      throw new RangeError("Diagnostic object byte limit must be positive.");
    }
    if (options.privacyClass === "secret" || options.privacyClass === "restricted") {
      throw new Error("Secret and restricted diagnostic objects are not persistable in D3.");
    }

    const stagingPath = join(this.#stagingRoot, `${randomUUID()}.partial`);
    const handle = await open(stagingPath, "wx", 0o600);
    const hash = createHash("sha256");
    let rawByteLength = 0;
    let storedByteLength = 0;
    let truncationReason: string | undefined;
    const redactor = options.sanitizeText ? new BoundedTextRedactor() : undefined;

    const persist = async (value: Uint8Array): Promise<void> => {
      if (value.byteLength === 0 || truncationReason !== undefined) return;
      const remaining = options.maxStoredBytes - storedByteLength;
      if (remaining <= 0) {
        truncationReason = "sizeLimit";
        return;
      }
      const accepted = value.byteLength <= remaining ? value : value.subarray(0, remaining);
      await handle.write(accepted);
      hash.update(accepted);
      storedByteLength += accepted.byteLength;
      if (accepted.byteLength !== value.byteLength) truncationReason = "sizeLimit";
    };

    try {
      for await (const suppliedChunk of chunks) {
        const chunk = suppliedChunk instanceof Uint8Array
          ? suppliedChunk
          : new Uint8Array(suppliedChunk);
        rawByteLength += chunk.byteLength;
        for (let offset = 0; offset < chunk.byteLength; offset += maximumInputChunkBytes) {
          const boundedChunk = chunk.subarray(
            offset,
            Math.min(offset + maximumInputChunkBytes, chunk.byteLength),
          );
          if (redactor === undefined) {
            await persist(boundedChunk);
          } else {
            for (const output of redactor.push(boundedChunk, false)) await persist(output);
          }
        }
      }
      if (redactor !== undefined) {
        for (const output of redactor.push(new Uint8Array(), true)) await persist(output);
      }
      await handle.sync();
    } catch (error) {
      await closeQuietly(handle);
      await rm(stagingPath, { force: true });
      throw error;
    }
    await handle.close();

    const sha256 = hash.digest("hex");
    const objectKey = `${options.privacyClass}/${sha256.slice(0, 2)}/${sha256.slice(2, 4)}/${sha256}`;
    const destination = this.#resolveObjectKey(objectKey);
    await mkdir(dirname(destination), { recursive: true });
    try {
      await stat(destination);
      await rm(stagingPath, { force: true });
    } catch (error) {
      if (!isMissingFile(error)) {
        await rm(stagingPath, { force: true });
        throw error;
      }
      await rename(stagingPath, destination);
      await chmod(destination, 0o600).catch(() => undefined);
    }
    return Object.freeze({
      captureState: truncationReason === undefined ? "captured" : "truncated",
      objectKey,
      rawByteLength,
      sha256,
      storedByteLength,
      ...(truncationReason === undefined ? {} : { truncationReason }),
    });
  }

  async readRange(
    objectKey: string,
    range: RuntimeDiagnosticAttachmentRange,
  ): Promise<{ readonly bytes: Uint8Array; readonly totalBytes: number }> {
    if (
      !Number.isSafeInteger(range.offset) ||
      range.offset < 0 ||
      !Number.isSafeInteger(range.length) ||
      range.length <= 0 ||
      range.length > 64 * 1024
    ) {
      throw new RangeError("Diagnostic attachment ranges are limited to 64 KiB.");
    }
    const path = this.#resolveObjectKey(objectKey);
    const file = await open(path, "r");
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

  async delete(objectKey: string): Promise<boolean> {
    const path = this.#resolveObjectKey(objectKey);
    try {
      await rm(path);
      return true;
    } catch (error) {
      if (isMissingFile(error)) return false;
      throw error;
    }
  }

  async listObjectKeys(): Promise<ReadonlySet<string>> {
    const result = new Set<string>();
    await walkFiles(this.#objectsRoot, async (path) => {
      const key = relative(this.#objectsRoot, path).split(sep).join("/");
      this.#resolveObjectKey(key);
      result.add(key);
    });
    return result;
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
        .filter((entry) => entry.isFile() && entry.name.endsWith(".partial"))
        .map((entry) => rm(join(this.#stagingRoot, entry.name), { force: true })),
    );
  }

  /** Only generated keys are accepted; neither key nor path leaves the store. */
  #resolveObjectKey(objectKey: string): string {
    if (!/^(?:public|internal|content)\/[a-f0-9]{2}\/[a-f0-9]{2}\/[a-f0-9]{64}$/.test(objectKey)) {
      throw new TypeError("Invalid internal diagnostic object key.");
    }
    const path = join(this.#objectsRoot, ...objectKey.split("/"));
    const relativePath = relative(this.#objectsRoot, path);
    if (relativePath.startsWith("..") || relativePath.includes(`..${sep}`)) {
      throw new Error("Diagnostic object key escaped its owned root.");
    }
    return path;
  }
}

/** Bounded UTF-8 line sanitizer for contentPayload text streams. */
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

async function walkFiles(
  root: string,
  visitor: (path: string) => Promise<void>,
): Promise<void> {
  const entries = await readdir(root, { withFileTypes: true }).catch(
    (error: unknown) => {
      if (isMissingFile(error)) return [];
      throw error;
    },
  );
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) await walkFiles(path, visitor);
    else if (entry.isFile()) await visitor(path);
  }
}

async function closeQuietly(handle: FileHandle): Promise<void> {
  await handle.close().catch(() => undefined);
}

function isMissingFile(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "ENOENT"
  );
}
