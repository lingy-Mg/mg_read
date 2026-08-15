#!/usr/bin/env node

import { deflateRawSync } from 'node:zlib';
import {
  lstat,
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const artifactsRoot = resolve(projectRoot, 'artifacts');
const crcTable = new Uint32Array(256);
for (let index = 0; index < crcTable.length; index += 1) {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  crcTable[index] = value >>> 0;
}
const command = process.argv[2];
if (command !== 'pack' || process.argv.length !== 3) {
  throw new Error('Usage: mgread pack');
}

const packageJson = JSON.parse(
  await readFile(resolve(projectRoot, 'package.json'), 'utf8'),
);
// 打包前在源码侧拒绝旧架构字段和非 dist 入口，避免生成 Runtime 无法按标准 Node 项目安装的容器。
validatePackage(packageJson);
const files = await collectFiles();
const archive = createZip(files);
const target = resolve(
  artifactsRoot,
  `${packageJson.mgread.id}-${packageJson.version}.mgplugin`,
);
assertInside(artifactsRoot, target);
await mkdir(artifactsRoot, { recursive: true });
await rm(target, { force: true });
await writeFile(target, archive, { mode: 0o444 });
process.stdout.write(`${relative(projectRoot, target).replaceAll('\\', '/')}\n`);

function validatePackage(value) {
  if (
    value?.mgread?.schemaVersion !== 1 ||
    value?.mgread?.pluginApi !== 1 ||
    typeof value?.mgread?.id !== 'string' ||
    !/^[a-z0-9]+(?:[.-][a-z0-9]+)+$/.test(value.mgread.id) ||
    typeof value?.mgread?.displayName !== 'string' ||
    value.mgread.displayName.trim().length === 0 ||
    !Array.isArray(value?.mgread?.contentKinds) ||
    value.mgread.contentKinds.length === 0 ||
    value.mgread.contentKinds.some(
      (kind) => kind !== 'novel' && kind !== 'manga',
    ) ||
    typeof value?.version !== 'string' ||
    typeof value?.main !== 'string' ||
    !value.main.startsWith('dist/') ||
    value.manifest !== undefined ||
    value.sharedDependencies !== undefined ||
    value.bundledDependencies !== undefined
  ) {
    throw new Error('package.json is not a MgRead standard plugin project.');
  }
}

async function collectFiles() {
  const files = [];
  for (const name of ['package.json', 'package-lock.json', 'README.md', 'LICENSE']) {
    files.push({ path: name, bytes: await readFile(resolve(projectRoot, name)) });
  }
  for (const directory of ['dist', 'assets', 'packages', 'tools']) {
    // 这里的白名单既定义容器内容，也防止把开发机状态、测试数据或意外文件当作插件协议发布。
    await collectDirectory(directory, files);
  }
  files.sort((left, right) => left.path.localeCompare(right.path));
  return files;
}

async function collectDirectory(directory, files) {
  const absolute = resolve(projectRoot, directory);
  assertInside(projectRoot, absolute);
  for (const entry of await readdir(absolute, { withFileTypes: true })) {
    const child = `${directory}/${entry.name}`;
    const childAbsolute = resolve(projectRoot, ...child.split('/'));
    assertInside(projectRoot, childAbsolute);
    if (entry.isSymbolicLink() || entry.name === 'node_modules') {
      // Runtime 依据 lockfile 恢复普通 node_modules；链接会破坏 ZIP 的可移植性和路径边界。
      throw new Error('Plugin archives cannot contain links or node_modules.');
    }
    if (entry.isDirectory()) {
      await collectDirectory(child, files);
      continue;
    }
    const details = await lstat(childAbsolute);
    if (!entry.isFile() || !details.isFile()) {
      throw new Error('Plugin archives can contain regular files only.');
    }
    files.push({ path: child, bytes: await readFile(childAbsolute) });
  }
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
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(33, 12);
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(file.bytes.length, 22);
    localHeader.writeUInt16LE(name.length, 26);
    localHeader.writeUInt16LE(0, 28);
    local.push(localHeader, name, compressed);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(0x0314, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0x0800, 8);
    centralHeader.writeUInt16LE(8, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(33, 14);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(compressed.length, 20);
    centralHeader.writeUInt32LE(file.bytes.length, 24);
    centralHeader.writeUInt16LE(name.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE((0o100444 << 16) >>> 0, 38);
    centralHeader.writeUInt32LE(offset, 42);
    central.push(centralHeader, name);
    offset += localHeader.length + name.length + compressed.length;
  }
  const centralBytes = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...local, centralBytes, end]);
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function assertInside(root, candidate) {
  // pack 只处理项目内的显式路径，不能因配置或链接把宿主机任意文件写入 .mgplugin。
  const fromRoot = relative(root, candidate);
  if (fromRoot === '' || fromRoot.startsWith('..') || fromRoot.includes(':')) {
    throw new Error('Refusing a path outside the plugin project.');
  }
}
