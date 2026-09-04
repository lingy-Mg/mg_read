// @ts-check

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

/** Minimal package.json fields relevant to the no-native-addon policy. */
/**
 * @typedef {object} PackageManifest
 * @property {unknown} [binary]
 * @property {unknown} [gypfile]
 * @property {unknown} [name]
 * @property {Record<string, unknown> | null} [scripts]
 */

/** Dependency tree root produced only by `npm ci`. */
const nodeModulesDirectory = resolve("node_modules");

/**
 * Safe, relative descriptions reported only when the audit fails.
 * @type {string[]}
 */
const findings = [];

/** Known tool names that indicate a package may build or fetch a native addon. */
const nativeBuildPattern = /\b(?:node-gyp|node-pre-gyp|prebuild-install|prebuildify|cmake-js)\b/i;

/** Inspects a single package manifest without executing any lifecycle script. */
/** @param {string} manifestPath Absolute path discovered during the local walk. */
function inspectPackageManifest(manifestPath) {
  /** @type {PackageManifest} */
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const packageName = typeof manifest.name === "string" ? manifest.name : manifestPath;

  if (manifest.gypfile === true) {
    findings.push(packageName + " declares gypfile.");
  }

  if (Object.hasOwn(manifest, "binary")) {
    findings.push(packageName + " declares a binary addon configuration.");
  }

  const scripts = manifest.scripts;
  if (scripts !== null && typeof scripts === "object") {
    for (const [name, value] of Object.entries(scripts)) {
      if (typeof value === "string" && nativeBuildPattern.test(value)) {
        findings.push(packageName + " has a native-build lifecycle script: " + name + ".");
      }
    }
  }
}

/** Recursively audits only real files; symbolic links are never followed. */
/** @param {string} directory Absolute directory inside `node_modules`. */
function walk(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const entryPath = join(directory, entry.name);

    if (entry.isSymbolicLink()) {
      continue;
    }

    if (entry.isDirectory()) {
      walk(entryPath);
      continue;
    }

    if (entry.name.endsWith(".node")) {
      findings.push(entryPath + " is a native addon binary.");
    } else if (entry.name === "package.json") {
      inspectPackageManifest(entryPath);
    }
  }
}

// `npm ci` is required before auditing so an absent tree cannot look clean.
if (!existsSync(nodeModulesDirectory)) {
  throw new Error("node_modules is absent. Run npm ci before auditing dependencies.");
}

walk(nodeModulesDirectory);

if (findings.length > 0) {
  throw new Error(
    "Native addon indicators found in the npm dependency tree:\n" +
      findings.map((finding) => "- " + finding).join("\n"),
  );
}

console.log("No native addon binaries or native-build package indicators found.");
