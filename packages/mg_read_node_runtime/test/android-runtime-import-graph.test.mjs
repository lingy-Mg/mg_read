/** Javet instantiates the static Core graph; desktop Node alone does not catch cycles. */
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import ts from "typescript";

test("Android Core startup has no static relative-module import cycle", async () => {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "../dist");
  const visited = new Set();
  const stack = [];
  async function visit(path) {
    const cycle = stack.indexOf(path);
    assert.equal(cycle, -1, `Javet startup cycle: ${[...stack.slice(cycle), path].map((value) => value.slice(root.length + 1)).join(" -> ")}`);
    if (visited.has(path)) return;
    stack.push(path);
    const source = ts.createSourceFile(path, await readFile(path, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    for (const node of source.statements) {
      if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
          node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier) && node.moduleSpecifier.text.startsWith(".")) {
        await visit(resolve(dirname(path), node.moduleSpecifier.text));
      }
    }
    stack.pop();
    visited.add(path);
  }
  await visit(resolve(root, "desktop-runtime.js"));
  assert.ok(visited.size > 30, "Check the real Core startup graph, not an isolated leaf fixture.");
});
