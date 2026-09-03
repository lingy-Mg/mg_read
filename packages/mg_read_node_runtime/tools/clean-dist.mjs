import { rm } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const distRoot = resolve(repositoryRoot, "dist");
const pathFromRepository = relative(repositoryRoot, distRoot);

if (pathFromRepository !== "dist") {
  throw new Error("Refusing to clean a path outside the Runtime repository.");
}

await rm(distRoot, { force: true, recursive: true });
