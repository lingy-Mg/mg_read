/** Builds one portable Rust binary, embeds it in a bundled adapter, and packs the standard artifact. */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { build, stop } from 'esbuild';
import { buildPluginArtifactForProject } from '../../aisishuwu/tools/mgread.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
if (!process.argv.includes('--pack')) {
  const cargo = spawnSync('cargo', ['build', '--locked', '--release', '--target', 'wasm32-unknown-unknown'], { cwd: root, stdio: 'inherit' });
  if (cargo.status !== 0) process.exit(cargo.status ?? 1);
  const binary = await readFile(resolve(root, 'target/wasm32-unknown-unknown/release/aisishuwu_wasm.wasm'));
  const hash = createHash('sha256').update(binary).digest('hex');
  await mkdir(resolve(root, 'build'), { recursive: true });
  await mkdir(resolve(root, 'dist'), { recursive: true });
  const entry = `import { createWasmSource } from '@mgread/source-wasm';\nimport { Buffer } from 'node:buffer';\n` +
    `const source=createWasmSource(Buffer.from(${JSON.stringify(binary.toString('base64'))},'base64'));\n` +
    `export const {activate,discover,search,searchSuggestions,getDetail,getChapters,getContent}=source;\n`;
  await writeFile(resolve(root, 'build/entry.mjs'), entry);
  try {
    const output = await build({ absWorkingDir: root, entryPoints: ['build/entry.mjs'], bundle: true, splitting: false,
      platform: 'node', target: 'node24', format: 'esm', minify: true, legalComments: 'none', write: false,
      banner: { js: `// MgRead Rust/Wasm ABI 1; binary sha256=${hash}; bytes=${binary.length}` } });
    if (output.outputFiles.length !== 1) throw new Error('Expected one bundled entry.');
    await writeFile(resolve(root, 'dist/index.mjs.part'), output.outputFiles[0].contents);
    await rename(resolve(root, 'dist/index.mjs.part'), resolve(root, 'dist/index.mjs'));
  } finally { await stop(); }
  await writeFile(resolve(root, 'build/binary.json'), JSON.stringify({ bytes: binary.length, sha256: hash }, null, 2));
}
const artifact = await buildPluginArtifactForProject(root);
await mkdir(resolve(root, 'artifacts'), { recursive: true });
await writeFile(resolve(root, 'artifacts', artifact.fileName), artifact.bytes);
console.log(JSON.stringify({ file: artifact.fileName, bytes: artifact.bytes.length, sha256: createHash('sha256').update(artifact.bytes).digest('hex') }));
