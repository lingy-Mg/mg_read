import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  copyFile,
  cp,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import test from "node:test";

import {
  createPluginArchive,
  DependencyStore,
  extractPluginArchive,
  PluginArchiveError,
  PluginInstaller,
  PluginManager,
  readPluginProject,
} from "../dist/index.js";

const fixtureRoot = fileURLToPath(
  new URL("./fixtures/standard-plugin/", import.meta.url),
);

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}

test("standard project uses package.json metadata and npm lockfile only", async () => {
  const project = await readPluginProject(fixtureRoot);
  assert.equal(project.descriptor.id, "org.mgread.runtime.fixture");
  assert.equal(project.descriptor.entry, "dist/index.mjs");
  assert.deepEqual(project.descriptor.contentKinds, ["novel"]);
  assert.deepEqual(project.dependencies, [
    {
      installPath: "node_modules/local-helper",
      kind: "local",
      optional: false,
      resolved: "packages/local-helper",
      sourcePath: "packages/local-helper",
      version: "1.0.0",
    },
  ]);
});

test("mgplugin is deterministic, excludes node_modules and rejects traversal", async (t) => {
  const root = await temporaryDirectory(t, "mgread-plugin-archive-");
  const first = join(root, "first.mgplugin");
  const second = join(root, "second.mgplugin");
  await createPluginArchive(fixtureRoot, first);
  await createPluginArchive(fixtureRoot, second);
  assert.deepEqual(await readFile(first), await readFile(second));

  const extracted = join(root, "extracted");
  const paths = await extractPluginArchive(first, extracted);
  assert.ok(paths.includes("package.json"));
  assert.ok(paths.includes("package-lock.json"));
  assert.ok(paths.includes("assets/rules.json"));
  assert.ok(paths.includes("packages/local-helper/index.js"));
  assert.equal(paths.some((path) => path.includes("node_modules")), false);
  await readPluginProject(extracted);

  const malicious = Buffer.from(await readFile(first));
  replaceAllAscii(malicious, "package.json", "../evil.json");
  const maliciousFile = join(root, "malicious.mgplugin");
  await writeFile(maliciousFile, malicious);
  await assert.rejects(
    extractPluginArchive(maliciousFile, join(root, "unsafe")),
    (error) =>
      error instanceof PluginArchiveError &&
      error.code === "plugin_archive_unsafe_path",
  );
});

test("installer hardlinks local packages and manager cold-activates named exports", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-plugin-install-");
  const installEvents = [];
  const installer = new PluginInstaller(dataRoot, {
    events: (event) => installEvents.push(event),
  });
  const installed = await installer.installProject(fixtureRoot);
  assert.equal(installed.pendingActivation, true);
  assert.equal(installed.reusedVersion, false);
  assert.ok(installed.hardlinkedFiles >= 2);
  assert.equal(installed.copiedFiles, 0);
  assert.deepEqual(
    installEvents.map((event) => event.code),
    ["plugin_install_started", "plugin_install_completed"],
  );

  const pluginRoot = join(
    dataRoot,
    "plugins",
    "org.mgread.runtime.fixture",
  );
  assert.equal((await readFile(join(pluginRoot, "pending"), "utf8")).trim(), "1.0.0");
  const source = await stat(
    join(pluginRoot, "versions", "1.0.0", "packages", "local-helper", "index.js"),
    { bigint: true },
  );
  const installedDependency = await stat(
    join(pluginRoot, "versions", "1.0.0", "node_modules", "local-helper", "index.js"),
    { bigint: true },
  );
  assert.equal(source.ino, installedDependency.ino);

  const managerEvents = [];
  const manager = new PluginManager(dataRoot, {
    events: (event) => managerEvents.push(event),
  });
  await manager.initialize();
  const plugins = await manager.listInstalled();
  assert.equal(plugins.length, 1);
  assert.equal(plugins[0].status, "active");
  assert.equal(plugins[0].activeVersion, "1.0.0");
  assert.equal(await fileExists(join(pluginRoot, "pending")), false);

  const search = await manager.search(
    "org.mgread.runtime.fixture",
    "测试",
    new AbortController().signal,
    String(Date.now() + 5_000),
  );
  assert.equal(search.items[0].title, "标准插件：测试");
  assert.equal(search.items[0].author, "org.mgread.runtime.fixture");
  assert.deepEqual(
    JSON.parse(
      await readFile(
        join(dataRoot, "plugin-data", "org.mgread.runtime.fixture", "activated.json"),
        "utf8",
      ),
    ),
    { pluginApi: 1 },
  );
  assert.equal(
    managerEvents.filter((event) => event.code === "plugin_load_started").length,
    1,
  );
  assert.equal(
    managerEvents.filter((event) => event.code === "plugin_load_completed").length,
    1,
  );
  assert.equal(
    managerEvents.filter((event) => event.code === "plugin_invocation_completed").length,
    1,
  );
});

test("registry dependencies are verified, shared once, copied on hardlink failure and swept", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-dependency-store-");
  const tarball = makeNpmTarball({
    "package.json": JSON.stringify({
      name: "fixture-dependency",
      version: "1.0.0",
      type: "module",
      main: "index.js",
    }),
    "index.js": "export const suffix = '共享依赖';\n",
    "data/rules.json": "{\"enabled\":true}\n",
    "wasm/parser.wasm": Buffer.from([0, 97, 115, 109]),
  });
  const integrity = `sha512-${createHash("sha512").update(tarball).digest("base64")}`;
  let downloads = 0;
  const fetchPackage = async () => {
    downloads += 1;
    return {
      ok: true,
      status: 200,
      async arrayBuffer() {
        return tarball.buffer.slice(
          tarball.byteOffset,
          tarball.byteOffset + tarball.byteLength,
        );
      },
    };
  };
  const store = new DependencyStore(dataRoot, { fetchPackage });
  const installer = new PluginInstaller(dataRoot, { dependencyStore: store });
  const firstProject = await createRegistryPlugin(
    join(dataRoot, "project-a"),
    "org.example.registry.a",
    "@mgread-plugin/registry-a",
    integrity,
  );
  const secondProject = await createRegistryPlugin(
    join(dataRoot, "project-b"),
    "org.example.registry.b",
    "@mgread-plugin/registry-b",
    integrity,
  );
  const [first, second] = await Promise.all([
    installer.installProject(firstProject),
    installer.installProject(secondProject),
  ]);
  assert.equal(downloads, 1);
  assert.ok(first.hardlinkedFiles >= 4);
  assert.ok(second.hardlinkedFiles >= 4);
  assert.equal((await installer.collectUnusedDependencies()).removedObjects, 0);

  await installer.scheduleUninstall("org.example.registry.a");
  await installer.scheduleUninstall("org.example.registry.b");
  await new PluginManager(dataRoot).initialize();
  assert.equal((await installer.collectUnusedDependencies()).removedObjects, 1);

  const copyRoot = await temporaryDirectory(t, "mgread-dependency-copy-");
  const copyStore = new DependencyStore(copyRoot, {
    fetchPackage,
    hardlinkFile: async () => {
      throw Object.assign(new Error("hardlink unavailable"), { code: "EPERM" });
    },
  });
  const copyInstaller = new PluginInstaller(copyRoot, {
    dependencyStore: copyStore,
  });
  const copyProject = await createRegistryPlugin(
    join(copyRoot, "project"),
    "org.example.registry.copy",
    "@mgread-plugin/registry-copy",
    integrity,
  );
  const copied = await copyInstaller.installProject(copyProject);
  assert.equal(copied.hardlinkedFiles, 0);
  assert.ok(copied.copiedFiles >= 4);
});

test("integrity failure produces one install terminal and leaves no version", async (t) => {
  const dataRoot = await temporaryDirectory(t, "mgread-integrity-failure-");
  const tarball = makeNpmTarball({
    "package.json": "{\"name\":\"bad\",\"version\":\"1.0.0\"}",
    "index.js": "export {};\n",
  });
  const events = [];
  const store = new DependencyStore(dataRoot, {
    fetchPackage: async () => ({
      ok: true,
      status: 200,
      async arrayBuffer() {
        return tarball.buffer.slice(
          tarball.byteOffset,
          tarball.byteOffset + tarball.byteLength,
        );
      },
    }),
  });
  const installer = new PluginInstaller(dataRoot, {
    dependencyStore: store,
    events: (event) => events.push(event),
  });
  const project = await createRegistryPlugin(
    join(dataRoot, "project"),
    "org.example.integrity",
    "@mgread-plugin/integrity",
    `sha512-${Buffer.alloc(64).toString("base64")}`,
  );
  await assert.rejects(installer.installProject(project));
  assert.deepEqual(
    events.map((event) => event.code),
    ["plugin_install_started", "plugin_install_failed"],
  );
  assert.equal(
    await fileExists(
      join(dataRoot, "plugins", "org.example.integrity", "versions", "1.0.0"),
    ),
    false,
  );
});

async function createRegistryPlugin(root, id, name, integrity) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageJson = {
    name,
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    dependencies: { "fixture-dependency": "1.0.0" },
    mgread: {
      schemaVersion: 1,
      id,
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name,
    version: "1.0.0",
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": {
        name,
        version: "1.0.0",
        dependencies: { "fixture-dependency": "1.0.0" },
      },
      "node_modules/fixture-dependency": {
        version: "1.0.0",
        resolved:
          "https://registry.npmjs.org/fixture-dependency/-/fixture-dependency-1.0.0.tgz",
        integrity,
      },
    },
  };
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(
      join(root, "dist", "index.mjs"),
      "export async function search(keyword) { return [{ id: keyword, title: keyword }]; }\n",
    ),
  ]);
  return root;
}

function makeNpmTarball(files) {
  const parts = [];
  for (const [path, value] of Object.entries(files)) {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
    const header = Buffer.alloc(512);
    writeTarString(header, 0, 100, `package/${path}`);
    writeTarOctal(header, 100, 8, 0o444);
    writeTarOctal(header, 108, 8, 0);
    writeTarOctal(header, 116, 8, 0);
    writeTarOctal(header, 124, 12, bytes.length);
    writeTarOctal(header, 136, 12, 0);
    header.fill(0x20, 148, 156);
    header[156] = "0".charCodeAt(0);
    writeTarString(header, 257, 6, "ustar");
    writeTarString(header, 263, 2, "00");
    let checksum = 0;
    for (const byte of header) checksum += byte;
    const checksumText = checksum.toString(8).padStart(6, "0");
    header.write(checksumText, 148, 6, "ascii");
    header[154] = 0;
    header[155] = 0x20;
    const padding = Buffer.alloc((512 - (bytes.length % 512)) % 512);
    parts.push(header, bytes, padding);
  }
  parts.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(parts), { level: 9, mtime: 0 });
}

function writeTarString(buffer, offset, length, value) {
  const bytes = Buffer.from(value);
  assert.ok(bytes.length <= length);
  bytes.copy(buffer, offset);
}

function writeTarOctal(buffer, offset, length, value) {
  const text = value.toString(8).padStart(length - 1, "0") + "\0";
  buffer.write(text, offset, length, "ascii");
}

function replaceAllAscii(buffer, from, to) {
  assert.equal(Buffer.byteLength(from), Buffer.byteLength(to));
  const source = Buffer.from(from);
  const replacement = Buffer.from(to);
  let offset = 0;
  let replacements = 0;
  while ((offset = buffer.indexOf(source, offset)) >= 0) {
    replacement.copy(buffer, offset);
    replacements += 1;
    offset += replacement.length;
  }
  assert.ok(replacements >= 2);
}

async function fileExists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}
