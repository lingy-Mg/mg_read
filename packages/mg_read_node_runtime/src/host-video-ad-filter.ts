/**
 * Host-owned, per-playback HLS filtering policy. A global app preference is
 * projected into the resolved resource descriptor, not persisted in Runtime.
 * Existing valid source policy wins while enabled; disabling explicitly clears
 * that policy. Other resource kinds and non-video callers are unchanged.
 */
import type { PluginHlsAdFilter } from "@mgread/source-api";
import { readHlsAdFilter } from "./hls-ad-analysis.js";
import type { JsonObject } from "./protocol.js";

export const defaultVideoAdFilter = Object.freeze({
  algorithm: "sequence-islands-v1",
  maximumInterstitialSeconds: 90,
  maximumInterstitialSegments: 32,
  minimumContentSegments: 30,
  minimumContentDurationRatio: 0.85,
  minimumFeatureContrast: 0.2,
} satisfies PluginHlsAdFilter);

export function applyHostVideoAdFilter(request: JsonObject, enabled: boolean | undefined): JsonObject {
  if (enabled === undefined || request.kind !== "hls") return request;
  const { hlsAdFilter, ...original } = request;
  return enabled
    ? { ...original, hlsAdFilter: { ...(readHlsAdFilter(hlsAdFilter) ?? defaultVideoAdFilter) } }
    : original;
}
