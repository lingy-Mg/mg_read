/** Verifies Android staging keeps both host entrypoints and fingerprints only
 * executable assets. The build runs staging before the parallel test suite.
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const runtime = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const assets = resolve(runtime, '../mgread_plugin_runtime/assets/runtime/android');
async function files(root) {
  const entries = await readdir(root, { withFileTypes: true, recursive: true });
  return entries.filter(entry => entry.isFile()).map(entry => resolve(entry.parentPath, entry.name)).sort();
}
test('Android staging retains runtime bytes and omits compiler-only files', async () => {
  const staged = await files(resolve(assets, 'dist'));
  const names = staged.map(file => relative(resolve(assets, 'dist'), file).replaceAll('\\', '/'));
  assert.ok(names.includes('cli.js'), 'Private Node process entry');
  assert.ok(names.includes('desktop-runtime.js'), 'Javet entry');
  assert.ok(names.includes('debug-ui/index.html'));
  assert.equal(names.some(name => /\.(?:map|d\.ts)$/.test(name) || name.startsWith('windows-release/')), false);
  for (let index = 0; index < staged.length; index++) {
    if (names[index] === 'package.json') {
      assert.deepEqual(JSON.parse(await readFile(staged[index], 'utf8')), { type: 'module' });
    } else {
      assert.deepEqual(await readFile(staged[index]), await readFile(resolve(runtime, 'dist', names[index])));
    }
  }
  const expected = (await files(resolve(runtime, 'dist'))).map(file => relative(resolve(runtime, 'dist'), file).replaceAll('\\', '/'))
    .filter(name => !/\.(?:map|d\.ts)$/.test(name) && !name.startsWith('windows-release/'));
  assert.deepEqual([...names].sort(), [...expected, 'package.json'].sort());
  const hash = createHash('sha256');
  for (let index = 0; index < staged.length; index++) hash.update(names[index]).update('\0').update(await readFile(staged[index])).update('\0');
  const metadata = JSON.parse(await readFile(resolve(runtime, 'package.json'), 'utf8'));
  assert.equal(await readFile(resolve(assets, 'runtime-version.txt'), 'utf8'), `${metadata.version}-${hash.digest('hex')}\n`);
});
