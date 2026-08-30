import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { DevelopmentPluginMonitor } from "../dist/development-plugin-monitor.js";

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}

async function createProject(root, name) {
  const project = join(root, name);
  await mkdir(join(project, "src"), { recursive: true });
  await writeFile(join(project, "package.json"), `{"name":"${name}"}\n`);
  return project;
}

async function waitFor(predicate, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for monitor state.");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("development monitor debounces per project and limits global build concurrency", async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-monitor-");
  const projects = await Promise.all([
    createProject(root, "source-a"),
    createProject(root, "source-b"),
    createProject(root, "source-c"),
  ]);
  let active = 0;
  let maximumActive = 0;
  const built = [];
  const monitor = new DevelopmentPluginMonitor({
    developmentRoot: root,
    npmCliPath: join(root, "unused-npm-cli.js"),
    settleDelayMs: 30,
    maxConcurrentBuilds: 2,
    buildRunner: async (projectRoot) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 70));
      active -= 1;
      return true;
    },
    onBuilt: (projectRoot) => built.push(projectRoot),
    onBuildFailed: () => assert.fail("build must succeed"),
    onRemoved: () => assert.fail("project must remain present"),
  });
  await monitor.start();
  t.after(() => monitor.close());

  await Promise.all(projects.map(async (project, index) => {
    const source = join(project, "src", "index.ts");
    await writeFile(source, `export const value = ${index};\n`);
    await writeFile(source, `export const value = ${index + 10};\n`);
  }));
  await waitFor(() => built.length === 3);

  assert.equal(maximumActive, 2);
  assert.deepEqual(new Set(built), new Set(projects));
});

test("a save during build makes the result stale and queues one serial rebuild", async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-stale-");
  const project = await createProject(root, "source-a");
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  let signalStarted;
  const firstStarted = new Promise((resolve) => { signalStarted = resolve; });
  let runs = 0;
  const built = [];
  const monitor = new DevelopmentPluginMonitor({
    developmentRoot: root,
    npmCliPath: join(root, "unused-npm-cli.js"),
    settleDelayMs: 25,
    buildRunner: async () => {
      runs += 1;
      if (runs === 1) {
        signalStarted();
        await firstGate;
      }
      return true;
    },
    onBuilt: (projectRoot) => built.push(projectRoot),
    onBuildFailed: () => assert.fail("build must succeed"),
    onRemoved: () => assert.fail("project must remain present"),
  });
  await monitor.start();
  t.after(() => monitor.close());

  const source = join(project, "src", "index.ts");
  await writeFile(source, "export const value = 1;\n");
  await firstStarted;
  await writeFile(source, "export const value = 2;\n");
  await new Promise((resolve) => setTimeout(resolve, 60));
  releaseFirst();
  await waitFor(() => built.length === 1);

  assert.equal(runs, 2);
  assert.deepEqual(built, [project]);
});

test("development monitor reports project deletion and closes without retained work", async (t) => {
  const root = await temporaryDirectory(t, "mgread-development-remove-");
  const project = await createProject(root, "source-a");
  const removed = [];
  const monitor = new DevelopmentPluginMonitor({
    developmentRoot: root,
    npmCliPath: join(root, "unused-npm-cli.js"),
    settleDelayMs: 25,
    buildRunner: async () => true,
    onBuilt: () => {},
    onBuildFailed: () => assert.fail("build must succeed"),
    onRemoved: (projectRoot) => removed.push(projectRoot),
  });
  await monitor.start();
  await rm(project, { force: true, recursive: true });
  await waitFor(() => removed.length === 1);
  await monitor.close();
  await writeFile(join(root, "ignored.txt"), "closed\n");
  await new Promise((resolve) => setTimeout(resolve, 60));

  assert.deepEqual(removed, [project]);
});
