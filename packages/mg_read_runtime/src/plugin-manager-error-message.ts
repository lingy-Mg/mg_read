/** Maps internal plugin failures to reviewed wire text without exposing causes. */
import type { PluginManagerError } from "./plugin-manager-contract.js";

export function pluginManagerErrorMessage(code: PluginManagerError["code"]): string {
  switch (code) {
    case "cancelled": return "The plugin request was cancelled.";
    case "interaction_required": return "The source requires an interactive browser verification.";
    case "invalid_request": return "The plugin request is invalid.";
    case "overloaded": return "The browser response exceeded the Runtime limit.";
    case "plugin_disabled": return "The requested plugin is disabled.";
    case "plugin_execution_failed": return "The plugin could not complete the requested operation.";
    case "plugin_invalid_response": return "The plugin returned an invalid response.";
    case "plugin_load_failed": return "The plugin does not provide the requested capability.";
    case "plugin_not_found": return "The requested plugin is not installed or active.";
    case "source_media_resolution_failed": return "The source could not resolve an external media address.";
    case "timeout": return "The plugin request deadline has elapsed.";
    case "unsupported": return "The current platform does not provide the required browser session capability.";
  }
}
