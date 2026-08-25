/** Synchronizes the vendored generic cache package into supported source plugins. */
import { cp, readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = resolve(repositoryRoot, 'packages', 'mg_read_plugin_cache');
const requestedSourceId = process.argv[2];
const sourceIds = requestedSourceId === undefined
  ? ['aisishuwu', 'shudugu']
  : [requestedSourceId];
const checkOnly = process.argv[3] === '--check';

for (const sourceId of sourceIds) {
  if (!/^[a-z0-9-]+$/u.test(sourceId)) throw new Error('Source ID is invalid.');
  const target = resolve(repositoryRoot, 'plugins', 'sources', sourceId, 'packages', 'mgread-plugin-cache');
  for (const name of ['package.json', 'index.d.ts', 'index.js']) {
    const sourcePath = resolve(source, name);
    const targetPath = resolve(target, name);
    if (checkOnly) {
      if ((await readFile(sourcePath, 'utf8')) !== (await readFile(targetPath, 'utf8'))) {
        throw new Error(`Vendored cache package is stale for ${sourceId}.`);
      }
    } else {
      await cp(sourcePath, targetPath);
    }
  }
}
