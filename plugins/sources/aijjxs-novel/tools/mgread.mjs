#!/usr/bin/env node

/**
 * 数据源构建与发布入口。
 * build 使用本项目的开发工具，将 npm 依赖内联后原子写入单个 JS 入口。
 * pack 只封装已构建入口；被 Runtime 导入时不构建、不写工作区，也不退出进程。
 */
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildBundledEntryForProject,
  buildPluginArtifactForProject as buildAliceArtifactForProject,
} from '../../aisishuwu/tools/mgread.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function buildPluginArtifactForProject(root, options = {}) {
  return buildAliceArtifactForProject(root, options);
}

export function buildPluginArtifact(options = {}) {
  return buildPluginArtifactForProject(projectRoot, options);
}

if (resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === 'build' && process.argv.length === 3) {
    await buildBundledEntryForProject(projectRoot, projectRoot);
    process.stdout.write('Bundled source entry.\n');
  } else if (process.argv[2] === 'pack' && process.argv.length === 3) {
    const artifact = await buildPluginArtifact();
    const artifactsRoot = resolve(projectRoot, 'artifacts');
    const target = resolve(artifactsRoot, artifact.fileName);
    await mkdir(artifactsRoot, { recursive: true });
    await rm(target, { force: true });
    await writeFile(target, artifact.bytes, { mode: 0o444 });
    process.stdout.write(`${relative(projectRoot, target).replaceAll('\\', '/')}\n`);
  } else {
    throw new Error('Usage: mgread build|pack');
  }
}
