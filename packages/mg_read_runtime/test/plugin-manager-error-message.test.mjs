import assert from "node:assert/strict";
import test from "node:test";

import { pluginManagerErrorMessage } from "../dist/plugin-manager-error-message.js";

test("invalid plugin response appends only Runtime-authored safe validation detail", () => {
  const detail = "Response validation failed at the inline payload budget: 64000 bytes exceeds the 57344-byte limit.";
  assert.equal(
    pluginManagerErrorMessage("plugin_invalid_response", detail),
    `The plugin returned an invalid response. ${detail}`,
  );
  assert.equal(
    pluginManagerErrorMessage("plugin_execution_failed", detail),
    "The plugin could not complete the requested operation.",
  );
});
