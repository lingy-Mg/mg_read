// Copies the release APK to the stable workspace output path and reveals it on
// supported developer hosts. It owns no build state and never deletes output.
import { access, copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { spawn } from "node:child_process";
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
await copyFile(source, destination);
console.log(`APK 已复制到：${destination}`);

const revealCommand = process.platform === "darwin"
  ? { command: "open", args: ["-R", destination] }
  : process.platform === "win32"
    ? { command: "explorer.exe", args: [`/select,${destination}`] }
    : null;

if (revealCommand !== null) {
  const reveal = spawn(revealCommand.command, revealCommand.args, {
    detached: true,
    stdio: "ignore",
  });
  reveal.unref();
}
