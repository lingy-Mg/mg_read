#!/usr/bin/env node

/** Delegates deterministic single-file packaging to the maintained builder. */
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPluginArtifactForProject as buildAliceArtifactForProject } from '../../aisishuwu/tools/mgread.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export function buildPluginArtifactForProject(root, options = {}) { return buildAliceArtifactForProject(root, { ...options, toolingRoot: projectRoot }); }
export function buildPluginArtifact(options = {}) { return buildPluginArtifactForProject(projectRoot, options); }
if (resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  if (process.argv[2] !== 'pack' || process.argv.length !== 3) throw new Error('Usage: mgread pack');
  const artifact = await buildPluginArtifact();
  const artifactsRoot = resolve(projectRoot, 'artifacts');
  const target = resolve(artifactsRoot, artifact.fileName);
  await mkdir(artifactsRoot, { recursive: true });
  await rm(target, { force: true });
  await writeFile(target, artifact.bytes, { mode: 0o444 });
  process.stdout.write(`${relative(projectRoot, target).replaceAll('\\', '/')}\n`);
}
