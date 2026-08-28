#!/usr/bin/env node
/** Project-local adapter for the reviewed repository artifact builder. */
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPluginArtifactForProject } from '../../../../templates/mg_read_plugin_template/tools/mgread.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function buildPluginArtifact(options = {}) {
  return buildPluginArtifactForProject(projectRoot, options);
}

if (resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  if (process.argv[2] !== 'pack' || process.argv.length !== 3) throw new Error('Usage: mgread pack');
  const artifact = await buildPluginArtifact();
  const root = resolve(projectRoot, 'artifacts');
  const target = resolve(root, artifact.fileName);
  await mkdir(root, { recursive: true });
  await rm(target, { force: true });
  await writeFile(target, artifact.bytes, { mode: 0o444 });
  process.stdout.write(`${relative(projectRoot, target).replaceAll('\\', '/')}\n`);
}
