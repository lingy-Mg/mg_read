/**
 * Runtime-private development generation staging.
 *
 * A unique filesystem root gives Node a fresh ESM/CJS identity after a
 * successful project build. It copies only runtime inputs and links the
 * existing dependency tree; it never creates a distributable artifact.
 */
import { randomUUID } from "node:crypto";
import { copyFile, cp, mkdir, rm, symlink } from "node:fs/promises";
import { resolve } from "node:path";

import { readPluginProject, type PluginPackageDescriptor } from "./plugin-package.js";
import { exists } from "./plugin-manager-files.js";

export interface StagedDevelopmentGeneration {
  readonly descriptor: PluginPackageDescriptor;
  readonly generationRoot: string;
}

/** Copies one already-built project into a unique Runtime-private root. */
export async function stageDevelopmentGeneration(
  dataRoot: string,
  projectRoot: string,
  expectedDescriptor: PluginPackageDescriptor,
): Promise<StagedDevelopmentGeneration> {
  const generationRoot = resolve(
    dataRoot,
    "development-generations",
    expectedDescriptor.id,
    randomUUID(),
  );
  await mkdir(generationRoot, { recursive: true });
  try {
    await copyFile(resolve(projectRoot, "package.json"), resolve(generationRoot, "package.json"));
    if (await exists(resolve(projectRoot, "package-lock.json"))) {
      await copyFile(
        resolve(projectRoot, "package-lock.json"),
        resolve(generationRoot, "package-lock.json"),
      );
    }
    for (const directory of ["dist", "assets", "packages"]) {
      const source = resolve(projectRoot, directory);
      if (await exists(source)) {
        await cp(source, resolve(generationRoot, directory), { recursive: true });
      }
    }
    const nodeModules = resolve(projectRoot, "node_modules");
    if (await exists(nodeModules)) {
      await symlink(
        nodeModules,
        resolve(generationRoot, "node_modules"),
        process.platform === "win32" ? "junction" : "dir",
      );
    }
    const staged = await readPluginProject(generationRoot);
    if (
      staged.descriptor.id !== expectedDescriptor.id ||
      staged.descriptor.version !== expectedDescriptor.version
    ) {
      throw new Error("Development generation descriptor changed while staging.");
    }
    return Object.freeze({
      descriptor: staged.descriptor,
      generationRoot,
    });
  } catch (error) {
    await rm(generationRoot, { force: true, recursive: true }).catch(() => {});
    throw error;
  }
}
