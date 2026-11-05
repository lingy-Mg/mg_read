/**
 * Pure, opt-in HLS sequence analysis. Learns the dominant URI naming family and
 * proposes bounded foreign islands only when the same content resumes on both
 * sides. This is structural evidence, never a domain/comment/duration blacklist.
 * Unknown HLS state, encrypted/live media and uncertain filename joins fail open.
 * Actual removal additionally requires Runtime-owned transport-clock probes.
 */
import type { PluginHlsAdFilter } from "@mgread/source-api";
import { projectHlsDifferences, type HlsAdProjection } from "./hls-ad-projection.js";

export type HlsSegment = {
  readonly url: string;
  readonly duration: number;
  readonly family: string;
  readonly sequence: bigint | undefined;
  readonly line: number;
  readonly boundaries: readonly number[];
};
export type HlsAdCandidate = {
  readonly before: HlsSegment;
  readonly inserted: readonly HlsSegment[];
  readonly after: HlsSegment;
  readonly startLine: number;
  readonly endLine: number;
};
export type HlsAdAnalysis = HlsAdProjection & { readonly lines: readonly string[]; readonly candidates: readonly HlsAdCandidate[] };

export function readHlsAdFilter(value: unknown): PluginHlsAdFilter | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  const rules = value as Record<string, unknown>;
  if (rules.algorithm !== "sequence-islands-v1" ||
      !bounded(rules.maximumInterstitialSeconds, 1, 120) ||
      !bounded(rules.maximumInterstitialSegments, 1, 64, true) ||
      !bounded(rules.minimumContentSegments, 10, 500, true) ||
      !bounded(rules.minimumContentDurationRatio, 0.8, 0.99) ||
      !bounded(rules.minimumFeatureContrast, 0.1, 0.8)) return undefined;
  return rules as PluginHlsAdFilter;
}

export function analyzeHlsAdIslands(text: string, base: string, rules: PluginHlsAdFilter): HlsAdAnalysis | undefined {
  if (text.length > 1024 * 1024 || !text.trimStart().startsWith("#EXTM3U")) return undefined;
  const lines = text.split(/\r?\n/u), segments: HlsSegment[] = [];
  let duration: number | undefined, boundaries: number[] = [], ended = false;
  for (let line = 0; line < lines.length; line += 1) {
    const value = lines[line]!.trim();
    if (value === "" || value.startsWith("#") && !value.startsWith("#EXT")) continue;
    if (ended) return undefined;
    if (value.startsWith("#EXTINF:")) {
      const match = /^#EXTINF:(\d+(?:\.\d+)?),[^\r\n]*$/u.exec(value);
      if (duration !== undefined || match === null || !bounded(Number(match[1]), 0.001, 120)) return undefined;
      duration = Number(match[1]);
    } else if (value === "#EXT-X-DISCONTINUITY") {
      if (duration !== undefined) return undefined;
      boundaries.push(line);
    } else if (value === "#EXT-X-ENDLIST") {
      if (duration !== undefined || boundaries.length !== 0) return undefined;
      ended = true;
    } else if (value.startsWith("#EXT")) {
      // Stateful extensions require timeline/key/byte-range reconciliation; do
      // not guess. This allowlist is intentionally narrower than HLS playback.
      if (!/^#EXTM3U$|^#EXT-X-(?:VERSION|TARGETDURATION|MEDIA-SEQUENCE|DISCONTINUITY-SEQUENCE):\d+$|^#EXT-X-PLAYLIST-TYPE:VOD$|^#EXT-X-INDEPENDENT-SEGMENTS$/u.test(value)) return undefined;
    } else {
      if (duration === undefined) return undefined;
      const identity = segmentIdentity(value, base);
      if (identity === undefined) return undefined;
      segments.push({ ...identity, duration, line, boundaries });
      duration = undefined; boundaries = [];
    }
  }
  if (!ended || segments.length < rules.minimumContentSegments + 3) return undefined;
  const families = new Map<string, { count: number; duration: number }>();
  let total = 0;
  for (const segment of segments) {
    const stats = families.get(segment.family) ?? { count: 0, duration: 0 };
    stats.count += 1; stats.duration += segment.duration; total += segment.duration;
    families.set(segment.family, stats);
  }
  const primary = [...families].sort((left, right) => right[1].duration - left[1].duration)[0];
  if (primary === undefined || primary[1].count < rules.minimumContentSegments ||
      primary[1].duration / total < rules.minimumContentDurationRatio) return undefined;
  const projection = projectHlsDifferences(segments, primary[0], rules.minimumFeatureContrast);
  const candidates: HlsAdCandidate[] = [];
  for (let start = 1; start < segments.length - 1; start += 1) {
    if (segments[start]!.family === primary[0] || segments[start - 1]!.family !== primary[0]) continue;
    let end = start;
    while (end < segments.length && segments[end]!.family !== primary[0]) end += 1;
    const before = segments[start - 1]!, after = segments[end];
    if (after === undefined) break;
    const inserted = segments.slice(start, end);
    if (inserted.some((_segment, index) => projection.scores[start + index]! < projection.threshold) ||
        inserted.length > rules.maximumInterstitialSegments ||
        inserted.reduce((sum, segment) => sum + segment.duration, 0) > rules.maximumInterstitialSeconds ||
        inserted[0]!.boundaries.length !== 1 || after.boundaries.length !== 1 ||
        before.sequence !== undefined && after.sequence !== before.sequence + 1n) { start = end; continue; }
    let startLine = inserted[0]!.boundaries[0]!;
    // Remove adjacent non-semantic comments as part of the confirmed island;
    // their wording never participates in identification.
    while (startLine > before.line + 1 && !lines[startLine - 1]!.trim().startsWith("#EXT")) startLine -= 1;
    candidates.push({ before, inserted, after, startLine, endLine: after.boundaries[0]! + 1 });
    if (candidates.length === 4) break;
    start = end;
  }
  return { ...projection, lines, candidates };
}

function segmentIdentity(raw: string, base: string): Pick<HlsSegment, "url" | "family" | "sequence"> | undefined {
  try {
    const url = new URL(raw, base);
    if (!["http:", "https:"].includes(url.protocol) || url.username !== "" || url.password !== "" ||
        !url.pathname.endsWith(".ts")) return undefined;
    const filename = url.pathname.split("/").at(-1)!.slice(0, -3);
    const directory = url.origin + url.pathname.slice(0, url.pathname.lastIndexOf("/") + 1);
    // Hashes and opaque tokens do not imply sequence order. Numbered filenames
    // contribute an independent join check; signatures in queries are ignored.
    const numbered = /^[a-f\d]{24,64}$/iu.test(filename) ? null : /^(.*?)(\d{3,24})$/u.exec(filename);
    const shape = numbered === null ? "opaque" : `numbered:${numbered[1]}:${numbered[2]!.length}`;
    return { url: url.href, family: `${directory}\u0000${shape}`, sequence: numbered === null ? undefined : BigInt(numbered[2]!) };
  } catch { return undefined; }
}

function bounded(value: unknown, minimum: number, maximum: number, integer = false): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= minimum && value <= maximum && (!integer || Number.isSafeInteger(value));
}
