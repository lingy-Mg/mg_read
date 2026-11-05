/** Synthetic HLS scenarios and minimal transport headers; no real media payload. */
export const rules = Object.freeze({ algorithm: 'sequence-islands-v1', maximumInterstitialSeconds: 90,
  maximumInterstitialSegments: 32, minimumContentSegments: 30, minimumContentDurationRatio: 0.85, minimumFeatureContrast: 0.2 });

export function transportPrefix(seconds, type = 0x1b) {
  const packet = (pid, payload) => {
    const result = Buffer.alloc(188, 0xff);
    result.set([0x47, 0x40 | (pid >> 8), pid & 255, 0x10]); result.set(payload, 4); return result;
  };
  const ticks = BigInt(Math.round(seconds * 90000)) % (1n << 33n);
  const pts = [0x21 | Number((ticks >> 29n) & 14n), Number((ticks >> 22n) & 255n),
    1 | Number((ticks >> 14n) & 254n), Number((ticks >> 7n) & 255n), 1 | Number((ticks << 1n) & 254n)];
  return Buffer.concat([
    packet(0, [0, 0, 0xb0, 13, 0, 1, 0xc1, 0, 0, 0, 1, 0xf0, 0, 0, 0, 0, 0]),
    packet(0x1000, [0, 2, 0xb0, 18, 0, 1, 0xc1, 0, 0, 0xe1, 0, 0xf0, 0, type, 0xe1, 0, 0xf0, 0, 0, 0, 0, 0]),
    packet(256, [0, 0, 1, 0xe0, 0, 0, 0x80, 0x80, 5, ...pts]),
  ]);
}

export function makeFixture(options = {}) {
  const base = 'https://arbitrary.example/content/season/stream.m3u8';
  const clocks = new Map(), originals = [], inserted = [];
  const count = options.contentCount ?? 58, adCount = options.adCount ?? 3, adDuration = options.adDuration ?? 4;
  const initial = options.initialClock ?? 1.48;
  const lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:8', '#EXT-X-PLAYLIST-TYPE:VOD', '#EXT-X-MEDIA-SEQUENCE:0'];
  for (let index = 0; index < count; index += 1) {
    const numbered = options.sequenceGap && index === 13 ? 15 : index;
    const filename = options.hashed ? (BigInt(index + 1) * 777777777777777777777777n).toString(16).padStart(32, 'a')
      : `clip${String(numbered).padStart(6, '0')}`;
    const uri = filename + '.ts' + (options.signed ? `?token=${index}-different` : '');
    const url = new URL(uri, base).href;
    originals.push(uri); clocks.set(url, { pts: initial + index * 4 + (options.continuousInsert && index >= 13 ? adCount * adDuration : 0), tracks: '256:27' });
    if ((options.positions ?? [13]).includes(index) && adCount > 0) {
      if (options.comment) lines.push('# unrelated custom marker');
      lines.push('#EXT-X-DISCONTINUITY');
      for (let ad = 0; ad < adCount; ad += 1) {
        const uri = options.sameDirectory ? `alternate${String(ad).padStart(6, '0')}.ts`
          : `${options.otherOrigin ? 'https://another.example' : ''}/different/tree/special${String(ad).padStart(20, '0')}.ts`;
        const url = new URL(uri, base).href;
        inserted.push(uri); clocks.set(url, { pts: options.noReset ? initial + 52 : initial + ad * adDuration, tracks: '256:27' });
        lines.push(`#EXTINF:${adDuration},`, uri);
      }
      if (!options.missingBoundary) lines.push('#EXT-X-DISCONTINUITY');
    }
    if (options.normalCuts && index % 5 === 0) lines.push('#EXT-X-DISCONTINUITY');
    lines.push('#EXTINF:4,', uri);
  }
  if (!options.live) lines.push('#EXT-X-ENDLIST');
  if (options.extraTag) lines.splice(2, 0, options.extraTag);
  const text = lines.join(options.crlf ? '\r\n' : '\n') + (options.crlf ? '\r\n' : '\n');
  return { base, text, clocks, originals, inserted, probe: async url => {
    if (options.probeFailure) throw new Error('unavailable');
    const clock = clocks.get(url);
    if (options.unknownClock) return undefined;
    if (options.codecChange && originals[13] && url === new URL(originals[13], base).href) return { ...clock, tracks: '256:36' };
    return clock && { ...clock, pts: clock.pts % (8589934592 / 90000) };
  } };
}
