import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
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
  PluginPackageError,
  readPluginProject,
} from "../dist/index.js";
import {
  PluginContentValidationError,
  parseChaptersParams,
  validateChaptersResult,
  validateContentResult,
  validateDetailResult,
  validateDiscoverResult,
  validateSearchResult,
} from "../dist/plugin-content.js";

const fixtureRoot = fileURLToPath(
  new URL("./fixtures/standard-plugin/", import.meta.url),
);

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}
export async function createRegistryPlugin(
  root,
  id,
  name,
  integrity,
  { optional = false } = {},
) {
  await mkdir(join(root, "dist"), { recursive: true });
  const dependencyField = optional ? "optionalDependencies" : "dependencies";
  const packageJson = {
    name,
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    [dependencyField]: { "fixture-dependency": "1.0.0" },
    mgread: {
      schemaVersion: 1,
      id,
      displayName: `Fixture ${id}`,
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
        [dependencyField]: { "fixture-dependency": "1.0.0" },
      },
      "node_modules/fixture-dependency": {
        version: "1.0.0",
        resolved:
          "https://registry.npmjs.org/fixture-dependency/-/fixture-dependency-1.0.0.tgz",
        integrity,
        ...(optional ? { optional: true } : {}),
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

export async function createDelayedPlugin(root) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageJson = {
    name: "@mgread-plugin/delayed",
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: "org.example.delayed",
      displayName: "Delayed fixture",
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name: packageJson.name,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": {
        name: packageJson.name,
        version: packageJson.version,
      },
    },
  };
  await Promise.all([
    writeFile(
      join(root, "package.json"),
      `${JSON.stringify(packageJson, null, 2)}\n`,
    ),
    writeFile(
      join(root, "package-lock.json"),
      `${JSON.stringify(lock, null, 2)}\n`,
    ),
    writeFile(
      join(root, "dist", "index.mjs"),
      `export function activate() {}
export function discover() { return { kind: "document", document: { components: [] } }; }
export async function search() { await new Promise((resolve) => setTimeout(resolve, 40)); return { items: [], nextCursor: null, totalCount: 0 }; }
export function getDetail() { throw new Error("unused"); }
export function getChapters() { throw new Error("unused"); }
export function getContent() { throw new Error("unused"); }
`,
    ),
  ]);
  return root;
}

export async function createDevelopmentPlugin(root, prefix) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageJson = {
    name: "@mgread-plugin/live-source",
    version: "0.1.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: "org.example.live-source",
      displayName: "Live source",
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name: packageJson.name,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": { name: packageJson.name, version: packageJson.version },
    },
  };
  const entry = `
export function activate() {}
const summary = (query) => ({
  id: "live:" + query,
  title: ${JSON.stringify(prefix)} + "：" + query,
  contentKind: "novel",
  author: null,
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: "unknown",
  access: "unknown",
  wordCount: null,
  chapterCount: 0,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: [],
  tags: [],
  attributes: [],
});
export function discover() { return { kind: "document", document: { components: [] } }; }
export function search(request) { return { items: [summary(request.query)], nextCursor: null, totalCount: 1 }; }
export function getDetail(request) { return { ...summary(request.id), id: request.id, aliases: [], catalogUrl: null }; }
export function getChapters() { return { items: [] }; }
export function getContent(request) { return { contentKind: "novel", chapterId: request.chapterId, title: null, updatedAt: null, text: "text", pages: [] }; }
`;
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(join(root, "dist", "index.mjs"), entry),
  ]);
  return root;
}

export function makeNpmTarball(files) {
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

export function writeTarString(buffer, offset, length, value) {
  const bytes = Buffer.from(value);
  assert.ok(bytes.length <= length);
  bytes.copy(buffer, offset);
}

export function writeTarOctal(buffer, offset, length, value) {
  const text = value.toString(8).padStart(length - 1, "0") + "\0";
  buffer.write(text, offset, length, "ascii");
}

export function replaceAllAscii(buffer, from, to) {
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

export async function fileExists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}
