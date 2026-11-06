/** Public novel contract and deterministic standalone artifact, without network. */
import assert from 'node:assert/strict';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';
import { assertStandardSourceContract, loadSourcePackage } from '@mgread/source-testkit';
import { buildPluginArtifact } from '../tools/mgread.mjs';
test('public exports and deterministic single-file artifact', async () => {
  const packageJson = await loadSourcePackage(new URL('../package.json', import.meta.url));
  assertStandardSourceContract({ plugin, packageJson, pluginId: 'org.mgread.snxsw-novel', optionalExports: ['searchSuggestions'], packageMode: 'single-file' });
  assert.deepEqual((await buildPluginArtifact()).bytes, (await buildPluginArtifact()).bytes);
});
