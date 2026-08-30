/**
 * Runtime-private development-sync revision registry.
 *
 * A successfully activated development fingerprint receives one stable,
 * monotonic revision. Reopening the Runtime with unchanged build inputs keeps
 * the same revision, while a newly activated fingerprint always sorts after
 * every previous local development build.
 */
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const schemaVersion = 1;
const maximumEntries = 128;
const revisionQueues = new Map<string, Promise<void>>();

interface DevelopmentSyncEntry {
  readonly fingerprint: string;
  readonly revision: number;
}

interface DevelopmentSyncState {
  readonly entries: Readonly<Record<string, DevelopmentSyncEntry>>;
  readonly lastRevision: number;
  readonly schemaVersion: number;
}

/** Returns the stable revision for one activated project fingerprint. */
export async function resolveDevelopmentSyncRevision(
  dataRoot: string,
  pluginId: string,
  fingerprint: string,
): Promise<number> {
  const path = resolve(dataRoot, "development-sync-revisions.json");
  const previousTurn = revisionQueues.get(path) ?? Promise.resolve();
  let releaseTurn!: () => void;
  const gate = new Promise<void>((resolveGate) => { releaseTurn = resolveGate; });
  const currentTurn = previousTurn.catch(() => {}).then(() => gate);
  revisionQueues.set(path, currentTurn);
  await previousTurn.catch(() => {});
  try {
    return await resolveRevision(path, pluginId, fingerprint);
  } finally {
    releaseTurn();
    if (revisionQueues.get(path) === currentTurn) revisionQueues.delete(path);
  }
}

async function resolveRevision(
  path: string,
  pluginId: string,
  fingerprint: string,
): Promise<number> {
  const previous = await readState(path);
  const existing = previous.entries[pluginId];
  if (existing?.fingerprint === fingerprint) return existing.revision;

  const revision = Math.max(Date.now(), previous.lastRevision + 1);
  const ordered = Object.entries({
    ...previous.entries,
    [pluginId]: Object.freeze({ fingerprint, revision }),
  })
    .sort((left, right) => right[1].revision - left[1].revision)
    .slice(0, maximumEntries);
  await writeState(path, Object.freeze({
    entries: Object.freeze(Object.fromEntries(ordered)),
    lastRevision: revision,
    schemaVersion,
  }));
  return revision;
}

async function readState(path: string): Promise<DevelopmentSyncState> {
  try {
    const decoded = JSON.parse(await readFile(path, "utf8")) as unknown;
    if (!isState(decoded)) return emptyState();
    return Object.freeze({
      entries: Object.freeze(decoded.entries),
      lastRevision: decoded.lastRevision,
      schemaVersion,
    });
  } catch {
    return emptyState();
  }
}

async function writeState(path: string, state: DevelopmentSyncState): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state)}\n`, { flag: "w", mode: 0o600 });
  try {
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

function emptyState(): DevelopmentSyncState {
  return Object.freeze({ entries: Object.freeze({}), lastRevision: 0, schemaVersion });
}

function isState(value: unknown): value is DevelopmentSyncState {
  if (!isRecord(value) || value.schemaVersion !== schemaVersion ||
      !Number.isSafeInteger(value.lastRevision) || (value.lastRevision as number) < 0 ||
      !isRecord(value.entries) || Object.keys(value.entries).length > maximumEntries) return false;
  return Object.entries(value.entries).every(([pluginId, entry]) =>
    /^[a-z0-9][a-z0-9.-]{0,127}$/.test(pluginId) && isRecord(entry) &&
    typeof entry.fingerprint === "string" && /^[a-f0-9]{64}$/.test(entry.fingerprint) &&
    Number.isSafeInteger(entry.revision) && (entry.revision as number) > 0
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
