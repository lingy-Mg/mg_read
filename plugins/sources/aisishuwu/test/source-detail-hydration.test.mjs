import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';

import { hydrateDetailsInOrder } from '../dist/source-detail-hydration.js';

test('hydrates in original order without exceeding the configured concurrency', async () => {
  const items = Array.from({ length: 20 }, (_, index) => index + 1);
  let active = 0;
  let maximumActive = 0;
  const result = await hydrateDetailsInOrder(items, {
    maximumConcurrency: 8,
    hydrate: async (item) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await delay(item % 3 === 0 ? 4 : 2);
      active -= 1;
      return item * 10;
    },
    onFailure: (item) => item,
  });

  assert.equal(maximumActive, 8);
  assert.deepEqual(result, items.map((item) => item * 10));
  assert.ok(Object.isFrozen(result));
});

test('returns a stable fallback snapshot when the deadline wins', async () => {
  const items = [1, 2, 3, 4];
  let started = 0;
  const result = await hydrateDetailsInOrder(items, {
    maximumConcurrency: 2,
    deadlineMs: Date.now() + 10,
    hydrate: async (item) => {
      started += 1;
      await delay(40);
      return item * 10;
    },
    onFailure: (item) => item,
  });

  assert.deepEqual(result, items);
  assert.equal(started, 2);
  await delay(50);
  assert.deepEqual(result, items);
});
