/**
 * Runtime-owned installed-source catalog and mutation boundary.
 *
 * Responsibilities:
 * - persist the compact, path-free metadata index used by normal cold starts;
 * - serialize every installed-source marker mutation behind one dirty journal;
 * - publish one observable change stream for install, enable, disable, activation,
 *   quarantine, scheduled removal, repair and removal.
 *
 * Boundaries:
 * - immutable version contents are still validated by PluginInstaller and again
 *   before first code execution;
 * - a missing, invalid or dirty index is never trusted and must be rebuilt by
 *   PluginManager from the installed version trees.
 */
import { readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

import type { InstalledPluginSnapshot } from "./plugin-manager-contract.js";
import {
  parsePluginPackageDescriptor,
  type PluginPackageDescriptor,
} from "./plugin-package.js";
import {
  atomicWrite,
  enabledStatus,
  exists,
  isPluginId,
  removePluginStorage,
  snapshotFrom,
} from "./plugin-manager-files.js";

const CATALOG_SCHEMA_VERSION = 1;
const MAX_CATALOG_ENTRIES = 1_024;

export type InstalledPluginCatalogChangeKind =
  | "activated"
  | "disabled"
  | "enabled"
  | "installed"
  | "quarantined"
  | "rebuilt"
  | "recovered"
  | "removal_scheduled"
  | "uninstalled";

export interface InstalledPluginCatalogChange {
  readonly itemCount: number;
  readonly kind: InstalledPluginCatalogChangeKind;
  readonly pluginId?: string;
  readonly revision: number;
}

export interface InstalledPluginCatalogRecord {
  readonly descriptor: PluginPackageDescriptor | undefined;
  readonly snapshot: InstalledPluginSnapshot;
  readonly uninstallPending: boolean;
}

type InstalledPluginCatalogListener = (change: InstalledPluginCatalogChange) => void;

/** One process-scoped owner for installed source metadata and marker changes. */
export class InstalledPluginCatalog {
  readonly #catalogPath: string;
  readonly #dataRoot: string;
  readonly #dirtyPath: string;
  readonly #listeners = new Set<InstalledPluginCatalogListener>();
  #records = new Map<string, InstalledPluginCatalogRecord>();
  #revision = 0;
  #tail: Promise<void> = Promise.resolve();
  #trusted = false;

  constructor(runtimeDataRoot: string) {
    this.#dataRoot = resolve(runtimeDataRoot);
    this.#catalogPath = resolve(this.#dataRoot, "plugin-catalog-v1.json");
    this.#dirtyPath = resolve(this.#dataRoot, "plugin-catalog-dirty");
  }

  observe(listener: InstalledPluginCatalogListener): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** Returns the trusted index, or undefined when a repair scan is required. */
  async load(): Promise<readonly InstalledPluginCatalogRecord[] | undefined> {
    await this.#tail;
    if (this.#trusted) return this.records;
    if (await exists(this.#dirtyPath)) return undefined;
    try {
      const decoded = decodeCatalog(
        JSON.parse(await readFile(this.#catalogPath, "utf8")) as unknown,
        this.#dataRoot,
      );
      this.#records = new Map(decoded.map((record) => [record.snapshot.id, record]));
      this.#trusted = true;
      return this.records;
    } catch {
      return undefined;
    }
  }

  get records(): readonly InstalledPluginCatalogRecord[] {
    return Object.freeze(
      [...this.#records.values()].sort((left, right) =>
        left.snapshot.id.localeCompare(right.snapshot.id)),
    );
  }

  record(pluginId: string): InstalledPluginCatalogRecord | undefined {
    return this.#records.get(pluginId);
  }

  /** Commits the result of a bounded repair scan as the new trusted baseline. */
  async recover(records: readonly InstalledPluginCatalogRecord[]): Promise<void> {
    await this.#enqueue(async () => {
      this.#records = new Map(records.map((record) => [record.snapshot.id, record]));
      await this.#write();
      await rm(this.#dirtyPath, { force: true });
      this.#trusted = true;
      this.#emit("rebuilt");
    });
  }

  /** Publishes an installed immutable version and its pending activation marker. */
  async installPending(
    descriptor: PluginPackageDescriptor,
    commitVersion: () => Promise<void>,
  ): Promise<void> {
    await this.#mutate("installed", descriptor.id, async () => {
      await commitVersion();
      await atomicWrite(
        resolve(this.#dataRoot, "plugins", descriptor.id, "pending"),
        `${descriptor.version}\n`,
      );
      const previous = this.#records.get(descriptor.id);
      // A user-disabled source remains disabled across upgrades. Quarantine is
      // a failed-version state, so installing a new pending version retries it.
      const enabled = previous?.snapshot.status === "disabled" ? false : true;
      const snapshot = snapshotFrom(
        descriptor,
        descriptor.id,
        previous?.snapshot.activeVersion ?? null,
        descriptor.version,
        enabled,
        enabled ? "pending" : "disabled",
      );
      this.#records.set(descriptor.id, Object.freeze({
        descriptor,
        snapshot,
        uninstallPending: false,
      }));
    });
  }

  async setEnabled(pluginId: string, enabled: boolean): Promise<InstalledPluginCatalogRecord | undefined> {
    let updated: InstalledPluginCatalogRecord | undefined;
    await this.#mutate(enabled ? "enabled" : "disabled", pluginId, async () => {
      const current = this.#records.get(pluginId);
      const pluginRoot = resolve(this.#dataRoot, "plugins", pluginId);
      if (enabled) {
        await rm(resolve(pluginRoot, "disabled"), { force: true });
        await rm(resolve(pluginRoot, "quarantined"), { force: true });
      } else {
        await atomicWrite(resolve(pluginRoot, "disabled"), "1\n");
      }
      if (current === undefined) {
        this.#trusted = false;
        return;
      }
      const snapshot = Object.freeze({
        ...current.snapshot,
        enabled,
        status: enabled ? enabledStatus(current.snapshot) : "disabled",
      } satisfies InstalledPluginSnapshot);
      updated = Object.freeze({ ...current, snapshot });
      this.#records.set(pluginId, updated);
    });
    return updated;
  }

  async activate(record: InstalledPluginCatalogRecord): Promise<void> {
    await this.#publishState("activated", record, async () => {
      const pluginRoot = this.#pluginRoot(record.snapshot.id);
      const previous = this.#records.get(record.snapshot.id)?.snapshot.activeVersion ?? null;
      const activated = record.snapshot.activeVersion;
      if (previous !== null && previous !== activated) {
        await atomicWrite(resolve(pluginRoot, "previous"), `${previous}\n`);
      }
      if (activated === null) throw new Error("plugin_catalog_activation_invalid");
      await atomicWrite(resolve(pluginRoot, "current"), `${activated}\n`);
      await rm(resolve(pluginRoot, "pending"), { force: true });
      await rm(resolve(pluginRoot, "quarantined"), { force: true });
    });
  }

  async quarantinePending(
    record: InstalledPluginCatalogRecord,
    failedVersion: string,
  ): Promise<void> {
    await this.#publishState("quarantined", record, async () => {
      const pluginRoot = this.#pluginRoot(record.snapshot.id);
      await atomicWrite(resolve(pluginRoot, "failed"), `${failedVersion}\n`);
      await rm(resolve(pluginRoot, "pending"), { force: true });
      await atomicWrite(resolve(pluginRoot, "quarantined"), `${failedVersion}\n`);
    });
  }

  async recoverPending(
    record: InstalledPluginCatalogRecord,
    failedVersion: string,
  ): Promise<void> {
    await this.#publishState("recovered", record, async () => {
      const pluginRoot = this.#pluginRoot(record.snapshot.id);
      await atomicWrite(resolve(pluginRoot, "failed"), `${failedVersion}\n`);
      await rm(resolve(pluginRoot, "pending"), { force: true });
    });
  }

  async quarantineCurrent(
    record: InstalledPluginCatalogRecord,
    version: string,
  ): Promise<void> {
    await this.#publishState(
      "quarantined",
      record,
      () => atomicWrite(resolve(this.#pluginRoot(record.snapshot.id), "quarantined"), `${version}\n`),
    );
  }

  async scheduleRemoval(pluginId: string): Promise<void> {
    await this.#mutate("removal_scheduled", pluginId, async () => {
      const current = this.#records.get(pluginId);
      await atomicWrite(
        resolve(this.#dataRoot, "plugins", pluginId, "uninstall-pending"),
        "1\n",
      );
      if (current === undefined) {
        this.#trusted = false;
        return;
      }
      this.#records.set(pluginId, Object.freeze({ ...current, uninstallPending: true }));
    });
  }

  async remove(pluginId: string): Promise<void> {
    await this.#mutate("uninstalled", pluginId, async () => {
      await removePluginStorage(this.#dataRoot, pluginId);
      this.#records.delete(pluginId);
    });
  }

  async #publishState(
    kind: "activated" | "quarantined" | "recovered",
    record: InstalledPluginCatalogRecord,
    updateMarkers: () => Promise<void>,
  ): Promise<void> {
    await this.#mutate(kind, record.snapshot.id, async () => {
      await updateMarkers();
      this.#records.set(record.snapshot.id, record);
    });
  }

  #pluginRoot(pluginId: string): string {
    return resolve(this.#dataRoot, "plugins", pluginId);
  }

  async #mutate(
    kind: InstalledPluginCatalogChangeKind,
    pluginId: string,
    operation: () => Promise<void>,
  ): Promise<void> {
    await this.#enqueue(async () => {
      await writeFile(this.#dirtyPath, "1\n", { mode: 0o600 });
      try {
        await operation();
        if (this.#trusted) {
          await this.#write();
          await rm(this.#dirtyPath, { force: true });
        }
        this.#emit(kind, pluginId);
      } catch (error) {
        this.#trusted = false;
        throw error;
      }
    });
  }

  async #write(): Promise<void> {
    const entries = this.records.map((record) => encodeRecord(record));
    await atomicWrite(this.#catalogPath, `${JSON.stringify({
      entries,
      schemaVersion: CATALOG_SCHEMA_VERSION,
    })}\n`);
  }

  #enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation, operation);
    this.#tail = result.then(() => undefined, () => undefined);
    return result;
  }

  #emit(kind: InstalledPluginCatalogChangeKind, pluginId?: string): void {
    const change = Object.freeze({
      itemCount: this.#records.size,
      kind,
      ...(pluginId === undefined ? {} : { pluginId }),
      revision: ++this.#revision,
    } satisfies InstalledPluginCatalogChange);
    for (const listener of this.#listeners) {
      try { listener(change); } catch { /* Observation must not change catalog state. */ }
    }
  }
}

function encodeRecord(record: InstalledPluginCatalogRecord): Readonly<Record<string, unknown>> {
  const descriptor = record.descriptor;
  return Object.freeze({
    activeVersion: record.snapshot.activeVersion,
    descriptor: descriptor === undefined ? null : {
      contentKinds: descriptor.contentKinds,
      ...(descriptor.description === undefined ? {} : { description: descriptor.description }),
      displayName: descriptor.displayName,
      entry: descriptor.entry,
      id: descriptor.id,
      ...(descriptor.icon === undefined ? {} : { icon: descriptor.icon }),
      name: descriptor.name,
      packageMode: descriptor.packageMode,
      pluginApi: descriptor.pluginApi,
      version: descriptor.version,
    },
    enabled: record.snapshot.enabled,
    id: record.snapshot.id,
    pendingVersion: record.snapshot.pendingVersion,
    status: record.snapshot.status,
    uninstallPending: record.uninstallPending,
  });
}

function decodeCatalog(value: unknown, dataRoot: string): readonly InstalledPluginCatalogRecord[] {
  if (!isRecord(value) || value.schemaVersion !== CATALOG_SCHEMA_VERSION ||
      !Array.isArray(value.entries) || value.entries.length > MAX_CATALOG_ENTRIES) {
    throw new Error("plugin_catalog_invalid");
  }
  const seen = new Set<string>();
  return Object.freeze(value.entries.map((entry) => {
    if (!isRecord(entry) || typeof entry.id !== "string" || !isPluginId(entry.id) || seen.has(entry.id) ||
        typeof entry.enabled !== "boolean" || typeof entry.uninstallPending !== "boolean" ||
        !isVersionOrNull(entry.activeVersion) || !isVersionOrNull(entry.pendingVersion) ||
        !isInstalledStatus(entry.status)) throw new Error("plugin_catalog_invalid");
    seen.add(entry.id);
    const descriptor = entry.descriptor === null
      ? undefined
      : decodeDescriptor(entry.descriptor, entry.id, dataRoot);
    if (descriptor !== undefined && descriptor.version !== entry.activeVersion &&
        descriptor.version !== entry.pendingVersion) throw new Error("plugin_catalog_invalid");
    const snapshot = snapshotFrom(
      descriptor,
      entry.id,
      entry.activeVersion,
      entry.pendingVersion,
      entry.enabled,
      entry.status,
    );
    return Object.freeze({ descriptor, snapshot, uninstallPending: entry.uninstallPending });
  }));
}

function decodeDescriptor(value: unknown, pluginId: string, dataRoot: string): PluginPackageDescriptor {
  if (!isRecord(value) || value.id !== pluginId || typeof value.name !== "string" ||
      typeof value.version !== "string" || typeof value.entry !== "string" ||
      typeof value.displayName !== "string" || value.pluginApi !== 1 ||
      (value.packageMode !== "archive" && value.packageMode !== "single-file") ||
      !Array.isArray(value.contentKinds) ||
      (value.description !== undefined && typeof value.description !== "string") ||
      (value.icon !== undefined && typeof value.icon !== "string")) {
    throw new Error("plugin_catalog_invalid");
  }
  const projectRoot = resolve(dataRoot, "plugins", pluginId, "versions", value.version);
  return parsePluginPackageDescriptor({
    engines: { node: ">=24 <25" },
    main: value.entry,
    mgread: {
      contentKinds: value.contentKinds,
      ...(value.description === undefined ? {} : { description: value.description }),
      displayName: value.displayName,
      id: value.id,
      ...(value.icon === undefined ? {} : { icon: value.icon }),
      packageMode: value.packageMode,
      pluginApi: value.pluginApi,
      schemaVersion: 1,
    },
    name: value.name,
    type: "module",
    version: value.version,
  }, projectRoot);
}

function isVersionOrNull(value: unknown): value is string | null {
  return value === null || (typeof value === "string" &&
    /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/.test(value));
}

function isInstalledStatus(value: unknown): value is InstalledPluginSnapshot["status"] {
  return value === "active" || value === "damaged" || value === "disabled" ||
    value === "pending" || value === "quarantined";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
