import { deflateRawSync, inflateRawSync } from "node:zlib";
import {
  lstat,
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, extname, resolve } from "node:path";

import {
  normalizePluginRelativePath,
  PluginPackageError,
  resolveInside,
} from "./plugin-package.js";

const MAX_ARCHIVE_BYTES = 128 * 1024 * 1024;
const MAX_ENTRY_BYTES = 64 * 1024 * 1024;
const MAX_ENTRY_COUNT = 4_096;
const MAX_TOTAL_UNCOMPRESSED_BYTES = 256 * 1024 * 1024;
const MAX_COMPRESSION_RATIO = 200;
const ZIP_EOCD_SIGNATURE = 0x06054b50;
const ZIP_CENTRAL_SIGNATURE = 0x02014b50;
const ZIP_LOCAL_SIGNATURE = 0x04034b50;
const UTF8_FLAG = 0x0800;

/** Stable archive failure that never preserves a path or raw ZIP detail. */
export class PluginArchiveError extends Error {
  constructor(
    readonly code:
      | "plugin_archive_invalid"
      | "plugin_archive_limit_exceeded"
      | "plugin_archive_unsafe_path",
  ) {
    super("The MgRead plugin archive is invalid or unsupported.");
    this.name = "PluginArchiveError";
  }
}

interface ZipEntry {
  readonly compressedSize: number;
  readonly compressionMethod: 0 | 8;
  readonly crc32: number;
  readonly externalAttributes: number;
  readonly localOffset: number;
  readonly path: string;
  readonly uncompressedSize: number;
}

interface ArchiveSourceFile {
  readonly bytes: Buffer;
  readonly path: string;
}

/** Creates a deterministic `.mgplugin` ZIP containing one standard Node project. */
export async function createPluginArchive(
  projectRoot: string,
  targetFile: string,
): Promise<void> {
  const files = await collectProjectFiles(resolve(projectRoot));
  if (files.length === 0 || files.length > MAX_ENTRY_COUNT) {
    throw new PluginArchiveError("plugin_archive_limit_exceeded");
  }
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let localOffset = 0;
  let totalBytes = 0;

  for (const file of files) {
    if (file.bytes.length > MAX_ENTRY_BYTES) {
      throw new PluginArchiveError("plugin_archive_limit_exceeded");
    }
    totalBytes += file.bytes.length;
    if (totalBytes > MAX_TOTAL_UNCOMPRESSED_BYTES) {
      throw new PluginArchiveError("plugin_archive_limit_exceeded");
    }

    const name = Buffer.from(file.path, "utf8");
    const compressed = deflateRawSync(file.bytes, { level: 9 });
    const checksum = crc32(file.bytes);
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(ZIP_LOCAL_SIGNATURE, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(UTF8_FLAG, 6);
    localHeader.writeUInt16LE(8, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(33, 12); // 1980-01-01 for reproducible output.
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(file.bytes.length, 22);
    localHeader.writeUInt16LE(name.length, 26);
    localHeader.writeUInt16LE(0, 28);
    localParts.push(localHeader, name, compressed);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(ZIP_CENTRAL_SIGNATURE, 0);
    centralHeader.writeUInt16LE(0x0314, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(UTF8_FLAG, 8);
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
    centralHeader.writeUInt32LE(localOffset, 42);
    centralParts.push(centralHeader, name);
    localOffset += localHeader.length + name.length + compressed.length;
  }

  const central = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(ZIP_EOCD_SIGNATURE, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(central.length, 12);
  end.writeUInt32LE(localOffset, 16);
  end.writeUInt16LE(0, 20);

  const archive = Buffer.concat([...localParts, central, end]);
  if (archive.length > MAX_ARCHIVE_BYTES) {
    throw new PluginArchiveError("plugin_archive_limit_exceeded");
  }
  await mkdir(dirname(resolve(targetFile)), { recursive: true });
  await writeFile(targetFile, archive, { flag: "wx", mode: 0o444 });
}

/** Safely extracts a `.mgplugin` ZIP into an empty Runtime-owned directory. */
export async function extractPluginArchive(
  archiveFile: string,
  destinationRoot: string,
): Promise<readonly string[]> {
  const archive = await readFile(archiveFile);
  if (archive.length > MAX_ARCHIVE_BYTES) {
    throw new PluginArchiveError("plugin_archive_limit_exceeded");
  }
  const entries = parseCentralDirectory(archive);
  await mkdir(destinationRoot, { recursive: true });
  const extracted: string[] = [];
  let totalBytes = 0;
  for (const entry of entries) {
    totalBytes += entry.uncompressedSize;
    if (totalBytes > MAX_TOTAL_UNCOMPRESSED_BYTES) {
      throw new PluginArchiveError("plugin_archive_limit_exceeded");
    }
    const bytes = inflateEntry(archive, entry);
    const target = resolveInside(destinationRoot, entry.path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, bytes, { flag: "wx", mode: 0o444 });
    extracted.push(entry.path);
  }
  return Object.freeze(extracted);
}

function parseCentralDirectory(archive: Buffer): readonly ZipEntry[] {
  const eocdOffset = findEndOfCentralDirectory(archive);
  const diskNumber = archive.readUInt16LE(eocdOffset + 4);
  const centralDisk = archive.readUInt16LE(eocdOffset + 6);
  const diskEntries = archive.readUInt16LE(eocdOffset + 8);
  const totalEntries = archive.readUInt16LE(eocdOffset + 10);
  const centralSize = archive.readUInt32LE(eocdOffset + 12);
  const centralOffset = archive.readUInt32LE(eocdOffset + 16);
  const commentLength = archive.readUInt16LE(eocdOffset + 20);
  if (
    diskNumber !== 0 ||
    centralDisk !== 0 ||
    diskEntries !== totalEntries ||
    totalEntries === 0 ||
    totalEntries > MAX_ENTRY_COUNT ||
    centralOffset + centralSize > eocdOffset ||
    eocdOffset + 22 + commentLength !== archive.length
  ) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }

  const entries: ZipEntry[] = [];
  const seen = new Set<string>();
  let offset = centralOffset;
  for (let index = 0; index < totalEntries; index += 1) {
    if (offset + 46 > archive.length || archive.readUInt32LE(offset) !== ZIP_CENTRAL_SIGNATURE) {
      throw new PluginArchiveError("plugin_archive_invalid");
    }
    const flags = archive.readUInt16LE(offset + 8);
    const method = archive.readUInt16LE(offset + 10);
    const checksum = archive.readUInt32LE(offset + 16);
    const compressedSize = archive.readUInt32LE(offset + 20);
    const uncompressedSize = archive.readUInt32LE(offset + 24);
    const nameLength = archive.readUInt16LE(offset + 28);
    const extraLength = archive.readUInt16LE(offset + 30);
    const entryCommentLength = archive.readUInt16LE(offset + 32);
    const externalAttributes = archive.readUInt32LE(offset + 38);
    const localOffset = archive.readUInt32LE(offset + 42);
    const next = offset + 46 + nameLength + extraLength + entryCommentLength;
    if (
      next > archive.length ||
      (flags & 0x0001) !== 0 ||
      (flags & UTF8_FLAG) === 0 ||
      (method !== 0 && method !== 8) ||
      compressedSize === 0xffffffff ||
      uncompressedSize === 0xffffffff ||
      localOffset === 0xffffffff ||
      compressedSize > MAX_ARCHIVE_BYTES ||
      uncompressedSize > MAX_ENTRY_BYTES ||
      (compressedSize === 0
        ? uncompressedSize !== 0
        : uncompressedSize / compressedSize > MAX_COMPRESSION_RATIO)
    ) {
      throw new PluginArchiveError("plugin_archive_limit_exceeded");
    }
    const rawName = archive.subarray(offset + 46, offset + 46 + nameLength).toString("utf8");
    if (rawName.endsWith("/")) {
      throw new PluginArchiveError("plugin_archive_invalid");
    }
    const path = normalizeArchiveEntryPath(rawName);
    const collisionKey = path.toLocaleLowerCase("en-US");
    if (seen.has(collisionKey) || isSymlink(externalAttributes)) {
      throw new PluginArchiveError("plugin_archive_unsafe_path");
    }
    seen.add(collisionKey);
    entries.push({
      compressedSize,
      compressionMethod: method,
      crc32: checksum,
      externalAttributes,
      localOffset,
      path,
      uncompressedSize,
    });
    offset = next;
  }
  if (offset !== centralOffset + centralSize) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  return Object.freeze(entries);
}

function inflateEntry(archive: Buffer, entry: ZipEntry): Buffer {
  const offset = entry.localOffset;
  if (offset + 30 > archive.length || archive.readUInt32LE(offset) !== ZIP_LOCAL_SIGNATURE) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  const flags = archive.readUInt16LE(offset + 6);
  const method = archive.readUInt16LE(offset + 8);
  const nameLength = archive.readUInt16LE(offset + 26);
  const extraLength = archive.readUInt16LE(offset + 28);
  const dataOffset = offset + 30 + nameLength + extraLength;
  const dataEnd = dataOffset + entry.compressedSize;
  if (
    (flags & 0x0001) !== 0 ||
    method !== entry.compressionMethod ||
    dataEnd > archive.length
  ) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  const localName = archive.subarray(offset + 30, offset + 30 + nameLength).toString("utf8");
  if (normalizeArchiveEntryPath(localName) !== entry.path) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  let bytes: Buffer;
  try {
    const compressed = archive.subarray(dataOffset, dataEnd);
    bytes = entry.compressionMethod === 0 ? Buffer.from(compressed) : inflateRawSync(compressed);
  } catch {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  if (bytes.length !== entry.uncompressedSize || crc32(bytes) !== entry.crc32) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  return bytes;
}

function findEndOfCentralDirectory(archive: Buffer): number {
  const minimum = Math.max(0, archive.length - 65_557);
  for (let offset = archive.length - 22; offset >= minimum; offset -= 1) {
    if (archive.readUInt32LE(offset) === ZIP_EOCD_SIGNATURE) {
      return offset;
    }
  }
  throw new PluginArchiveError("plugin_archive_invalid");
}

function normalizeArchiveEntryPath(value: string): string {
  try {
    return normalizePluginRelativePath(value);
  } catch (error) {
    if (error instanceof PluginPackageError) {
      throw new PluginArchiveError("plugin_archive_unsafe_path");
    }
    throw error;
  }
}

function isSymlink(externalAttributes: number): boolean {
  const unixMode = externalAttributes >>> 16;
  return (unixMode & 0o170000) === 0o120000;
}

async function collectProjectFiles(projectRoot: string): Promise<ArchiveSourceFile[]> {
  const allowedRootFiles = new Set([
    "package.json",
    "package-lock.json",
  ]);
  const allowedRootDirectories = new Set([
    "assets",
    "dist",
    "packages",
    "tools",
  ]);
  const files: ArchiveSourceFile[] = [];
  for (const entry of await readdir(projectRoot, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) {
      throw new PluginArchiveError("plugin_archive_unsafe_path");
    }
    if (entry.isFile()) {
      const lowerName = entry.name.toLowerCase();
      if (
        !allowedRootFiles.has(entry.name) &&
        !lowerName.startsWith("readme") &&
        !lowerName.startsWith("license")
      ) {
        continue;
      }
      files.push({
        bytes: await readFile(resolve(projectRoot, entry.name)),
        path: normalizeArchiveEntryPath(entry.name),
      });
      continue;
    }
    if (entry.isDirectory() && allowedRootDirectories.has(entry.name)) {
      await collectDirectory(projectRoot, entry.name, files);
    }
  }
  files.sort((left, right) => left.path.localeCompare(right.path));
  if (!files.some((file) => file.path === "package.json") ||
      !files.some((file) => file.path === "package-lock.json") ||
      !files.some((file) => file.path.startsWith("dist/"))) {
    throw new PluginArchiveError("plugin_archive_invalid");
  }
  return files;
}

async function collectDirectory(
  projectRoot: string,
  relativeDirectory: string,
  files: ArchiveSourceFile[],
): Promise<void> {
  const absolute = resolveInside(projectRoot, relativeDirectory);
  for (const entry of await readdir(absolute, { withFileTypes: true })) {
    const child = `${relativeDirectory}/${entry.name}`;
    if (entry.isSymbolicLink()) {
      throw new PluginArchiveError("plugin_archive_unsafe_path");
    }
    if (entry.isDirectory()) {
      if (entry.name === "node_modules") {
        throw new PluginArchiveError("plugin_archive_invalid");
      }
      await collectDirectory(projectRoot, child, files);
      continue;
    }
    if (!entry.isFile()) {
      throw new PluginArchiveError("plugin_archive_invalid");
    }
    const path = normalizeArchiveEntryPath(child);
    const file = await lstat(resolveInside(projectRoot, path));
    if (!file.isFile() || file.size > MAX_ENTRY_BYTES) {
      throw new PluginArchiveError("plugin_archive_limit_exceeded");
    }
    files.push({ bytes: await readFile(resolveInside(projectRoot, path)), path });
  }
}

const crcTable = buildCrcTable();

function crc32(bytes: Buffer): number {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value = crcTable[(value ^ byte) & 0xff]! ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function buildCrcTable(): Uint32Array {
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
