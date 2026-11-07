/** Load the production Runtime validators for offline and live source checks. */
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

export async function loadRuntimeValidators() {
  const runtimeRoot = fileURLToPath(new URL('../../../../packages/mg_read_node_runtime/', import.meta.url));
  const result = await build({
    bundle: true, format: 'esm', logLevel: 'silent', platform: 'node',
    stdin: {
      contents: [
        "export { validateDiscoverResult } from './src/plugin-content-discovery.ts';",
        "export { validateSearchResult, validateDetailResult, validateChaptersResult, validateContentResult } from './src/plugin-content-validation.ts';",
      ].join('\n'),
      loader: 'ts', resolveDir: runtimeRoot, sourcefile: 'yinghua-runtime-contract-entry.mts',
    },
    target: 'node24', write: false,
  });
  const source = result.outputFiles[0]?.text;
  assert.ok(source);
  return import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
}
