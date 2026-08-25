#!/usr/bin/env node
import { deflateRawSync } from 'node:zlib';
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const crcTable = new Uint32Array(256); for (let index = 0; index < 256; index += 1) { let value = index; for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1; crcTable[index] = value >>> 0; }
if (process.argv.length !== 3 || process.argv[2] !== 'pack') throw new Error('Usage: mgread pack');
const packageJson = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
if (packageJson?.mgread?.schemaVersion !== 1 || packageJson?.mgread?.pluginApi !== 1 || !packageJson.main?.startsWith('dist/')) throw new Error('Invalid MgRead package.');
const files = [];
for (const name of ['package.json', 'package-lock.json', 'README.md', 'LICENSE']) files.push({ path: name, bytes: await readFile(resolve(root, name)) });
// Local `file:./packages/...` dependencies are part of the standard plugin
// archive. Runtime recreates node_modules from the lockfile after install.
for (const directory of ['dist', 'assets', 'packages', 'tools']) await collect(directory);
files.sort((a, b) => a.path.localeCompare(b.path));
const archive = zip(files); const targetDir = resolve(root, 'artifacts'); const target = resolve(targetDir, `${packageJson.mgread.id}-${packageJson.version}.mgplugin`);
await mkdir(targetDir, { recursive: true }); await rm(target, { force: true }); await writeFile(target, archive, { mode: 0o444 });
process.stdout.write(`${relative(root, target).replaceAll('\\', '/')}` + '\n');
async function collect(directory) { let entries = await readdir(resolve(root, directory), { withFileTypes: true }); for (const entry of entries) { if (entry.name === 'node_modules' || entry.isSymbolicLink()) throw new Error('Invalid archive entry.'); const path = `${directory}/${entry.name}`; if (entry.isDirectory()) await collect(path); else files.push({ path, bytes: await readFile(resolve(root, path)) }); } }
function zip(entries) { const local = [], central = []; let offset = 0; for (const entry of entries) { const name = Buffer.from(entry.path); const body = deflateRawSync(entry.bytes, { level: 9 }); const checksum = crc32(entry.bytes); const header = Buffer.alloc(30); header.writeUInt32LE(0x04034b50); header.writeUInt16LE(20, 4); header.writeUInt16LE(0x0800, 6); header.writeUInt16LE(8, 8); header.writeUInt32LE(checksum, 14); header.writeUInt32LE(body.length, 18); header.writeUInt32LE(entry.bytes.length, 22); header.writeUInt16LE(name.length, 26); local.push(header, name, body); const c = Buffer.alloc(46); c.writeUInt32LE(0x02014b50); c.writeUInt16LE(20, 4); c.writeUInt16LE(20, 6); c.writeUInt16LE(0x0800, 8); c.writeUInt16LE(8, 10); c.writeUInt32LE(checksum, 16); c.writeUInt32LE(body.length, 20); c.writeUInt32LE(entry.bytes.length, 24); c.writeUInt16LE(name.length, 28); c.writeUInt32LE(offset, 42); central.push(c, name); offset += header.length + name.length + body.length; } const centralBytes = Buffer.concat(central); const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(centralBytes.length, 12); end.writeUInt32LE(offset, 16); return Buffer.concat([...local, centralBytes, end]); }
function crc32(bytes) { let value = 0xffffffff; for (const byte of bytes) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8); return (value ^ 0xffffffff) >>> 0; }
