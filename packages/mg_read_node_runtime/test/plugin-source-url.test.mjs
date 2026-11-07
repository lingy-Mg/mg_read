// Validates shipped source metadata without requiring source build artifacts.
import assert from "node:assert/strict";
import { access, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import { normalizePluginSourceUrl, parsePluginPackageDescriptor } from "../dist/plugin-package.js";

async function readSourceDescriptor(projectRoot) {
  const packageJson = JSON.parse(await readFile(join(projectRoot, "package.json"), "utf8"));
  return parsePluginPackageDescriptor(packageJson, projectRoot);
}

test("every shipped Node source declares one valid canonical homepage", async () => {
  const sourceRoot = resolve(import.meta.dirname, "../../../plugins/sources");
  const directories = (await Promise.all((await readdir(sourceRoot, { withFileTypes: true })).map(async (entry) => {
    if (!entry.isDirectory()) return undefined;
    try {
      await access(join(sourceRoot, entry.name, "package.json"));
      return entry;
    } catch {
      return undefined;
    }
  }))).filter(Boolean);
  const descriptors = await Promise.all(directories.map((entry) => readSourceDescriptor(join(sourceRoot, entry.name))));
  assert.ok(descriptors.length > 0, "the shipped source set must not be empty");
  assert.ok(descriptors.every((descriptor) => descriptor.sourceUrl !== undefined));
  assert.equal(new Set(descriptors.map((descriptor) => descriptor.id)).size, descriptors.length);
});

test("validates source homepage metadata before the source entry is built", async (t) => {
  const projectRoot = await mkdtemp(join(tmpdir(), "mgread-source-homepage-"));
  t.after(() => rm(projectRoot, { recursive: true, force: true }));
  const packageJson = {
    name: "homepage-test-source",
    version: "1.0.0",
    type: "module",
    main: "dist/index.js",
    mgread: {
      schemaVersion: 1,
      pluginApi: 1,
      id: "test.homepage",
      displayName: "Homepage test source",
      sourceUrl: " HTTPS://Example.COM:443/path/// ",
      contentKinds: ["novel"],
    },
  };
  const packagePath = join(projectRoot, "package.json");
  await writeFile(packagePath, JSON.stringify(packageJson));
  await assert.rejects(access(join(projectRoot, "dist")), { code: "ENOENT" });
  const descriptor = await readSourceDescriptor(projectRoot);
  assert.equal(descriptor.id, "test.homepage");
  assert.equal(descriptor.sourceUrl, "https://example.com/path");

  packageJson.mgread.sourceUrl = "javascript:alert(1)";
  await writeFile(packagePath, JSON.stringify(packageJson));
  await assert.rejects(readSourceDescriptor(projectRoot), { code: "plugin_package_invalid" });
});

test("normalizes safe source homepage URLs and rejects unsafe or ambiguous URLs", () => {
  assert.equal(normalizePluginSourceUrl(" HTTPS://Example.COM:443/path/// "), "https://example.com/path");
  for (const value of [undefined, "", "javascript:alert(1)", "file:///tmp/source", "https://user@source.example/", "https://source.example/?next=x", "https://source.example/#fragment", "http://localhost/"]) {
    assert.equal(normalizePluginSourceUrl(value), undefined, String(value));
  }
});
