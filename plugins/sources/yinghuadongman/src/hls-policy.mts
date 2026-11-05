/** Yinghua's opt-in HLS anomaly policy; Runtime owns analysis, probes and bytes. */
import type { PluginHlsAdFilter } from '@mgread/source-api';

export const hlsAdFilter = Object.freeze({
  algorithm: 'sequence-islands-v1',
  maximumInterstitialSeconds: 90,
  maximumInterstitialSegments: 32,
  minimumContentSegments: 30,
  minimumContentDurationRatio: 0.85,
  minimumFeatureContrast: 0.2,
} satisfies PluginHlsAdFilter);
