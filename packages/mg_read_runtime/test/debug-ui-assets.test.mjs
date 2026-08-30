/**
 * Runtime Debug inspector static asset contract tests.
 *
 * Responsibilities:
 * - prove the build copies native HTML, CSS and JavaScript files into dist;
 * - parse the browser script and retain the expected Web Components shell.
 * - verify log category visibility round-trips through browser-local storage.
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
  assert.match(css, /--log-toolbar-control-height: 34px/);
  assert.match(css, /\.log-status \{/);
  assert.doesNotThrow(() => new vm.Script(script, { filename: "debug-inspector-app.js" }));
  assert.match(script, /customElements\.define\('mg-debug-app'/);
  assert.match(script, /customElements\.define\('mg-search-panel'/);
  assert.match(script, /customElements\.define\('mg-discovery-panel'/);
  assert.match(script, /customElements\.define\('mg-log-viewer'/);
  assert.match(script, /runtime\.plugin\.resource_proxy/);
  assert.match(script, /log-category-filters/);
  assert.match(script, /role="group" aria-label="显示类别"/);
  assert.match(script, /heading-actions log-status/);
  assert.match(script, /defaultVisibleLogEntryLimit = 10/);
  assert.match(script, /entries\.slice\(-defaultVisibleLogEntryLimit\)/);
  assert.match(script, /dataset\.action = 'show-all'/);
  assert.match(script, /latestSequence/);
  assert.match(script, /workspaceRoutes/);
  assert.match(script, /window\.history\.pushState/);
  assert.match(script, /data-action="copy"/);
  assert.match(script, /navigator\.clipboard\?\.writeText/);
  assert.match(script, /document\.execCommand\('copy'\)/);
});

test("Debug inspector persists hidden log categories across viewer instances", async () => {
  const script = await readDebugInspectorAsset("app.js");
  const elements = new Map();
  const values = new Map([
    ["mgread.debug.logs.hiddenCategories.v1", JSON.stringify(["plugin.http", "unknown.category"])],
  ]);
  const context = {
    HTMLElement: class {},
    customElements: {
      define(name, constructor) { elements.set(name, constructor); },
    },
    window: {
      localStorage: {
        getItem(key) { return values.get(key) ?? null; },
        setItem(key, value) { values.set(key, value); },
      },
    },
  };
  vm.runInNewContext(script, context, { filename: "debug-inspector-app.js" });

  const LogViewer = elements.get("mg-log-viewer");
  const viewer = new LogViewer();
  viewer.categories = [
    { checked: true, value: "runtime.diagnostic" },
    { checked: true, value: "plugin.http" },
    { checked: true, value: "plugin.webview" },
  ];
  viewer.restoreCategoryVisibility();
  assert.deepEqual(viewer.categories.map((category) => category.checked), [true, false, true]);

  viewer.categories[0].checked = false;
  viewer.categories[1].checked = true;
  viewer.categories[2].checked = false;
  viewer.persistCategoryVisibility();
  assert.equal(
    values.get("mgread.debug.logs.hiddenCategories.v1"),
    JSON.stringify(["runtime.diagnostic", "plugin.webview"]),
  );

  const refreshedViewer = new LogViewer();
  refreshedViewer.categories = viewer.categories.map((category) => ({ ...category, checked: true }));
  refreshedViewer.restoreCategoryVisibility();
  assert.deepEqual(refreshedViewer.categories.map((category) => category.checked), [false, true, false]);
});
