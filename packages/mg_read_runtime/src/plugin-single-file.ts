/**
 * `.mgplugin.js` 单文件 artifact 编解码器。
 *
 * 职责：
 * - 生成和解析带规范化元数据头的单文件 ESM artifact。
 * - 校验 artifact 容器、图标、摘要与大小边界，但绝不分析或执行插件代码。
 * - 将已验证 artifact 合成为标准无依赖 Node 项目输入。
 *
 * 注意：
 * - 单文件代码的运行时依赖由实际 Node 启动处理，不在安装阶段静态扫描。
 * - canonical JSON 的键递归排序，header 必须逐字节匹配该规范形式。
 *
 * TODO:
 * - 无。
 */
import { createHash } from "node:crypto";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";

import {
  type PluginContentKind,
  type PluginPackageDescriptor,
  parsePluginPackageDescriptor,
  pluginApiVersion,
  pluginPackageSchemaVersion,
  readPluginProject,
  resolveInside,
} from "./plugin-package.js";

export const MAX_PLUGIN_ARTIFACT_BYTES = 32 * 1024 * 1024;
export const MAX_PLUGIN_SINGLE_FILE_HEADER_BYTES = 512 * 1024;
export const MAX_PLUGIN_ICON_BYTES = 256 * 1024;
export const PLUGIN_SINGLE_FILE_PREFIX = "// @mgread-plugin-v1 ";

export type PluginArtifactFormat = "archive" | "singleFile";

export class PluginSingleFileError extends Error {
  constructor(
    readonly code:
      | "plugin_artifact_invalid"
      | "plugin_artifact_limit_exceeded",
  ) {
    super("The MgRead single-file plugin artifact is invalid or unsupported.");
    this.name = "PluginSingleFileError";
  }
}

export interface SingleFilePluginDescriptor {
  readonly engines: { readonly node: ">=24 <25" };
  readonly main: "dist/index.mjs";
  readonly mgread: {
    readonly contentKinds: readonly PluginContentKind[];
    readonly description?: string;
    readonly displayName: string;
    readonly icon?: string;
    readonly id: string;
    readonly packageMode: "single-file";
    readonly pluginApi: typeof pluginApiVersion;
    readonly schemaVersion: typeof pluginPackageSchemaVersion;
  };
  readonly name: string;
  readonly type: "module";
  readonly version: string;
}

export interface SingleFilePluginIcon {
  readonly bytes: number;
  readonly data: string;
  readonly mediaType: "image/jpeg" | "image/png" | "image/webp";
  readonly sha256: string;
}

export interface SingleFilePluginEnvelope {
  readonly codeBytes: number;
  readonly codeSha256: string;
  readonly descriptor: SingleFilePluginDescriptor;
  readonly formatVersion: 1;
  readonly icon?: SingleFilePluginIcon;
}

export interface ParsedSingleFilePlugin {
  readonly code: Buffer;
  readonly descriptor: SingleFilePluginDescriptor;
  readonly envelope: SingleFilePluginEnvelope;
  readonly icon?: { readonly bytes: Buffer; readonly mediaType: SingleFilePluginIcon["mediaType"] };
}

export interface PluginSingleFileCreateOptions {
  readonly versionOverride?: string;
}

/** Builds a deterministic `.mgplugin.js` from one standard development project. */
export async function createPluginSingleFile(
  projectRoot: string,
  targetFile: string,
  options: PluginSingleFileCreateOptions = {},
): Promise<void> {
  const project = await readPluginProject(projectRoot);
  if (project.descriptor.packageMode !== "single-file") {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const version = options.versionOverride ?? project.descriptor.version;
  if (!isExactSemver(version)) throw new PluginSingleFileError("plugin_artifact_invalid");
  const code = await readFile(resolveInside(projectRoot, project.descriptor.entry));
  const descriptor = descriptorForEnvelope(project.descriptor, version);
  const icon = project.descriptor.icon === undefined
    ? undefined
    : await readIcon(projectRoot, project.descriptor.icon);
  const envelope = Object.freeze({
    codeBytes: code.byteLength,
    codeSha256: sha256(code),
    descriptor,
    formatVersion: 1,
    ...(icon === undefined ? {} : { icon: icon.envelope }),
  } satisfies SingleFilePluginEnvelope);
  const headerJson = canonicalJson(envelope);
  const header = Buffer.from(
    `${PLUGIN_SINGLE_FILE_PREFIX}${Buffer.from(headerJson, "utf8").toString("base64url")}\n`,
    "utf8",
  );
  if (header.byteLength > MAX_PLUGIN_SINGLE_FILE_HEADER_BYTES ||
      header.byteLength + code.byteLength > MAX_PLUGIN_ARTIFACT_BYTES) {
    throw new PluginSingleFileError("plugin_artifact_limit_exceeded");
  }
  await mkdir(dirname(resolve(targetFile)), { recursive: true });
  await writeFile(targetFile, Buffer.concat([header, code]), { flag: "wx", mode: 0o444 });
}

/** Parses and authenticates a `.mgplugin.js` without importing or evaluating it. */
export async function parsePluginSingleFile(artifactFile: string): Promise<ParsedSingleFilePlugin> {
  const metadata = await stat(artifactFile).catch(() => {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  });
  if (!metadata.isFile()) throw new PluginSingleFileError("plugin_artifact_invalid");
  if (metadata.size <= PLUGIN_SINGLE_FILE_PREFIX.length || metadata.size > MAX_PLUGIN_ARTIFACT_BYTES) {
    throw new PluginSingleFileError("plugin_artifact_limit_exceeded");
  }
  const artifact = await readFile(artifactFile);
  const newline = artifact.indexOf(0x0a);
  if (newline < 0 || newline + 1 > MAX_PLUGIN_SINGLE_FILE_HEADER_BYTES) {
    throw new PluginSingleFileError("plugin_artifact_limit_exceeded");
  }
  const header = artifact.subarray(0, newline + 1).toString("utf8");
  if (!header.startsWith(PLUGIN_SINGLE_FILE_PREFIX) || header.endsWith("\r\n")) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const encoded = header.slice(PLUGIN_SINGLE_FILE_PREFIX.length, -1);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) throw new PluginSingleFileError("plugin_artifact_invalid");
  let raw: unknown;
  try {
    const jsonBytes = Buffer.from(encoded, "base64url");
    if (jsonBytes.toString("base64url") !== encoded) throw new Error("non-canonical base64url");
    raw = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(jsonBytes)) as unknown;
    if (canonicalJson(raw) !== jsonBytes.toString("utf8")) throw new Error("non-canonical JSON");
  } catch {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const envelope = parseEnvelope(raw);
  const code = artifact.subarray(newline + 1);
  if (code.byteLength !== envelope.codeBytes || sha256(code) !== envelope.codeSha256) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const icon = envelope.icon === undefined ? undefined : decodeIcon(envelope.icon);
  return Object.freeze({
    code: Buffer.from(code),
    descriptor: envelope.descriptor,
    envelope,
    ...(icon === undefined ? {} : { icon }),
  });
}

/** Writes a verified single-file artifact as the standard installed project tree. */
export async function materializePluginSingleFile(
  artifactFile: string,
  destinationRoot: string,
): Promise<ParsedSingleFilePlugin> {
  const parsed = await parsePluginSingleFile(artifactFile);
  const packageJson = packageJsonFor(parsed.descriptor);
  const lock = lockfileFor(parsed.descriptor);
  await mkdir(resolve(destinationRoot, "dist"), { recursive: true });
  await Promise.all([
    writeFile(resolve(destinationRoot, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`, { flag: "wx", mode: 0o444 }),
    writeFile(resolve(destinationRoot, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`, { flag: "wx", mode: 0o444 }),
    writeFile(resolve(destinationRoot, "dist", "index.mjs"), parsed.code, { flag: "wx", mode: 0o444 }),
  ]);
  if (parsed.icon !== undefined && parsed.descriptor.mgread.icon !== undefined) {
    const target = resolveInside(destinationRoot, parsed.descriptor.mgread.icon);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, parsed.icon.bytes, { flag: "wx", mode: 0o444 });
  }
  return parsed;
}

function descriptorForEnvelope(
  descriptor: PluginPackageDescriptor,
  version: string,
): SingleFilePluginDescriptor {
  return Object.freeze({
    engines: Object.freeze({ node: ">=24 <25" }),
    main: "dist/index.mjs",
    mgread: Object.freeze({
      contentKinds: Object.freeze([...descriptor.contentKinds]),
      ...(descriptor.description === undefined ? {} : { description: descriptor.description }),
      displayName: descriptor.displayName,
      ...(descriptor.icon === undefined ? {} : { icon: descriptor.icon }),
      id: descriptor.id,
      packageMode: "single-file",
      pluginApi: descriptor.pluginApi,
      schemaVersion: pluginPackageSchemaVersion,
    }),
    name: descriptor.name,
    type: "module",
    version,
  });
}

function parseEnvelope(value: unknown): SingleFilePluginEnvelope {
  if (!isRecord(value) || value.formatVersion !== 1 ||
      !isPositiveBoundedInteger(value.codeBytes, MAX_PLUGIN_ARTIFACT_BYTES) ||
      !isSha256(value.codeSha256) || !isRecord(value.descriptor)) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const descriptor = parseEnvelopeDescriptor(value.descriptor);
  const icon = value.icon === undefined ? undefined : parseIconEnvelope(value.icon);
  if ((descriptor.mgread.icon === undefined) !== (icon === undefined)) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  if (descriptor.mgread.icon !== undefined && icon !== undefined &&
      mediaTypeForIcon(descriptor.mgread.icon) !== icon.mediaType) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const allowed = new Set(["codeBytes", "codeSha256", "descriptor", "formatVersion", "icon"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  return Object.freeze({
    codeBytes: value.codeBytes,
    codeSha256: value.codeSha256,
    descriptor,
    formatVersion: 1,
    ...(icon === undefined ? {} : { icon }),
  });
}

function parseEnvelopeDescriptor(value: Record<string, unknown>): SingleFilePluginDescriptor {
  const allowed = new Set(["engines", "main", "mgread", "name", "type", "version"]);
  if (Object.keys(value).some((key) => !allowed.has(key)) || value.type !== "module" ||
      value.main !== "dist/index.mjs" || !isRecord(value.engines) ||
      Object.keys(value.engines).length !== 1 || value.engines.node !== ">=24 <25" ||
      !isRecord(value.mgread)) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  const mgreadAllowed = new Set([
    "contentKinds", "description", "displayName", "icon", "id",
    "packageMode", "pluginApi", "schemaVersion",
  ]);
  if (Object.keys(value.mgread).some((key) => !mgreadAllowed.has(key)) ||
      value.mgread.packageMode !== "single-file" ||
      value.mgread.schemaVersion !== pluginPackageSchemaVersion ||
      value.mgread.pluginApi !== pluginApiVersion) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  let normalized: PluginPackageDescriptor;
  try {
    normalized = parsePluginPackageDescriptor(value, ".");
  } catch {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  return descriptorForEnvelope(normalized, normalized.version);
}

function parseIconEnvelope(value: unknown): SingleFilePluginIcon {
  if (!isRecord(value) || Object.keys(value).length !== 4 ||
      !isPositiveBoundedInteger(value.bytes, MAX_PLUGIN_ICON_BYTES) ||
      (value.mediaType !== "image/png" && value.mediaType !== "image/jpeg" && value.mediaType !== "image/webp") ||
      typeof value.data !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(value.data) ||
      !isSha256(value.sha256)) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  return Object.freeze({ bytes: value.bytes, data: value.data, mediaType: value.mediaType, sha256: value.sha256 });
}

function decodeIcon(icon: SingleFilePluginIcon): ParsedSingleFilePlugin["icon"] {
  const bytes = Buffer.from(icon.data, "base64");
  if (bytes.toString("base64") !== icon.data || bytes.byteLength !== icon.bytes || sha256(bytes) !== icon.sha256) {
    throw new PluginSingleFileError("plugin_artifact_invalid");
  }
  assertIconSignature(bytes, icon.mediaType);
  return Object.freeze({ bytes, mediaType: icon.mediaType });
}

async function readIcon(projectRoot: string, relativePath: string): Promise<{
  readonly bytes: Buffer;
  readonly envelope: SingleFilePluginIcon;
}> {
  const bytes = await readFile(resolveInside(projectRoot, relativePath));
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_PLUGIN_ICON_BYTES) {
    throw new PluginSingleFileError("plugin_artifact_limit_exceeded");
  }
  const mediaType = mediaTypeForIcon(relativePath);
  assertIconSignature(bytes, mediaType);
  return Object.freeze({
    bytes,
    envelope: Object.freeze({
      bytes: bytes.byteLength,
      data: bytes.toString("base64"),
      mediaType,
      sha256: sha256(bytes),
    }),
  });
}

function packageJsonFor(descriptor: SingleFilePluginDescriptor): Record<string, unknown> {
  return { ...descriptor };
}

function lockfileFor(descriptor: SingleFilePluginDescriptor): Record<string, unknown> {
  return {
    name: descriptor.name,
    version: descriptor.version,
    lockfileVersion: 3,
    requires: true,
    packages: { "": { name: descriptor.name, version: descriptor.version } },
  };
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  throw new PluginSingleFileError("plugin_artifact_invalid");
}

function mediaTypeForIcon(path: string): SingleFilePluginIcon["mediaType"] {
  switch (extname(path).toLowerCase()) {
    case ".png": return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".webp": return "image/webp";
    default: throw new PluginSingleFileError("plugin_artifact_invalid");
  }
}

function assertIconSignature(bytes: Buffer, mediaType: SingleFilePluginIcon["mediaType"]): void {
  const valid = mediaType === "image/png"
    ? bytes.byteLength >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    : mediaType === "image/jpeg"
      ? bytes.byteLength >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
      : bytes.byteLength >= 12 && bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
        bytes.subarray(8, 12).toString("ascii") === "WEBP";
  if (!valid) throw new PluginSingleFileError("plugin_artifact_invalid");
}

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function isPositiveBoundedInteger(value: unknown, maximum: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= maximum;
}

function isSha256(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function isExactSemver(value: string): boolean {
  return /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
