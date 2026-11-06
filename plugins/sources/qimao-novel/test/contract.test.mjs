/** Public export contract and reproducible single-file artifact; no network. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { assertStandardSourceContract, loadSourcePackage } from '@mgread/source-testkit';
import { buildPluginArtifact } from '../tools/mgread.mjs';

test('public novel contract and deterministic standalone artifact', async () => {
  const packageJson = await loadSourcePackage(new URL('../package.json', import.meta.url));
  assertStandardSourceContract({ plugin, packageJson, pluginId: 'org.mgread.qimao-novel', optionalExports: ['searchSuggestions'], packageMode: 'single-file' });
  const first = await buildPluginArtifact();
  const second = await buildPluginArtifact();
  assert.deepEqual(first.bytes, second.bytes);
  assert.equal(first.fileName, 'org.mgread.qimao-novel-1.0.0.mgplugin.js');
});
