import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
if (process.argv[2] !== 'pack') throw new Error('Usage: node tools/pack.mjs pack');
const manifest = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
const files = [];
for (const name of ['package.json', 'package-lock.json', 'README.md', 'LICENSE']) {
  files.push({ name, bytes: await readFile(resolve(root, name)) });
}
await collect('dist');
await collect('tools');
files.sort((left, right) => left.name.localeCompare(right.name));
const archive = zip(files);
const target = resolve(root, 'artifacts', `${manifest.mgread.id}-${manifest.version}.mgplugin`);
await mkdir(dirname(target), { recursive: true });
await rm(target, { force: true });
await writeFile(target, archive, { mode: 0o444 });
process.stdout.write(`${relative(root, target).replaceAll('\\', '/')}\n`);

async function collect(directory) {
  const absolute = resolve(root, directory);
  for (const entry of await readdir(absolute, { withFileTypes: true })) {
    const name = `${directory}/${entry.name}`;
    if (entry.isDirectory()) await collect(name);
    else if (entry.isFile()) files.push({ name, bytes: await readFile(resolve(root, name)) });
  }
}

function zip(entries) {
  const bodies = [];
  const directory = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name);
    const crc = crc32(entry.bytes);
    const local = Buffer.alloc(30 + name.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(entry.bytes.length, 18);
    local.writeUInt32LE(entry.bytes.length, 22);
    local.writeUInt16LE(name.length, 26);
    name.copy(local, 30);
    bodies.push(local, entry.bytes);
    const central = Buffer.alloc(46 + name.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(entry.bytes.length, 20);
    central.writeUInt32LE(entry.bytes.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    name.copy(central, 46);
    directory.push(central);
    offset += local.length + entry.bytes.length;
  }
  const directoryBytes = Buffer.concat(directory);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directoryBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...bodies, directoryBytes, end]);
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
  }
  return (value ^ 0xffffffff) >>> 0;
}
