import assert from 'node:assert/strict'; import test from 'node:test';
test('live probe records the current CF gate without claiming source success', { timeout: 30_000 }, async () => { const response = await fetch('https://xx.knit.bid/'); const body = await response.text(); assert.ok(response.status === 403 || /(?:cf-challenge|Just a moment)/iu.test(body)); });
