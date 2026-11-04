// @ts-check
/** Downloads a pinned official Bun distribution, verifies its archive, and
 * stages only the executable and license alongside the desktop Node helper.
 * Toolchain caches stay inside this package; no ambient Bun/npm is used.
 */
import { EnvHttpProxyAgent, fetch } from "undici";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { chmod, copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

export const bunVersion = "1.4.4";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const distributions = {
  "windows-x64": {
    name: "bun-windows-x64",
    executable: "bun.exe",
    integrity: "a3LNctBVO8PjePsFZfwDleF2JXYf2BfQ1u/PLRnBDLnC2Riml+4+LgJpKj4xRGhB92KweGyQI5PXaTkP9qypMQ==",
  },
  "macos-arm64": {
    name: "bun-darwin-aarch64",
    executable: "bun",
    integrity: "zW/hxwc8sJAILGwB5eTC4i48ouGXf0V4lrxmEOk3JIE6JkYVW1TZh1E2pIempqsezgW1sckTIIDudFON8bJ2Mw==",
  },
};

/** @param {keyof typeof distributions} platform @param {string} destination */
export async function stageBunRuntime(platform, destination) {
  const distribution = distributions[platform];
  if (!distribution) throw new Error("Unsupported Bun target.");
  const packages = resolve(root, "..");
  const target = relative(packages, resolve(destination));
  if (!target || target.startsWith("..") || target.includes(":")) {
    throw new Error("Bun staging destination must stay inside packages.");
  }
  const cache = resolve(root, "tools", `bun-v${bunVersion}-${platform}`);
  const archive = resolve(cache, "distribution.tgz");
  await mkdir(cache, { recursive: true });
  let bytes;
  try {
    bytes = await readFile(archive);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    const url = `https://registry.npmjs.org/@oven/${distribution.name}/-/${distribution.name}-${bunVersion}.tgz`;
    const dispatcher = new EnvHttpProxyAgent();
    try {
      const response = await fetch(url, { dispatcher, signal: AbortSignal.timeout(120_000) });
      if (!response.ok) throw new Error(`Bun distribution download failed: ${response.status}`);
      bytes = Buffer.from(await response.arrayBuffer());
    } finally {
      await dispatcher.close();
    }
  }
  if (createHash("sha512").update(bytes).digest("base64") !== distribution.integrity) {
    throw new Error("Pinned Bun archive integrity check failed.");
  }
  await writeFile(archive, bytes);
  // Only this member of the integrity-checked archive is extracted. Re-extract
  // even on cache hits so stale local executable edits cannot enter a release.
  await promisify(execFile)("tar", ["-xzf", archive, "-C", cache,
    `package/bin/${distribution.executable}`], { windowsHide: true });
  const executable = resolve(cache, distribution.executable);
  await copyFile(resolve(cache, "package/bin", distribution.executable), executable);
  await chmod(executable, 0o755);
  await mkdir(destination, { recursive: true });
  const staged = resolve(destination, platform === "windows-x64" ? "MgReadBun.exe" : "MgReadBun");
  await copyFile(executable, staged);
  await chmod(staged, 0o755);
  await copyFile(resolve(root, "tools/BUN-LICENSE.md"), resolve(destination, "BUN-LICENSE.md"));
}
