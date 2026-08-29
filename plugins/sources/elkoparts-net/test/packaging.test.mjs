/** Deterministic single-file artifact smoke; no network access. */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { buildPluginArtifact } from '../tools/mgread.mjs';

test('builds a deterministic, hashed, self-contained single-file artifact', async () => {
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.equal(first.format, 'singleFile');
  assert.equal(first.fileName, `${packageJson.mgread.id}-${packageJson.version}.mgplugin.js`);
  assert.deepEqual(first.bytes, second.bytes);
  const newline = first.bytes.indexOf(10);
  const prefix = '// @mgread-plugin-v1 ';
  const line = first.bytes.subarray(0, newline).toString('utf8');
  assert.ok(line.startsWith(prefix));
  const envelope = JSON.parse(Buffer.from(line.slice(prefix.length), 'base64url').toString('utf8'));
  const code = first.bytes.subarray(newline + 1);
  assert.equal(envelope.descriptor.mgread.id, 'org.mgread.elkoparts-net');
  assert.equal(envelope.descriptor.mgread.packageMode, 'single-file');
  assert.equal(envelope.codeBytes, code.length);
  assert.equal(envelope.codeSha256, createHash('sha256').update(code).digest('hex'));
  assert.equal(code.includes(Buffer.from('sourceMappingURL=')), false);
});

