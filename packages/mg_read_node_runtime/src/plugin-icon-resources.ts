/**
 * Runtime 插件图标资源投影。
 *
 * 职责：为已验证的 installed/development 图标签发有界 loopback token 并读取受限字节。
 * 注意：不向 wire 暴露路径或图标字节，资源总量限制为每 Runtime 进程 1024 项。
 */
import { randomBytes } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { resolve } from "node:path";

import type {
  DevelopmentPlugin,
  InstalledPluginSnapshot,
  PluginIconResource,
} from "./plugin-manager-contract.js";
import { readPluginProject, resolveInside } from "./plugin-package.js";

/** Owns bounded icon tokens independently from the PluginManager coordinator. */
export class PluginIconResources {
  readonly #dataRoot: string;
  readonly #resources = new Map<string, { mediaType: PluginIconResource["mediaType"]; path: string }>();
  readonly #tokens = new Map<string, string>();

  constructor(dataRoot: string) { this.#dataRoot = resolve(dataRoot); }

  async project(
    snapshot: InstalledPluginSnapshot,
    development: ReadonlyMap<string, DevelopmentPlugin>,
    origin: string,
  ): Promise<InstalledPluginSnapshot> {
    const activeDevelopment = development.get(snapshot.id);
    const version = snapshot.activeVersion ?? snapshot.pendingVersion;
    let descriptor = activeDevelopment?.loaded.descriptor;
    let projectRoot = activeDevelopment?.projectRoot;
    if (descriptor === undefined && version !== null) {
      projectRoot = resolve(this.#dataRoot, "plugins", snapshot.id, "versions", version);
      try { descriptor = (await readPluginProject(projectRoot)).descriptor; }
      catch { return snapshot; }
    }
    if (descriptor?.icon === undefined || projectRoot === undefined) return snapshot;
    const mediaType = mediaTypeFor(descriptor.icon);
    if (mediaType === undefined) return snapshot;
    const path = resolveInside(projectRoot, descriptor.icon);
    let token = this.#tokens.get(path);
    if (token === undefined) {
      if (this.#resources.size >= 1024) this.#removeOldest();
      token = randomBytes(32).toString("base64url");
      this.#tokens.set(path, token);
      this.#resources.set(token, { mediaType, path });
    }
    return Object.freeze({ ...snapshot, iconUrl: `${origin}/v1/plugin-icon/${token}` });
  }

  async consume(token: string): Promise<PluginIconResource | undefined> {
    const resource = this.#resources.get(token);
    if (resource === undefined) return undefined;
    try {
      const metadata = await lstat(resource.path);
      if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0 || metadata.size > 256 * 1024) return undefined;
      return Object.freeze({ body: await readFile(resource.path), mediaType: resource.mediaType });
    } catch { return undefined; }
  }

  #removeOldest(): void {
    const oldest = this.#resources.keys().next().value;
    if (typeof oldest !== "string") return;
    this.#resources.delete(oldest);
    for (const [path, token] of this.#tokens) {
      if (token === oldest) { this.#tokens.delete(path); break; }
    }
  }
}

function mediaTypeFor(path: string): PluginIconResource["mediaType"] | undefined {
  const lower = path.toLowerCase();
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
  return lower.endsWith(".webp") ? "image/webp" : undefined;
}
