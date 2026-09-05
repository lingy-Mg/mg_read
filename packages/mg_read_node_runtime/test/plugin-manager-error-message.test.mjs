import assert from "node:assert/strict";
import test from "node:test";

import { pluginManagerErrorMessage } from "../dist/plugin-manager-error-message.js";

test("plugin error messages append available detail", () => {
  const detail = "Response validation failed at the inline payload budget: 64000 bytes exceeds the 57344-byte limit.";
  assert.equal(
    pluginManagerErrorMessage("plugin_invalid_response", detail),
    `The plugin returned an invalid response. ${detail}`,
  );
  assert.equal(
    pluginManagerErrorMessage("plugin_execution_failed", detail),
    `The plugin could not complete the requested operation. ${detail}`,
  );
});

test("source access block uses the source-authored original and annotation", () => {
  assert.equal(
    pluginManagerErrorMessage(
      "source_access_blocked",
      "访问异常，请稍后再试。\n注释：当前 IP 可能异常，请更换 IP 后重试。",
    ),
    "访问异常，请稍后再试。\n注释：当前 IP 可能异常，请更换 IP 后重试。",
  );
});
