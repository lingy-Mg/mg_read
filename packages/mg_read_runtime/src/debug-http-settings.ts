/**
 * Runtime Debug HTTP operational settings.
 *
 * Responsibilities:
 * - retain only the Debug inspector enable preference in the Runtime data root;
 * - atomically replace the tiny setting document without retaining diagnostics.
 *
 * Boundaries:
 * - never stores endpoints, requests, source data, credentials, or logs;
 * - unreadable/corrupt settings safely fall back to the disabled default.
 */
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const settingsFileName = "debug-http.json";
const settingsDirectoryName = "runtime-settings";

/** Owns the Runtime-private, durable Debug inspector preference. */
export class RuntimeDebugHttpSettings {
  readonly #path: string;

  constructor(dataRoot: string) {
    this.#path = resolve(dataRoot, settingsDirectoryName, settingsFileName);
  }

  async readEnabled(): Promise<boolean> {
    try {
      const value: unknown = JSON.parse(await readFile(this.#path, "utf8"));
      return isDebugHttpSettings(value) && value.enabled;
    } catch {
      return false;
    }
  }

  async writeEnabled(enabled: boolean): Promise<void> {
    const temporaryPath = `${this.#path}.tmp-${process.pid}-${Date.now()}`;
    await mkdir(dirname(this.#path), { recursive: true });
    try {
      await writeFile(temporaryPath, `${JSON.stringify({ enabled })}\n`, {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      await rename(temporaryPath, this.#path);
    } finally {
      await rm(temporaryPath, { force: true });
    }
  }
}

function isDebugHttpSettings(value: unknown): value is { readonly enabled: boolean } {
  return typeof value === "object" && value !== null && "enabled" in value && typeof value.enabled === "boolean";
}
