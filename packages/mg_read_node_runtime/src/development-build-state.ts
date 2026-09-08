/**
 * Runtime-private development build input ledger.
 *
 * It detects edits made while the App was closed. Only source/build inputs are
 * fingerprinted here; generated `dist`, artifacts, tests and dependencies are
 * deliberately excluded. A fingerprint is committed only after the matching
 * generation and transferable artifact have both succeeded.
 */
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const SCHEMA_VERSION = 1;
const MAX_FILES = 4_096;
const MAX_BYTES = 32 * 1024 * 1024;

export interface DevelopmentSourceState {
  readonly fingerprint: string;
  readonly requiresBuild: boolean;
}

/** Compares current source inputs with the last successfully published build. */
export async function inspectDevelopmentSourceState(
  dataRoot: string,
  pluginId: string,
  projectRoot: string,
): Promise<DevelopmentSourceState> {
  const paths = await sourceInputPaths(projectRoot);
  const fingerprint = await hashPaths(projectRoot, paths);
  const previous = await readCommittedFingerprint(dataRoot, pluginId);
  if (previous !== undefined) {
    return Object.freeze({ fingerprint, requiresBuild: previous !== fingerprint });
  }
  return Object.freeze({
    fingerprint,
    requiresBuild: !await generatedOutputIsAtLeastAsNew(projectRoot, paths),
  });
}

/** Persists the source inputs belonging to one fully published development build. */
export async function commitDevelopmentSourceFingerprint(
  dataRoot: string,
  pluginId: string,
  fingerprint: string,
): Promise<void> {
  const path = statePath(dataRoot, pluginId);
  const temporary = `${path}.next-${randomUUID()}`;
  await mkdir(dirname(path), { recursive: true });
  await writeFile(temporary, `${JSON.stringify({
    fingerprint,
    pluginId,
    schemaVersion: SCHEMA_VERSION,
  })}\n`, { flag: "wx", mode: 0o600 });
  try {
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true }).catch(() => {});
  }
}

async function readCommittedFingerprint(
  dataRoot: string,
  pluginId: string,
): Promise<string | undefined> {
  try {
    const decoded = JSON.parse(await readFile(statePath(dataRoot, pluginId), "utf8")) as unknown;
    if (!isRecord(decoded) || decoded.schemaVersion !== SCHEMA_VERSION ||
        decoded.pluginId !== pluginId || typeof decoded.fingerprint !== "string" ||
        !/^[a-f0-9]{64}$/.test(decoded.fingerprint)) return undefined;
    return decoded.fingerprint;
  } catch {
    return undefined;
  }
}

function statePath(dataRoot: string, pluginId: string): string {
  return resolve(dataRoot, "development-source-state", `${pluginId}.json`);
}

async function sourceInputPaths(projectRoot: string): Promise<readonly string[]> {
  const paths: string[] = [];
  const rootEntries = await readdir(projectRoot, { withFileTypes: true });
  for (const entry of rootEntries) {
    if (entry.isFile() && (
      entry.name === "package.json" || entry.name === "package-lock.json" ||
      entry.name === "build.mjs" || /^tsconfig(?:\.[A-Za-z0-9_-]+)?\.json$/.test(entry.name)
    )) paths.push(entry.name);
  }
  for (const directory of ["src", "assets", "packages", "tools"]) {
    await collectFiles(projectRoot, directory, paths);
  }
  paths.sort((left, right) => left.localeCompare(right));
  if (paths.length === 0 || paths.length > MAX_FILES) throw new Error("development_source_inputs_invalid");
  return Object.freeze(paths);
}

async function collectFiles(root: string, relative: string, output: string[]): Promise<void> {
  let entries;
  try {
    entries = await readdir(resolve(root, relative), { withFileTypes: true });
  } catch (error) {
    if (isMissing(error)) return;
    throw error;
  }
  for (const entry of entries) {
    const child = `${relative}/${entry.name}`;
    if (entry.isDirectory()) await collectFiles(root, child, output);
    else if (entry.isFile()) output.push(child);
  }
}

async function hashPaths(root: string, paths: readonly string[]): Promise<string> {
  const hash = createHash("sha256");
  let totalBytes = 0;
  for (const path of paths) {
    const bytes = await readFile(resolve(root, path));
    totalBytes += bytes.byteLength;
    if (totalBytes > MAX_BYTES) throw new Error("development_source_inputs_too_large");
    hash.update(path.replaceAll("\\", "/"));
    hash.update("\0");
    hash.update(bytes);
    hash.update("\0");
  }
  return hash.digest("hex");
}

async function generatedOutputIsAtLeastAsNew(
  root: string,
  sourcePaths: readonly string[],
): Promise<boolean> {
  const outputPaths: string[] = [];
  await collectFiles(root, "dist", outputPaths);
  if (outputPaths.length === 0) return false;
  const sourceStats = await Promise.all(sourcePaths.map((path) => stat(resolve(root, path))));
  const outputStats = await Promise.all(outputPaths.map((path) => stat(resolve(root, path))));
  const newestSource = Math.max(...sourceStats.map((value) => value.mtimeMs));
  const newestOutput = Math.max(...outputStats.map((value) => value.mtimeMs));
  return newestOutput >= newestSource;
}

function isMissing(error: unknown): boolean {
  return isRecord(error) && error.code === "ENOENT";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
