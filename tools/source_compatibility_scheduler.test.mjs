/** Verifies the source concurrency budget, completion order and error drain. */
import assert from 'node:assert/strict';
import test from 'node:test';
import { mapSources } from './source_compatibility_scheduler.mjs';

test('bounds active sources and preserves results when sources finish out of order', async () => {
  let active = 0;
  let maximum = 0;
  let releaseFirst;
  const firstGate = new Promise(resolve => { releaseFirst = resolve; });
  const starts = [];
  const finishes = [];
  const results = await mapSources([0, 1, 2, 3], 2, async value => {
    starts.push(value);
    active += 1;
    maximum = Math.max(maximum, active);
    if (value === 0) await firstGate;
    if (value === 2) releaseFirst();
    finishes.push(value);
    active -= 1;
    return value * 2;
  });
  assert.equal(maximum, 2);
  assert.deepEqual(starts, [0, 1, 2, 3]);
  assert.equal(finishes[0], 1);
  assert.deepEqual(results, [0, 2, 4, 6]);
  assert.equal(active, 0);
});

test('unexpected failure still drains all sources before rejecting', async () => {
  const finished = [];
  await assert.rejects(mapSources([0, 1, 2], 2, async value => {
    await Promise.resolve();
    finished.push(value);
    if (value === 1) throw new Error('fixture failure');
  }), error => error instanceof AggregateError && error.errors[0].message === 'fixture failure');
  assert.deepEqual([...finished].sort(), [0, 1, 2]);
});

test('invalid limits fail before running work; an empty input completes', async () => {
  for (const limit of [0, 9, 1.5, NaN]) {
    await assert.rejects(mapSources([1], limit, () => assert.fail('must not start')), RangeError);
  }
  assert.deepEqual(await mapSources([], 2, () => assert.fail('empty input')), []);
});
