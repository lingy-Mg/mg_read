/**
 * Desktop development-project monitor.
 *
 * Responsibilities:
 * - coalesce source-project filesystem changes by project;
 * - run the changed project's existing npm build with bounded concurrency;
 * - report only stable project-level outcomes to PluginManager.
 *
 * Boundaries:
 * - this never packages or installs an artifact;
 * - it never runs npm install or falls back to ambient Node/npm executables;
 * - Android never constructs this monitor.
 */
import { spawn } from "node:child_process";
import { watch, type FSWatcher } from "node:fs";
import { access, readdir } from "node:fs/promises";
import { delimiter, dirname, resolve } from "node:path";

// A source save is normally followed by more saves while an editor/AI is
// writing a change set. Keep the quiet period short, but cap the total wait
// from the first save so a continuously changing project still reloads.
const DEFAULT_SETTLE_DELAY_MS = 2_000;
const DEFAULT_MAX_SETTLE_DELAY_MS = 10_000;
const DEFAULT_MAX_CONCURRENT_BUILDS = 2;
const MAX_BUILD_OUTPUT_BYTES = 64 * 1024;

export interface DevelopmentBuildResult {
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly stderr: string;
  readonly stdout: string;
  readonly success: boolean;
}

export type DevelopmentBuildRunner = (
  projectRoot: string,
) => Promise<DevelopmentBuildResult | boolean>;

export interface DevelopmentPluginMonitorOptions {
  readonly developmentRoot: string;
  readonly npmCliPath: string;
  readonly onBuildFailed: (projectRoot: string, result: DevelopmentBuildResult) => Promise<void> | void;
  readonly onBuilt: (projectRoot: string) => Promise<void> | void;
  readonly onRemoved: (projectRoot: string) => Promise<void> | void;
  readonly buildRunner?: DevelopmentBuildRunner;
  readonly maxConcurrentBuilds?: number;
  readonly settleDelayMs?: number;
  readonly maxSettleDelayMs?: number;
}

interface ProjectMonitorState {
  building: boolean;
  pendingAfterBuild: boolean;
  queued: boolean;
  revision: number;
  suppressDistUntil: number;
  debounceStartedAt: number | undefined;
  timer: NodeJS.Timeout | undefined;
}

/** One recursive watcher and a bounded project build queue. */
export class DevelopmentPluginMonitor {
  readonly #developmentRoot: string;
  readonly #onBuildFailed: DevelopmentPluginMonitorOptions["onBuildFailed"];
  readonly #onBuilt: DevelopmentPluginMonitorOptions["onBuilt"];
  readonly #onRemoved: DevelopmentPluginMonitorOptions["onRemoved"];
  readonly #buildRunner: DevelopmentBuildRunner;
  readonly #maxConcurrentBuilds: number;
  readonly #settleDelayMs: number;
  readonly #maxSettleDelayMs: number;
  readonly #states = new Map<string, ProjectMonitorState>();
  readonly #queue: string[] = [];
  readonly #activeBuilds = new Set<Promise<void>>();
  #watcher: FSWatcher | undefined;
  #closed = false;

  constructor(options: DevelopmentPluginMonitorOptions) {
    this.#developmentRoot = resolve(options.developmentRoot);
    this.#onBuildFailed = options.onBuildFailed;
    this.#onBuilt = options.onBuilt;
    this.#onRemoved = options.onRemoved;
    this.#maxConcurrentBuilds = options.maxConcurrentBuilds ?? DEFAULT_MAX_CONCURRENT_BUILDS;
    this.#settleDelayMs = options.settleDelayMs ?? DEFAULT_SETTLE_DELAY_MS;
    this.#maxSettleDelayMs = options.maxSettleDelayMs ?? DEFAULT_MAX_SETTLE_DELAY_MS;
    this.#buildRunner = options.buildRunner ?? createNpmBuildRunner(options.npmCliPath);
  }

  /** Arms the watcher before PluginManager takes its initial project snapshot. */
  async start(): Promise<void> {
    await access(this.#developmentRoot);
    this.#watcher = watch(
      this.#developmentRoot,
      { recursive: true },
      (_eventType, filename) => this.#onFileEvent(filename),
    );
    this.#watcher.on("error", () => {
      void this.#scheduleAllProjects();
    });
  }

  /** Stops new work, cancels timers and waits for already-started builds. */
  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    this.#watcher?.close();
    this.#watcher = undefined;
    for (const state of this.#states.values()) {
      if (state.timer !== undefined) clearTimeout(state.timer);
    }
    this.#queue.length = 0;
    await Promise.allSettled([...this.#activeBuilds]);
    this.#states.clear();
  }

  /** Runs one explicitly requested catch-up build without publishing it. */
  async buildNow(projectRoot: string): Promise<DevelopmentBuildResult> {
    try {
      const result = await this.#buildRunner(resolve(projectRoot));
      return typeof result === "boolean"
        ? {
            exitCode: result ? 0 : 1,
            signal: null,
            stderr: "",
            stdout: "",
            success: result,
          }
        : result;
    } catch (error) {
      return {
        exitCode: null,
        signal: null,
        stderr: error instanceof Error ? `${error.message}\n` : "",
        stdout: "",
        success: false,
      };
    }
  }

  #onFileEvent(filename: string | Buffer | null): void {
    if (this.#closed) return;
    if (filename === null) {
      void this.#scheduleAllProjects();
      return;
    }
    const normalized = filename.toString().replaceAll("\\", "/");
    const parts = normalized.split("/").filter((part) => part.length > 0);
    const projectName = parts[0];
    if (projectName === undefined || projectName.startsWith(".")) return;
    const projectRelativePath = parts.slice(1).join("/");
    if (!isRelevantDevelopmentPath(projectRelativePath)) return;
    const projectRoot = resolve(this.#developmentRoot, projectName);
    const state = this.#stateFor(projectRoot);
    if (
      projectRelativePath.startsWith("dist/") &&
      (state.building || Date.now() < state.suppressDistUntil)
    ) {
      return;
    }
    this.#schedule(projectRoot, state);
  }

  async #scheduleAllProjects(): Promise<void> {
    if (this.#closed) return;
    let entries;
    try {
      entries = await readdir(this.#developmentRoot, { withFileTypes: true });
    } catch {
      return;
    }
    const existingRoots = new Set<string>();
    for (const entry of entries) {
      if (entry.isDirectory() && !entry.name.startsWith(".")) {
        const projectRoot = resolve(this.#developmentRoot, entry.name);
        existingRoots.add(projectRoot);
        this.#schedule(projectRoot, this.#stateFor(projectRoot));
      }
    }
    for (const projectRoot of this.#states.keys()) {
      if (!existingRoots.has(projectRoot)) {
        this.#schedule(projectRoot, this.#stateFor(projectRoot));
      }
    }
  }

  #stateFor(projectRoot: string): ProjectMonitorState {
    let state = this.#states.get(projectRoot);
    if (state === undefined) {
      state = {
        building: false,
        pendingAfterBuild: false,
        queued: false,
        revision: 0,
        suppressDistUntil: 0,
        debounceStartedAt: undefined,
        timer: undefined,
      };
      this.#states.set(projectRoot, state);
    }
    return state;
  }

  #schedule(projectRoot: string, state: ProjectMonitorState): void {
    state.revision += 1;
    const now = Date.now();
    state.debounceStartedAt ??= now;
    if (state.timer !== undefined) clearTimeout(state.timer);
    const remainingMaxDelay = Math.max(
      0,
      state.debounceStartedAt + this.#maxSettleDelayMs - now,
    );
    state.timer = setTimeout(() => {
      state.timer = undefined;
      state.debounceStartedAt = undefined;
      this.#enqueue(projectRoot, state);
    }, Math.min(this.#settleDelayMs, remainingMaxDelay));
  }

  #enqueue(projectRoot: string, state: ProjectMonitorState): void {
    if (this.#closed) return;
    if (state.building) {
      state.pendingAfterBuild = true;
      return;
    }
    if (state.queued) return;
    state.queued = true;
    this.#queue.push(projectRoot);
    this.#drain();
  }

  #drain(): void {
    while (!this.#closed && this.#activeBuilds.size < this.#maxConcurrentBuilds) {
      const projectRoot = this.#queue.shift();
      if (projectRoot === undefined) return;
      const state = this.#stateFor(projectRoot);
      state.queued = false;
      const task = this.#run(projectRoot, state).finally(() => {
        this.#activeBuilds.delete(task);
        if (!this.#closed && state.pendingAfterBuild && !state.queued) {
          state.pendingAfterBuild = false;
          state.queued = true;
          this.#queue.push(projectRoot);
        }
        this.#drain();
      });
      this.#activeBuilds.add(task);
    }
  }

  async #run(projectRoot: string, state: ProjectMonitorState): Promise<void> {
    if (this.#closed) return;
    const revision = state.revision;
    try {
      await access(projectRoot);
    } catch {
      await this.#onRemoved(projectRoot);
      this.#states.delete(projectRoot);
      return;
    }
    try {
      await access(resolve(projectRoot, "package.json"));
    } catch {
      // A source collection can contain draft or leftover directories. Only a
      // project manifest makes one eligible for build/reload work.
      await this.#onRemoved(projectRoot);
      this.#states.delete(projectRoot);
      return;
    }

    state.building = true;
    let result: DevelopmentBuildResult = {
      exitCode: null,
      signal: null,
      stderr: "",
      stdout: "",
      success: false,
    };
    try {
      const buildResult = await this.#buildRunner(projectRoot);
      result = typeof buildResult === "boolean"
        ? { ...result, success: buildResult }
        : buildResult;
    } catch {
      // A failed runner is reported with the same bounded failure shape as a
      // non-zero npm build. The normal npm runner includes spawn errors below.
    } finally {
      state.building = false;
      state.suppressDistUntil = Date.now() + 500;
    }
    if (this.#closed) return;
    if (state.revision !== revision) return;
    if (!result.success) {
      await this.#onBuildFailed(projectRoot, result);
      return;
    }
    await this.#onBuilt(projectRoot);
  }
}

/** Filters watcher noise without recursively walking any project. */
function isRelevantDevelopmentPath(path: string): boolean {
  if (path.length === 0) return true;
  if (path === "package.json" || path === "package-lock.json") return true;
  if (path === "node_modules/.package-lock.json") return true;
  const root = path.split("/", 1)[0];
  if (root === undefined) return false;
  if (root === "node_modules" || root === "test" || root === "coverage" || root === ".git") {
    return false;
  }
  if (root === ".mgread-runtime" || root === ".dart_tool" || root === "build") return false;
  return root === "src" || root === "dist" || root === "assets" ||
    root === "packages" || root === "tools" ||
    /^tsconfig(?:\.[A-Za-z0-9_-]+)?\.json$/.test(path) || path === "build.mjs";
}

/** Runs the declared build through the repository-pinned npm CLI and Node. */
function createNpmBuildRunner(npmCliPath: string): DevelopmentBuildRunner {
  const normalizedNpmCli = resolve(npmCliPath);
  return (projectRoot) => new Promise<DevelopmentBuildResult>((complete) => {
    const nodeDirectory = dirname(process.execPath);
    const currentPath = process.env.PATH ?? process.env.Path ?? "";
    const stdout: string[] = [];
    const stderr: string[] = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    const append = (target: string[], chunk: string, currentBytes: number): number => {
      const remaining = MAX_BUILD_OUTPUT_BYTES - currentBytes;
      if (remaining <= 0) return currentBytes;
      const bounded = Buffer.from(chunk, "utf8").subarray(0, remaining).toString("utf8");
      target.push(bounded);
      return currentBytes + Buffer.byteLength(bounded, "utf8");
    };
    const finish = (result: DevelopmentBuildResult): void => {
      if (settled) return;
      settled = true;
      complete(result);
    };
    const child = spawn(
      process.execPath,
      [normalizedNpmCli, "run", "build"],
      {
        cwd: projectRoot,
        env: {
          ...process.env,
          PATH: `${nodeDirectory}${delimiter}${currentPath}`,
          Path: `${nodeDirectory}${delimiter}${currentPath}`,
          ...(process.platform === "win32"
            ? {}
            : { npm_config_script_shell: "/bin/sh" }),
          npm_execpath: normalizedNpmCli,
          npm_node_execpath: process.execPath,
        },
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      },
    );
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      stdoutBytes = append(stdout, chunk, stdoutBytes);
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      stderrBytes = append(stderr, chunk, stderrBytes);
    });
    child.once("error", (error) => {
      stderrBytes = append(stderr, `${error.message}\n`, stderrBytes);
      finish({
        exitCode: null,
        signal: null,
        stderr: stderr.join(""),
        stdout: stdout.join(""),
        success: false,
      });
    });
    child.once("close", (code, signal) => finish({
      exitCode: code,
      signal,
      stderr: stderr.join(""),
      stdout: stdout.join(""),
      success: code === 0 && signal === null,
    }));
  });
}
