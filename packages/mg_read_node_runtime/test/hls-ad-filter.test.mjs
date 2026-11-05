/** Structural/histogram simulations, false-positive controls and clock parsing. */
import assert from 'node:assert/strict';
import test from 'node:test';
import { filterHlsAdManifest } from '../dist/hls-ad-filter.js';
import { analyzeHlsAdIslands, readHlsAdFilter } from '../dist/hls-ad-analysis.js';
import { readTransportClock, transportClockDelta } from '../dist/hls-transport-clock.js';
import { makeFixture, rules, transportPrefix } from './helpers/hls-ad-fixtures.mjs';

export const scenarios = [
  ['unmarked insertion with arbitrary names and paths', {}, 3],
  ['a marker is irrelevant to classification', { comment: true }, 3],
  ['signed segment queries differ on every original', { signed: true }, 3],
  ['hashed originals with transport-clock evidence', { hashed: true }, 3],
  ['foreign origin, resumed original content', { otherOrigin: true }, 3],
  ['CRLF manifest', { crlf: true }, 3],
  ['33-bit clock wrap at the join', { initialClock: 8589934592 / 90000 - 50 }, 3],
  ['two independent foreign islands', { positions: [13, 33] }, 6],
  ['a foreign intro has no two-sided evidence', { positions: [0] }, 0],
  ['normal manifest without insertions', { adCount: 0 }, 0],
  ['ordinary discontinuities every five segments', { adCount: 0, normalCuts: true }, 0],
  ['a legitimate inserted scene advances the content clock', { continuousInsert: true }, 0],
  ['a very short legitimate transition still advances the clock', { continuousInsert: true, adDuration: 0.04 }, 0],
  ['nonconsecutive content sequence', { sequenceGap: true }, 0],
  ['same directory with insufficient feature contrast', { sameDirectory: true }, 0],
  ['no timestamp reset at candidate entry', { noReset: true }, 0],
  ['missing return boundary', { missingBoundary: true }, 0],
  ['live playlist', { live: true }, 0],
  ['encrypted playlist with implicit sequence IV', { extraTag: '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"' }, 0],
  ['byte-range state', { extraTag: '#EXT-X-BYTERANGE:1000' }, 0],
  ['initialization map state', { extraTag: '#EXT-X-MAP:URI="init.mp4"' }, 0],
  ['wall-clock timeline metadata', { extraTag: '#EXT-X-PROGRAM-DATE-TIME:2026-11-05T00:00:00Z' }, 0],
  ['unknown future HLS tag', { extraTag: '#EXT-X-UNKNOWN:1' }, 0],
  ['probe fails', { probeFailure: true }, 0],
  ['transport clock cannot be identified', { unknownClock: true }, 0],
  ['original stream changes codec after the island', { codecChange: true }, 0],
  ['short movie without sufficient baseline', { contentCount: 20 }, 0],
  ['too many foreign segments', { adCount: 33, adDuration: 1 }, 0],
  ['long foreign interval', { adCount: 24, adDuration: 4 }, 0],
];

for (const [name, options, expected] of scenarios) test(name, async () => {
  const fixture = makeFixture(options);
  const result = await filterHlsAdManifest(fixture.text, fixture.base, rules, fixture.probe);
  assert.equal(result.removedSegments, expected);
  for (const original of fixture.originals) assert.ok(result.text.includes(original), `Lost original ${original}`);
  if (expected === 0) assert.equal(result.text, fixture.text, 'A protected scenario must remain byte-for-byte unchanged');
  else {
    for (const inserted of fixture.inserted) assert.ok(!result.text.includes(inserted));
    const analysis = analyzeHlsAdIslands(fixture.text, fixture.base, rules);
    assert.equal(analysis.histogram.reduce((sum, count) => sum + count, 0), fixture.originals.length + fixture.inserted.length);
    assert.ok(analysis.candidates.length > 0);
  }
});

test('invalid policies and absent opt-in do not probe or filter', async () => {
  const fixture = makeFixture();
  for (const policy of [undefined, {}, { ...rules, algorithm: 'other' }, { ...rules, maximumInterstitialSegments: 1000 },
    { ...rules, minimumFeatureContrast: NaN }, { ...rules, minimumContentDurationRatio: 0.01 }]) {
    assert.equal(readHlsAdFilter(policy), undefined);
    const result = await filterHlsAdManifest(fixture.text, fixture.base, policy, () => assert.fail('Must not probe'));
    assert.equal(result.text, fixture.text);
  }
});

test('reads a video clock from bounded PAT/PMT/PES transport headers', () => {
  assert.deepEqual(readTransportClock(transportPrefix(1.48)), { pts: 1.48, tracks: '256:27' });
  assert.deepEqual(readTransportClock(transportPrefix(302.0986)), { pts: 302.0986, tracks: '256:27' });
  assert.equal(readTransportClock(new Uint8Array(188)), undefined);
  assert.equal(readTransportClock(Buffer.from('<html>not media</html>')), undefined);
  assert.ok(Math.abs(transportClockDelta(2, 8589934592 / 90000 - 2) - 4) < 1e-8);
});
