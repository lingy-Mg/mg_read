// Copies native Debug inspector assets after TypeScript compilation.
import { cp, mkdir, rm } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceRoot = resolve(runtimeRoot, "src/debug-ui");
const targetRoot = resolve(runtimeRoot, "dist/debug-ui");

if (relative(runtimeRoot, sourceRoot).replaceAll("\\", "/") !== "src/debug-ui") {
  throw new Error("Debug UI source path escaped the Runtime package.");
}
if (relative(runtimeRoot, targetRoot).replaceAll("\\", "/") !== "dist/debug-ui") {
  throw new Error("Debug UI target path escaped the Runtime package.");
}

await rm(targetRoot, { force: true, recursive: true });
await mkdir(dirname(targetRoot), { recursive: true });
await cp(sourceRoot, targetRoot, { recursive: true });
