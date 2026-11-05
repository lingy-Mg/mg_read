// Verifies the ARM64 APK with the same policy as CI, then copies it to the
// stable local output. --no-reveal keeps automation from opening a file manager.
import { access, copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const workspaceRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = resolve(
  workspaceRoot,
  "build/app/outputs/flutter-apk/app-release.apk",
);
const destination = resolve(workspaceRoot, "build/mg_read-release.apk");

try {
  await access(source);
} catch {
  throw new Error(`找不到 APK：${source}`);
}

await mkdir(dirname(destination), { recursive: true });
const verification = spawnSync(process.platform === "win32" ? "python" : "python3", [
  resolve(workspaceRoot, "tools/verify_android_release.py"), "arm64", "--apk", source,
  "--report", resolve(workspaceRoot, "build/android-release/local-arm64-report.json"),
], { cwd: workspaceRoot, stdio: "inherit", windowsHide: true });
if (verification.error || verification.status !== 0) {
  throw new Error("APK 发布校验失败，未覆盖上一次可交付产物。", { cause: verification.error });
}
await copyFile(source, destination);
console.log(`APK 已复制到：${destination}`);

const revealCommand = process.platform === "darwin"
  ? { command: "open", args: ["-R", destination] }
  : process.platform === "win32"
    ? { command: "explorer.exe", args: [`/select,${destination}`] }
    : null;

if (revealCommand !== null && !process.argv.includes("--no-reveal")) {
  const reveal = spawn(revealCommand.command, revealCommand.args, {
    detached: true,
    stdio: "ignore",
  });
  reveal.unref();
}
