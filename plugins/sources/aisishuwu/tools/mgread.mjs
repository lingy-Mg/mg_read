#!/usr/bin/env node

/**
 * MgRead 插件确定性发布工具。
 *
 * 职责：
 * - 默认生成带规范信封的单文件 Node 24 ESM artifact。
 * - 为显式 archive 模式保留确定性 ZIP 兼容分支。
 * - 向 development sync 提供不写工作区的内存构建函数。
 *
 * 注意：
 * - esbuild 只在开发机运行，每次构建后必须停止 helper。
 * - single-file 只允许纯 JavaScript/JSON 和 Node builtin；图标是唯一声明式资源。
 */

import { createHash } from 'node:crypto';
import { lstat, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { builtinModules, createRequire } from 'node:module';
import { dirname, extname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const HEADER_PREFIX = '// @mgread-plugin-v1 ';
const HEADER_LIMIT = 512 * 1024;
const ICON_LIMIT = 256 * 1024;
const ARTIFACT_LIMIT = 32 * 1024 * 1024;
const BUNDLE_EXTENSIONS = new Set(['.js', '.mjs', '.cjs', '.json']);
const NODE_BUILTINS = new Set(
  builtinModules.flatMap((name) => [name, name.startsWith('node:') ? name.slice(5) : `node:${name}`]),
);
const crcTable = createCrcTable();

if (isMainModule()) {
  if (process.argv[2] !== 'pack' || process.argv.length !== 3) throw new Error('Usage: mgread pack');
  const artifact = await buildPluginArtifact();
  const artifactsRoot = resolve(projectRoot, 'artifacts');
  const target = resolve(artifactsRoot, artifact.fileName);
  assertInside(artifactsRoot, target);
  await mkdir(artifactsRoot, { recursive: true });
  await rm(target, { force: true });
  await writeFile(target, artifact.bytes, { mode: 0o444 });
  process.stdout.write(`${relative(projectRoot, target).replaceAll('\\', '/')}\n`);
}

/** Builds this project without writing either the workspace or an output path. */
export async function buildPluginArtifact({ versionOverride } = {}) {
  return buildPluginArtifactForProject(projectRoot, { versionOverride, toolingRoot: projectRoot });
}

/** Project-root variant used by deterministic offline contract tests. */
export async function buildPluginArtifactForProject(root, { versionOverride, toolingRoot = projectRoot } = {}) {
  const originalPackage = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
  const packageMode = originalPackage?.mgread?.packageMode ?? 'single-file';
  validatePackage(originalPackage, packageMode, versionOverride);
  const packageJson = structuredClone(originalPackage);
  if (versionOverride !== undefined) packageJson.version = versionOverride;

  if (packageMode === 'archive') {
    const bytes = await buildArchive(root, packageJson, versionOverride);
    assertArtifactSize(bytes);
    return {
      bytes,
      fileName: `${packageJson.mgread.id}-${packageJson.version}.mgplugin`,
      format: 'archive',
    };
  }

  const bytes = await buildSingleFile(root, packageJson, toolingRoot);
  assertArtifactSize(bytes);
  return {
    bytes,
    fileName: `${packageJson.mgread.id}-${packageJson.version}.mgplugin.js`,
    format: 'singleFile',
  };
}

async function buildSingleFile(root, packageJson, toolingRoot) {
  await validateSingleFileAssets(root, packageJson.mgread.icon);
  const { build, stop } = createRequire(resolve(toolingRoot, 'package.json'))('esbuild');
  let result;
  try {
    result = await build({
      absWorkingDir: root,
      entryPoints: [packageJson.main],
      bundle: true,
      charset: 'utf8',
      conditions: ['node', 'import', 'default'],
      external: [...NODE_BUILTINS],
      format: 'esm',
      legalComments: 'none',
      logLevel: 'silent',
      mainFields: ['module', 'main'],
      metafile: true,
      minify: false,
      platform: 'node',
      sourcemap: false,
      target: 'node24',
      treeShaking: true,
      write: false,
    });
  } catch (error) {
    throw new Error(`Single-file bundle failed: ${formatBuildError(error)}`);
  } finally {
    await stop();
  }
  if (result.warnings.length !== 0) {
    throw new Error(`Single-file bundle warnings are not allowed: ${result.warnings[0].text}`);
  }
  if (result.outputFiles.length !== 1) {
    throw new Error('Single-file mode must produce exactly one JavaScript output.');
  }
  validateBundleGraph(result.metafile);
  const code = Buffer.from(result.outputFiles[0].contents);
  validateBundleCode(code);
  const descriptor = createDescriptor(packageJson);
  const envelope = {
    formatVersion: 1,
    descriptor,
    codeBytes: code.length,
    codeSha256: sha256(code),
  };
  if (descriptor.mgread.icon !== undefined) envelope.icon = await readIcon(root, descriptor.mgread.icon);
  const encoded = Buffer.from(canonicalJson(envelope)).toString('base64url');
  const header = Buffer.from(`${HEADER_PREFIX}${encoded}\n`);
  if (header.length > HEADER_LIMIT) throw new Error(`Single-file header exceeds ${HEADER_LIMIT} bytes.`);
  return Buffer.concat([header, code]);
}

function validateBundleGraph(metafile) {
  for (const input of Object.keys(metafile.inputs)) {
    if (!BUNDLE_EXTENSIONS.has(extname(input).toLowerCase())) {
      throw new Error(`Unsupported bundled resource: ${input}`);
    }
  }
  for (const output of Object.values(metafile.outputs)) {
    for (const dependency of output.imports) {
      if (!dependency.external || !NODE_BUILTINS.has(dependency.path)) {
        throw new Error(`Only Node builtin externals are allowed: ${dependency.path}`);
      }
    }
  }
}

function validateBundleCode(code) {
  const source = code.toString('utf8');
  const executable = source.replace(/\/\*[\s\S]*?\*\//gu, '').replace(/^\s*\/\/.*$/gmu, '');
  if (/\bimport\s*\(/u.test(executable)) {
    throw new Error('Dynamic import is not supported by single-file artifacts.');
  }
  if (/import\.meta\.url/u.test(source)) {
    throw new Error('Single-file artifacts cannot reference sidecar files through import.meta.url.');
  }
  if (/sourceMappingURL=/u.test(source)) throw new Error('Single-file artifacts cannot contain source maps.');
}

async function validateSingleFileAssets(root, iconPath) {
  const assetsRoot = resolve(root, 'assets');
  let entries;
  try {
    entries = await collectRegularPaths(assetsRoot);
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  const allowedIcon = iconPath === undefined ? undefined : normalizeRelative(iconPath);
  const unsupported = entries.find((entry) => normalizeRelative(relative(root, entry)) !== allowedIcon);
  if (unsupported !== undefined) {
    throw new Error(
      `Single-file mode does not publish sidecar resources: ${normalizeRelative(relative(root, unsupported))}`,
    );
  }
}

async function collectRegularPaths(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const absolute = resolve(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Plugin artifacts cannot contain symbolic links.');
    if (entry.isDirectory()) files.push(...(await collectRegularPaths(absolute)));
    else if (entry.isFile()) files.push(absolute);
    else throw new Error('Plugin artifacts can contain regular files only.');
  }
  return files;
}

async function readIcon(root, iconPath) {
  const normalized = normalizeRelative(iconPath);
  if (!normalized.startsWith('assets/') || extname(normalized).toLowerCase() !== '.png') {
    throw new Error('mgread.icon must name a PNG below assets/.');
  }
  const absolute = resolve(root, ...normalized.split('/'));
  assertInside(root, absolute);
  const details = await lstat(absolute);
  if (!details.isFile() || details.isSymbolicLink()) throw new Error('mgread.icon must name a regular file.');
  const bytes = await readFile(absolute);
  if (bytes.length > ICON_LIMIT) throw new Error(`Plugin icon exceeds ${ICON_LIMIT} bytes.`);
  if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error('mgread.icon is not a valid PNG file.');
  }
  return { mediaType: 'image/png', bytes: bytes.length, sha256: sha256(bytes), data: bytes.toString('base64') };
}

function createDescriptor(packageJson) {
  return {
    name: packageJson.name,
    version: packageJson.version,
    type: 'module',
    main: 'dist/index.mjs',
    engines: { node: packageJson.engines.node },
    mgread: {
      schemaVersion: packageJson.mgread.schemaVersion,
      id: packageJson.mgread.id,
      displayName: packageJson.mgread.displayName,
      ...(packageJson.mgread.description === undefined ? {} : { description: packageJson.mgread.description }),
      pluginApi: packageJson.mgread.pluginApi,
      contentKinds: [...packageJson.mgread.contentKinds],
      packageMode: 'single-file',
      ...(packageJson.mgread.icon === undefined ? {} : { icon: packageJson.mgread.icon }),
    },
  };
}

async function buildArchive(root, packageJson, versionOverride) {
  const files = [];
  for (const name of ['package.json', 'package-lock.json', 'README.md', 'LICENSE']) {
    let bytes = await readFile(resolve(root, name));
    if (name === 'package.json' && versionOverride !== undefined) {
      bytes = Buffer.from(`${JSON.stringify(packageJson, null, 2)}\n`);
    }
    if (name === 'package-lock.json' && versionOverride !== undefined) {
      const lock = JSON.parse(bytes.toString('utf8'));
      lock.version = versionOverride;
      if (lock.packages?.[''] !== undefined) lock.packages[''].version = versionOverride;
      bytes = Buffer.from(`${JSON.stringify(lock, null, 2)}\n`);
    }
    files.push({ path: name, bytes });
  }
  for (const directory of ['dist', 'assets', 'packages', 'tools']) {
    await collectArchiveDirectory(root, directory, files);
  }
  files.sort((left, right) => left.path.localeCompare(right.path));
  return createZip(files);
}

async function collectArchiveDirectory(root, directory, files) {
  const absolute = resolve(root, directory);
  assertInside(root, absolute);
  let entries;
  try {
    entries = await readdir(absolute, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  for (const entry of entries) {
    const child = `${directory}/${entry.name}`;
    const childAbsolute = resolve(root, ...child.split('/'));
    assertInside(root, childAbsolute);
    if (entry.isSymbolicLink() || entry.name === 'node_modules') {
      throw new Error('Plugin archives cannot contain links or node_modules.');
    }
    if (entry.isDirectory()) await collectArchiveDirectory(root, child, files);
    else if (entry.isFile()) files.push({ path: child, bytes: await readFile(childAbsolute) });
    else throw new Error('Plugin archives can contain regular files only.');
  }
}

function validatePackage(value, mode, versionOverride) {
  const version = versionOverride ?? value?.version;
  if (
    typeof value?.name !== 'string' || value.name.trim().length === 0 ||
    typeof version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version) ||
    value?.type !== 'module' || value?.main !== 'dist/index.mjs' || value?.engines?.node !== '>=24 <25' ||
    value?.mgread?.schemaVersion !== 1 || value?.mgread?.pluginApi !== 1 ||
    typeof value?.mgread?.id !== 'string' || !/^[a-z0-9]+(?:[.-][a-z0-9]+)+$/u.test(value.mgread.id) ||
    typeof value?.mgread?.displayName !== 'string' || value.mgread.displayName.trim().length === 0 ||
    (value.mgread.description !== undefined &&
      (typeof value.mgread.description !== 'string' || value.mgread.description.trim().length === 0)) ||
    !Array.isArray(value?.mgread?.contentKinds) || value.mgread.contentKinds.length === 0 ||
    value.mgread.contentKinds.some(
      (kind) => !['novel', 'manga', 'audio', 'video'].includes(kind),
    ) ||
    (value.mgread.icon !== undefined && typeof value.mgread.icon !== 'string') ||
    !['single-file', 'archive'].includes(mode) || value.manifest !== undefined ||
    value.sharedDependencies !== undefined || value.bundledDependencies !== undefined
  ) {
    throw new Error('package.json is not a supported MgRead standard plugin project.');
  }
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function createZip(files) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const file of files) {
    const name = Buffer.from(file.path, 'utf8');
    const compressed = deflateRawSync(file.bytes, { level: 9 });
    const checksum = crc32(file.bytes);
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0x0800, 6);
    localHeader.writeUInt16LE(8, 8);
    localHeader.writeUInt16LE(33, 12);
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(file.bytes.length, 22);
    localHeader.writeUInt16LE(name.length, 26);
    local.push(localHeader, name, compressed);
    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(0x0314, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0x0800, 8);
    centralHeader.writeUInt16LE(8, 10);
    centralHeader.writeUInt16LE(33, 14);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(compressed.length, 20);
    centralHeader.writeUInt32LE(file.bytes.length, 24);
    centralHeader.writeUInt16LE(name.length, 28);
    centralHeader.writeUInt32LE((0o100444 << 16) >>> 0, 38);
    centralHeader.writeUInt32LE(offset, 42);
    central.push(centralHeader, name);
    offset += localHeader.length + name.length + compressed.length;
  }
  const centralBytes = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, centralBytes, end]);
}

function createCrcTable() {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    table[index] = value >>> 0;
  }
  return table;
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function sha256(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
function assertArtifactSize(bytes) {
  if (bytes.length > ARTIFACT_LIMIT) throw new Error(`Plugin artifact exceeds ${ARTIFACT_LIMIT} bytes.`);
}
function assertInside(root, candidate) {
  const fromRoot = relative(root, candidate);
  if (fromRoot === '' || fromRoot.startsWith('..') || fromRoot.includes(':')) {
    throw new Error('Refusing a path outside the plugin project.');
  }
}
function normalizeRelative(value) {
  const normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/') || normalized.includes('\0') || normalized.split('/').includes('..')) {
    throw new Error('Plugin paths must stay within the project.');
  }
  return normalized;
}
function formatBuildError(error) {
  if (Array.isArray(error?.errors) && error.errors[0]?.text !== undefined) return error.errors[0].text;
  return error instanceof Error ? error.message : String(error);
}
function isMainModule() {
  return process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}
