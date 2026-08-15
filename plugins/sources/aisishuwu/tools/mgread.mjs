#!/usr/bin/env node

import { deflateRawSync } from 'node:zlib';
import { lstat, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const artifactsRoot = resolve(projectRoot, 'artifacts');
const crcTable = createCrcTable();
const command = process.argv[2];
if (command !== 'pack' || process.argv.length !== 3) {
  throw new Error('Usage: mgread pack');
}

const packageJson = JSON.parse(await readFile(resolve(projectRoot, 'package.json'), 'utf8'));
validatePackage(packageJson);
const archive = createZip(await collectFiles());
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
    value.mgread.contentKinds.some((kind) => kind !== 'novel' && kind !== 'manga') ||
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
    await collectDirectory(directory, files);
  }
  files.sort((left, right) => left.path.localeCompare(right.path));
  return files;
}

async function collectDirectory(directory, files) {
  const absolute = resolve(projectRoot, directory);
  assertInside(projectRoot, absolute);
  let entries;
  try {
    entries = await readdir(absolute, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT' && directory === 'packages') return;
    throw error;
  }
  for (const entry of entries) {
    const child = `${directory}/${entry.name}`;
    const childAbsolute = resolve(projectRoot, ...child.split('/'));
    assertInside(projectRoot, childAbsolute);
    if (entry.isSymbolicLink() || entry.name === 'node_modules') {
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
  const locals = [];
  const central = [];
  let offset = 0;
  for (const file of files) {
    const name = Buffer.from(file.path, 'utf8');
    const compressed = deflateRawSync(file.bytes, { level: 9 });
    const checksum = crc32(file.bytes);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(33, 12);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(file.bytes.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, name, compressed);

    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE(0x0314, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0x0800, 8);
    header.writeUInt16LE(8, 10);
    header.writeUInt16LE(0, 12);
    header.writeUInt16LE(33, 14);
    header.writeUInt32LE(checksum, 16);
    header.writeUInt32LE(compressed.length, 20);
    header.writeUInt32LE(file.bytes.length, 24);
    header.writeUInt16LE(name.length, 28);
    header.writeUInt16LE(0, 30);
    header.writeUInt16LE(0, 32);
    header.writeUInt16LE(0, 34);
    header.writeUInt16LE(0, 36);
    header.writeUInt32LE((0o100444 << 16) >>> 0, 38);
    header.writeUInt32LE(offset, 42);
    central.push(header, name);
    offset += local.length + name.length + compressed.length;
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
  return Buffer.concat([...locals, centralBytes, end]);
}

function createCrcTable() {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function assertInside(root, candidate) {
  const fromRoot = relative(root, candidate);
  if (fromRoot === '' || fromRoot.startsWith('..') || fromRoot.includes(':')) {
    throw new Error('Refusing a path outside the plugin project.');
  }
}
