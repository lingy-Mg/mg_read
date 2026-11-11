// UTF-8 chapter boundaries, including long Alice chapters; no network or content fixtures.
import assert from 'node:assert/strict';
import test from 'node:test';
import { validateContentResult } from '../dist/plugin-content-validation.js';

const validate = text => validateContentResult('org.example.novel', '测试来源', {
  chapterId: 'chapter:long', contentKind: 'novel', title: null, updatedAt: null, text, pages: [],
});

test('novel text keeps a full long chapter beyond the old 48 KiB limit', () => {
  const text = '正文。'.repeat(10000);
  assert.equal(validate(text).text, text);
});

test('novel budget uses UTF-8 bytes and reports measured size without text', () => {
  const limit = 10 * 1024 * 1024;
  const text = '章'.repeat(Math.floor(limit / 3)) + 'x';
  assert.equal(Buffer.byteLength(text), limit);
  assert.equal(validate(text).text, text);
  assert.throws(() => validate(text + '章'), /text.*10485763 bytes.*10485760-byte limit/u);
  assert.throws(() => validate(42), /text.*string or null/u);
});

test('a complete 10 MiB chapter also fits when JSON needs worst-case escaping', () => {
  const text = '\0'.repeat(10 * 1024 * 1024);
  assert.equal(validate(text).text, text);
});
