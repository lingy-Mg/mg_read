/**
 * Runtime-owned opt-in HLS filtering. Sources supply a bounded structural policy;
 * this owner confirms candidate islands with three limited TS-prefix requests.
 * No ad domains/paths/comments are special-cased, no media body enters a plugin.
 * A failed/ambiguous probe keeps the original interval. Cancellation is propagated
 * to every request and reader; unchanged sources incur no filtering/probe work.
 */
import { contentLimits } from './content-limits.js';
import { analyzeHlsAdIslands, readHlsAdFilter, type HlsAdCandidate } from "./hls-ad-analysis.js";
import { readTransportClock, transportClockDelta, type TransportClock } from "./hls-transport-clock.js";
import { openSourceProxyResource, type SourceProxyEntry, type SourceProxyResource } from "./source-resource-proxy.js";

export type HlsAdFilterResult = { readonly text: string; readonly removedSegments: number; readonly removedDuration: number };

export async function filterHlsAdManifest(
  text: string, base: string, policy: unknown,
  probe: (url: string) => Promise<TransportClock | undefined>,
): Promise<HlsAdFilterResult> {
  const unchanged = { text, removedSegments: 0, removedDuration: 0 };
  const rules = readHlsAdFilter(policy);
  const analysis = rules === undefined ? undefined : analyzeHlsAdIslands(text, base, rules);
  if (analysis === undefined || analysis.candidates.length === 0) return unchanged;
  const confirmed: HlsAdCandidate[] = [];
  for (const candidate of analysis.candidates) {
    const clocks = await Promise.allSettled([candidate.before.url, candidate.inserted[0]!.url, candidate.after.url].map(probe));
    if (!clocks.every(clock => clock.status === "fulfilled" && clock.value !== undefined)) continue;
    const [before, inserted, after] = clocks.map(clock => clock.status === "fulfilled" ? clock.value! : undefined!);
    // A fixed frame-reordering allowance must not swallow a legitimate short
    // transition. Its entire duration must remain distinguishable from jitter.
    const tolerance = Math.min(0.25, candidate.inserted.reduce((sum, segment) => sum + segment.duration, 0) / 8);
    if (before!.tracks !== after!.tracks ||
        Math.abs(transportClockDelta(after!.pts, before!.pts) - candidate.before.duration) > tolerance ||
        Math.abs(transportClockDelta(inserted!.pts, after!.pts)) < Math.max(1, candidate.before.duration / 2)) continue;
    confirmed.push(candidate);
  }
  if (confirmed.length === 0) return unchanged;
  const removed = new Set<number>();
  for (const candidate of confirmed) for (let line = candidate.startLine; line < candidate.endLine; line += 1) removed.add(line);
  return {
    text: analysis.lines.filter((_line, index) => !removed.has(index)).join(text.includes("\r\n") ? "\r\n" : "\n"),
    removedSegments: confirmed.reduce((sum, candidate) => sum + candidate.inserted.length, 0),
    removedDuration: Math.round(confirmed.flatMap(candidate => candidate.inserted).reduce((sum, segment) => sum + segment.duration, 0) * 1e6) / 1e6,
  };
}

export async function filterSourceHlsResource(
  resource: SourceProxyResource, entry: SourceProxyEntry, signal: AbortSignal,
): Promise<SourceProxyResource> {
  if (resource.request.kind !== "hls" || resource.response.status !== 200 || readHlsAdFilter(resource.request.hlsAdFilter) === undefined) return resource;
  const text = new TextDecoder().decode(await readPrefix(resource.response, contentLimits.hlsBytes, signal, true));
  const timeout = AbortSignal.any([signal, AbortSignal.timeout(6000)]);
  const probes = new Map<string, Promise<TransportClock | undefined>>();
  const probe = (url: string) => {
    let pending = probes.get(url);
    if (pending === undefined) {
      pending = probeClock(entry, url, timeout);
      probes.set(url, pending);
    }
    return pending;
  };
  const result = await filterHlsAdManifest(text, resource.responseUrl, resource.request.hlsAdFilter, probe);
  signal.throwIfAborted();
  const headers = new Headers(resource.response.headers);
  headers.delete("content-length"); headers.delete("content-encoding");
  return { ...resource, response: new Response(result.text, { status: resource.response.status, statusText: resource.response.statusText, headers }) };
}

async function probeClock(entry: SourceProxyEntry, url: string, signal: AbortSignal): Promise<TransportClock | undefined> {
  try {
    const { hlsAdFilter: _policy, ...request } = entry.request;
    const media = await openSourceProxyResource({ ...entry, request: { ...request, kind: "video", resourceRole: "hlsMedia", url } }, { range: "bytes=0-65535" }, signal);
    if (media === undefined || !media.response.ok) { await media?.response.body?.cancel(); return undefined; }
    if (media.response.status === 206 && !/^bytes 0-/u.test(media.response.headers.get("content-range") ?? "")) {
      await media.response.body?.cancel(); return undefined;
    }
    return readTransportClock(await readPrefix(media.response, 65536, signal));
  } catch { return undefined; }
}

async function readPrefix(response: Response, limit: number, signal: AbortSignal, complete = false): Promise<Uint8Array> {
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  const aborted = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", aborted, { once: true });
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    signal.throwIfAborted();
    while (true) {
      const next = await reader.read();
      signal.throwIfAborted();
      if (next.done) break;
      if (complete && size + next.value.byteLength > limit) throw new Error("manifest_too_large");
      const chunk = next.value.subarray(0, limit - size);
      chunks.push(chunk); size += chunk.byteLength;
      if (!complete && size >= limit) break;
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  } finally {
    signal.removeEventListener("abort", aborted);
    await reader.cancel().catch(() => {});
  }
}
