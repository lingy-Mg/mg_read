/**
 * Runtime Debug inspector static asset contract tests.
 *
 * Responsibilities:
 * - prove the build copies native HTML, CSS and JavaScript files into dist;
 * - parse the browser script and retain the expected Web Components shell.
 *
 * Boundaries:
 * - does not bind the fixed LAN Debug port or start a Runtime;
 * - does not execute browser code outside a browser DOM.
 */
import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";

import { readDebugInspectorAsset } from "../dist/debug-ui-assets.js";

test("Debug inspector ships native static assets with a Web Components entrypoint", async () => {
  const [html, css, script] = await Promise.all([
    readDebugInspectorAsset("index.html"),
    readDebugInspectorAsset("app.css"),
    readDebugInspectorAsset("app.js"),
  ]);

  assert.match(html, /<mg-debug-app/);
  assert.match(html, /__debug\/app\.css/);
  assert.match(html, /__debug\/app\.js/);
  assert.doesNotMatch(html, /customElements\.define/);
  assert.match(css, /mg-debug-app, mg-runtime-status/);
  assert.match(css, /\.workspace-panel/);
  assert.doesNotThrow(() => new vm.Script(script, { filename: "debug-inspector-app.js" }));
  assert.match(script, /customElements\.define\('mg-debug-app'/);
  assert.match(script, /customElements\.define\('mg-search-panel'/);
  assert.match(script, /customElements\.define\('mg-discovery-panel'/);
  assert.match(script, /customElements\.define\('mg-log-viewer'/);
  assert.match(script, /data-action="copy"/);
  assert.match(script, /navigator\.clipboard\?\.writeText/);
  assert.match(script, /document\.execCommand\('copy'\)/);
});
