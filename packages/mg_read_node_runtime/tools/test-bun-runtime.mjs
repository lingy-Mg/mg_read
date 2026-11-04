/** Runs the shared desktop behavioral suite on the pinned Bun executable.
 * Android/Javet and Node-toolchain metadata have their own Node checks. No
 * production behavior tests are dropped when adding a new desktop test file.
 */
import { spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bunVersion, stageBunRuntime } from "./stage-bun-runtime.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
if (!["win32", "darwin"].includes(process.platform)) throw new Error("Bun desktop verification requires Windows or macOS.");
const platform = process.platform === "win32" ? "windows-x64" : "macos-arm64";
await stageBunRuntime(platform, resolve(root, `../mgread_plugin_runtime/assets/runtime/${platform}/node`));
const executable = resolve(root, `tools/bun-v${bunVersion}-${platform}`, process.platform === "win32" ? "bun.exe" : "bun");
const tests = (await readdir(resolve(root, "test"))).filter(name => name.endsWith(".test.mjs") &&
  !/^(?:android-|runtime-version\.|windows-runtime-staging\.|macos-runtime-staging\.|bilibili-audio-contract\.)/.test(name));
const child = spawn(executable, ["test", "--timeout", "30000", ...tests.map(name => `test/${name}`)], {
  cwd: root, stdio: "inherit", windowsHide: true,
});
child.on("error", error => { console.error(error); process.exitCode = 1; });
child.on("exit", code => { process.exitCode = code ?? 1; });
