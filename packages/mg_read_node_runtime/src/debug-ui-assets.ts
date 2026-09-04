/**
 * Runtime Debug inspector static asset loader.
 *
 * Responsibilities:
 * - read the three build-copied browser assets from the Runtime distribution;
 * - expose only a fixed asset-name allowlist to the Debug HTTP router.
 *
 * Boundaries:
 * - never resolves request-controlled filesystem paths;
 * - keeps browser markup, styles and Web Components in their native file formats.
 */
import { readFile } from "node:fs/promises";

export type DebugInspectorAsset = "app.css" | "app.js" | "index.html";

const assetUrls: Readonly<Record<DebugInspectorAsset, URL>> = Object.freeze({
  "app.css": new URL("./debug-ui/app.css", import.meta.url),
  "app.js": new URL("./debug-ui/app.js", import.meta.url),
  "index.html": new URL("./debug-ui/index.html", import.meta.url),
});

/** Reads one known Debug UI asset from the compiled Runtime distribution. */
export function readDebugInspectorAsset(asset: DebugInspectorAsset): Promise<string> {
  return readFile(assetUrls[asset], "utf8");
}
