#!/usr/bin/env node
/** 单来源构建与确定性发布入口；复用仓库构建器，Runtime 导入时只读已打包 JS。 */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundledEntryForProject, buildPluginArtifactForProject } from '../../aisishuwu/tools/mgread.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export { buildPluginArtifactForProject };
export function buildPluginArtifact(options = {}) { return buildPluginArtifactForProject(projectRoot, options); }

if (resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === 'build' && process.argv.length === 3) {
    await buildBundledEntryForProject(projectRoot);
    const entry = resolve(projectRoot, 'dist/index.mjs');
    const license = await readFile(resolve(projectRoot, 'LICENSE.upstream'), 'utf8');
    const code = await readFile(entry);
    await writeFile(entry, Buffer.concat([Buffer.from(`/* zhi35/iptv icon attribution:\n${license}*/\n`), code]));
    process.stdout.write('Bundled source entry.\n');
  } else if (process.argv[2] === 'pack' && process.argv.length === 3) {
    const artifact = await buildPluginArtifact();
    await mkdir(resolve(projectRoot, 'artifacts'), { recursive: true });
    await writeFile(resolve(projectRoot, 'artifacts', artifact.fileName), artifact.bytes);
    process.stdout.write(`artifacts/${artifact.fileName}\n`);
  } else throw new Error('Usage: mgread build|pack');
}
