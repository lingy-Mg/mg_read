/** Separate-process public-capability comparison. Mock HTTP removes network
 * variance; unique IDs avoid the original source's warm projection cache.
 * Repeated-ID results intentionally include each implementation's cache policy.
 */
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { createSourceTestHarness } from '../../../../packages/mg_read_source_testkit/index.js';
import { fixtureFetch } from '../test/fixtures.mjs';

const mode = process.argv[2];
if (mode === 'js' || mode === 'wasm') {
  const start = performance.now();
  const plugin = await import(mode === 'wasm' ? '../dist/index.mjs' : '../../aisishuwu/dist/index.mjs');
  const importMs = performance.now() - start;
  const harness = await createSourceTestHarness({plugin,pluginId:`org.mgread.benchmark.${mode}`,version:'0.1.0',fetch:fixtureFetch});
  try {
    const cold = performance.now();
    const detail = await plugin.getDetail({id:'novel:1'});
    const coldMs = performance.now() - cold;
    if (detail.wordCount !== 12000 || detail.chapterCount !== 3) throw new Error('Projection differs');
    const unique = performance.now();
    for (let n=2;n<=51;n++) await plugin.getDetail({id:`novel:${n}`});
    const uniqueMeanMs = (performance.now()-unique)/50;
    const repeat = performance.now();
    for (let n=0;n<100;n++) await plugin.getDetail({id:'novel:1'});
    const repeatedMeanMs = (performance.now()-repeat)/100;
    console.log(JSON.stringify({importMs,coldMs,uniqueMeanMs,repeatedMeanMs,rssBytes:process.memoryUsage().rss}));
  } finally { await harness.cleanup(); }
} else {
  const result = {node:process.versions.node,platform:process.platform,arch:process.arch,samples:5,network:'in-memory fixture; no real HTTP',cases:{}};
  for (const variant of ['js','wasm']) {
    const samples=[];
    for (let n=0;n<5;n++) {
      const child=spawnSync(process.execPath,[fileURLToPath(import.meta.url),variant],{encoding:'utf8',timeout:30000});
      if(child.status!==0) throw new Error(child.stderr || child.stdout);
      samples.push(JSON.parse(child.stdout.trim()));
    }
    const median = Object.fromEntries(Object.keys(samples[0]).map(key=>[key,samples.map(s=>s[key]).sort((a,b)=>a-b)[2]]));
    result.cases[variant]={median,samples};
  }
  result.binary=JSON.parse(await readFile(new URL('../build/binary.json',import.meta.url),'utf8'));
  const manifest=JSON.parse(await readFile(new URL('../package.json',import.meta.url),'utf8'));
  result.artifactBytes={
    js:(await stat(new URL('../../aisishuwu/artifacts/org.mgread.aisishuwu-0.2.12.mgplugin.js',import.meta.url))).size,
    wasm:(await stat(new URL(`../artifacts/org.mgread.aisishuwu.wasm-${manifest.version}.mgplugin.js`,import.meta.url))).size,
  };
  await writeFile(new URL('../artifacts/benchmark.json',import.meta.url),JSON.stringify(result,null,2));
  console.log(JSON.stringify({cases:Object.fromEntries(Object.entries(result.cases).map(([k,v])=>[k,v.median])),artifactBytes:result.artifactBytes}));
}
