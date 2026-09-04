/**
 * Runtime-private bounded HLS manifest warmup.
 *
 * Responsibilities:
 * - Share root-manifest work with the first loopback request.
 * - Retain at most eight 1 MiB manifests for 15 seconds with concurrency two.
 * - Follow only one unambiguous child playlist and never fetch media or keys.
 *
 * Notes:
 * - Range requests always bypass this cache.
 * - Failures are deliberately invisible to callers, which use live forwarding.
 */
import type { JsonObject } from "./protocol.js";
import {
  openSourceProxyResource,
  type SourceProxyEntry,
  type SourceProxyResource,
} from "./source-resource-proxy.js";

const maximumEntries = 8;
const maximumManifestBytes = 1024 * 1024;
const timeToLiveMs = 15_000;
const fetchTimeoutMs = 5_000;
const maximumDepth = 2;

export type HlsWarmupEvent = {
  readonly bytes?: number;
  readonly durationMs: number;
  readonly phase: "failed" | "hit" | "ready" | "started";
  readonly pluginId: string;
  readonly resourceRole: "hlsPlaylist" | "hlsRoot";
};

type ManifestRecord = {
  readonly body: Uint8Array;
  readonly headers: readonly (readonly [string, string])[];
  readonly responseUrl: string;
  readonly status: number;
};

type CacheEntry = {
  readonly expiresAt: number;
  readonly promise: Promise<ManifestRecord | undefined>;
};

export class HlsManifestWarmup {
  readonly #entries = new Map<string, CacheEntry>();
  readonly #waiters: Array<() => void> = [];
  readonly #event: (event: HlsWarmupEvent) => void;
  readonly #now: () => number;
  #active = 0;

  constructor(
    event: (event: HlsWarmupEvent) => void = () => {},
    now: () => number = Date.now,
  ) {
    this.#event = event;
    this.#now = now;
  }

  schedule(pluginId: string, entry: SourceProxyEntry): void {
    if (!isRootHls(entry.request)) return;
    void this.#ensure(pluginId, entry, 1);
  }

  async open(
    pluginId: string,
    entry: SourceProxyEntry,
    requestHeaders: Readonly<Record<string, string>>,
    signal: AbortSignal,
  ): Promise<SourceProxyResource | undefined> {
    if (!isHls(entry.request) || hasRange(requestHeaders)) {
      return openSourceProxyResource(entry, requestHeaders, signal);
    }
    const record = await this.#waitForSignal(
      this.#ensure(pluginId, entry, entry.request.resourceRole === "hlsPlaylist" ? 2 : 1),
      signal,
    );
    if (record !== undefined) {
      this.#emit({
        bytes: record.body.byteLength,
        durationMs: 0,
        phase: "hit",
        pluginId,
        resourceRole: roleOf(entry.request),
      });
      return resourceFromRecord(entry, record);
    }
    return openSourceProxyResource(entry, requestHeaders, signal);
  }

  async #ensure(
    pluginId: string,
    entry: SourceProxyEntry,
    depth: number,
  ): Promise<ManifestRecord | undefined> {
    const key = cacheKey(pluginId, entry.request);
    const now = this.#now();
    const existing = this.#entries.get(key);
    if (existing !== undefined && existing.expiresAt > now) return existing.promise;
    if (existing !== undefined) this.#entries.delete(key);

    const promise = this.#runBounded(async () => {
      const startedAt = performance.now();
      this.#emit({ durationMs: 0, phase: "started", pluginId, resourceRole: roleOf(entry.request) });
      const cancellation = new AbortController();
      const timeout = setTimeout(() => cancellation.abort(), fetchTimeoutMs);
      try {
        const resource = await openSourceProxyResource(entry, {}, cancellation.signal);
        if (resource === undefined || !resource.response.ok) return undefined;
        const body = await readBounded(resource.response, cancellation);
        const record: ManifestRecord = Object.freeze({
          body,
          headers: Object.freeze([...resource.response.headers.entries()].map(([name, value]) => Object.freeze([name, value] as const))),
          responseUrl: resource.responseUrl,
          status: resource.response.status,
        });
        this.#emit({
          bytes: body.byteLength,
          durationMs: Math.round(performance.now() - startedAt),
          phase: "ready",
          pluginId,
          resourceRole: roleOf(entry.request),
        });
        if (depth < maximumDepth) {
          const child = soleChildPlaylist(new TextDecoder().decode(body), resource.responseUrl);
          if (child !== undefined) {
            const childRequest: JsonObject = {
              ...entry.request,
              kind: "hls",
              resourceRole: "hlsPlaylist",
              url: child,
            };
            void this.#ensure(pluginId, { ...entry, request: childRequest }, depth + 1);
          }
        }
        return record;
      } catch {
        this.#emit({
          durationMs: Math.round(performance.now() - startedAt),
          phase: "failed",
          pluginId,
          resourceRole: roleOf(entry.request),
        });
        return undefined;
      } finally {
        clearTimeout(timeout);
      }
    });
    this.#entries.set(key, { expiresAt: now + timeToLiveMs, promise });
    while (this.#entries.size > maximumEntries) {
      const oldest = this.#entries.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.#entries.delete(oldest);
    }
    return promise;
  }

  async #runBounded<T>(operation: () => Promise<T>): Promise<T> {
    if (this.#active >= 2) {
      await new Promise<void>((resolve) => this.#waiters.push(resolve));
    }
    this.#active += 1;
    try {
      return await operation();
    } finally {
      this.#active -= 1;
      this.#waiters.shift()?.();
    }
  }

  async #waitForSignal<T>(promise: Promise<T>, signal: AbortSignal): Promise<T | undefined> {
    if (signal.aborted) return undefined;
    return new Promise<T | undefined>((resolve) => {
      const aborted = (): void => resolve(undefined);
      signal.addEventListener("abort", aborted, { once: true });
      void promise.then(
        (value) => {
          signal.removeEventListener("abort", aborted);
          resolve(value);
        },
        () => {
          signal.removeEventListener("abort", aborted);
          resolve(undefined);
        },
      );
    });
  }

  #emit(event: HlsWarmupEvent): void {
    try { this.#event(event); } catch { /* Diagnostics never affect media. */ }
  }
}

async function readBounded(response: Response, cancellation: AbortController): Promise<Uint8Array> {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maximumManifestBytes) throw new Error("manifest_too_large");
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      bytes += next.value.byteLength;
      if (bytes > maximumManifestBytes) {
        cancellation.abort();
        throw new Error("manifest_too_large");
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function resourceFromRecord(entry: SourceProxyEntry, record: ManifestRecord): SourceProxyResource {
  return Object.freeze({
    proxy: entry.proxy,
    request: entry.request,
    response: new Response(record.body.slice(), {
      headers: new Headers(Object.fromEntries(record.headers)),
      status: record.status,
    }),
    responseUrl: record.responseUrl,
  });
}

function soleChildPlaylist(text: string, base: string): string | undefined {
  const candidates = new Set<string>();
  let nextPlainUriIsPlaylist = false;
  for (const line of text.split(/\r?\n/u)) {
    if (line === "") continue;
    if (!line.startsWith("#")) {
      if (nextPlainUriIsPlaylist || isPlaylistUri(line)) candidates.add(new URL(line, base).toString());
      nextPlainUriIsPlaylist = false;
      continue;
    }
    const separator = line.indexOf(":");
    const tag = separator === -1 ? line : line.slice(0, separator);
    if (tag === "#EXT-X-STREAM-INF") nextPlainUriIsPlaylist = true;
    if (!playlistUriTags.has(tag)) continue;
    for (const match of line.matchAll(/URI="([^"]+)"/gu)) {
      const uri = match[1];
      if (uri !== undefined) candidates.add(new URL(uri, base).toString());
    }
  }
  return candidates.size === 1 ? candidates.values().next().value : undefined;
}

const playlistUriTags = new Set([
  "#EXT-X-I-FRAME-STREAM-INF",
  "#EXT-X-MEDIA",
  "#EXT-X-RENDITION-REPORT",
]);

function isPlaylistUri(raw: string): boolean {
  try { return new URL(raw, "https://mgread.invalid/").pathname.toLowerCase().endsWith(".m3u8"); }
  catch { return false; }
}

function cacheKey(pluginId: string, request: JsonObject): string {
  return `${pluginId}\u0000${JSON.stringify(request)}`;
}

function hasRange(headers: Readonly<Record<string, string>>): boolean {
  return headers.range !== undefined || headers["if-range"] !== undefined;
}

function isHls(request: JsonObject): boolean { return request.kind === "hls"; }

function isRootHls(request: JsonObject): boolean {
  return isHls(request) && request.resourceRole === undefined;
}

function roleOf(request: JsonObject): "hlsPlaylist" | "hlsRoot" {
  return request.resourceRole === "hlsPlaylist" ? "hlsPlaylist" : "hlsRoot";
}
