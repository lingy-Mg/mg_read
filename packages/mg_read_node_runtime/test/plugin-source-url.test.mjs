import assert from "node:assert/strict";
import { access, readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import test from "node:test";

import { normalizePluginSourceUrl, readPluginProject } from "../dist/plugin-package.js";

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
  const projects = await Promise.all(directories.map((entry) => readPluginProject(join(sourceRoot, entry.name))));
  assert.ok(projects.length > 0, "the shipped source set must not be empty");
  assert.ok(projects.every(({ descriptor }) => descriptor.sourceUrl !== undefined));
  assert.equal(new Set(projects.map(({ descriptor }) => descriptor.id)).size, projects.length);
});

test("normalizes safe source homepage URLs and rejects unsafe or ambiguous URLs", () => {
  assert.equal(normalizePluginSourceUrl(" HTTPS://Example.COM:443/path/// "), "https://example.com/path");
  for (const value of [undefined, "", "javascript:alert(1)", "file:///tmp/source", "https://user@source.example/", "https://source.example/?next=x", "https://source.example/#fragment", "http://localhost/"]) {
    assert.equal(normalizePluginSourceUrl(value), undefined, String(value));
  }
});
