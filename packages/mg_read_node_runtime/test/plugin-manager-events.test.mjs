import assert from "node:assert/strict";
import test from "node:test";

import { developmentPluginBuildFailureDebugLog } from "../dist/plugin-manager-events.js";

test("development build failures keep one detailed Runtime Debug log entry per source", () => {
  const log = developmentPluginBuildFailureDebugLog({
    code: "development_plugin_build_failed",
    outcome: "error",
    pluginId: "org.mgread.bilibili-collection",
    pluginName: "哔哩集合",
    buildOutput: "[stderr]\nError: Cannot find module walk-up-path\n[exit] code=7",
  });

  assert.deepEqual(log, {
    category: "runtime.diagnostic",
    code: "development_plugin_build_failed",
    level: "error",
    message: "开发数据源构建失败：哔哩集合 (org.mgread.bilibili-collection)\n[stderr]\nError: Cannot find module walk-up-path\n[exit] code=7",
    pluginId: "org.mgread.bilibili-collection",
    source: "runtime",
  });
  assert.equal(developmentPluginBuildFailureDebugLog({ code: "development_plugin_updated", outcome: "success" }), undefined);
});
