/** Runs the compiled binary through the public host API and real Runtime validators. */
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createWasmSource } from '../../../../packages/mg_read_source_wasm/index.mjs';
import { createSourceTestHarness, assertStandardSourceContract } from '../../../../packages/mg_read_source_testkit/index.js';
import { PluginInstaller, PluginManager } from '../../../../packages/mg_read_node_runtime/dist/index.js';
import { validateDetailResult, validateDiscoverResult, validateSearchResult, validateChaptersResult, validateContentResult } from '../../../../packages/mg_read_node_runtime/dist/plugin-content.js';
import { buildPluginArtifactForProject } from '../../aisishuwu/tools/mgread.mjs';
import { id, fixtureFetch, chapterId } from './fixtures.mjs';

const root = new URL('../', import.meta.url);
const binary = await readFile(new URL('../target/wasm32-unknown-unknown/release/aisishuwu_wasm.wasm', import.meta.url));
async function setup(t, fetch = fixtureFetch) {
  const plugin = createWasmSource(binary);
  const harness = await createSourceTestHarness({ plugin, pluginId: id, version: '0.1.0', fetch });
  t.after(async () => { await plugin.deactivate(); await harness.cleanup(); });
  return { plugin, harness };
}
test('binary implements all public capabilities and projects valid host results', async (t) => {
  const { plugin, harness } = await setup(t);
  assertStandardSourceContract({ plugin, packageJson: JSON.parse(await readFile(new URL('package.json',root),'utf8')), pluginId: id, optionalExports:['searchSuggestions','deactivate'] });
  const detail = await plugin.getDetail({ id: 'novel:1' });
  validateDetailResult(id, 'Rust/Wasm', detail);
  assert.equal(detail.wordCount,12000);
  assert.equal(detail.chapterCount,3);
  assert.equal(detail.author,'测试作者');
  assert.equal(detail.status,'ongoing');
  assert.match(detail.coverUrl,/127\.0\.0\.1/);
  assert.equal(harness.resourceRequests[0].url,'https://img.321cdn.com/cover.jpg');
  const search = await plugin.search({query:'测试',cursor:null,pageSize:2});
  validateSearchResult(id, 'Rust/Wasm', search);
  assert.equal(search.items.length,2);
  assert.equal(search.nextCursor,'search-page:2');
  const home = await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:2});
  validateDiscoverResult(id, 'Rust/Wasm', home);
  const append = await plugin.discover({target:'category:71',cursor:'category-page:1',collectionId:'category-books:71',pageSize:2});
  validateDiscoverResult(id, 'Rust/Wasm', append);
  assert.equal(append.kind,'append');
  const chapters = await plugin.getChapters({id:'novel:1'});
  validateChaptersResult(id, 'Rust/Wasm', chapters);
  assert.deepEqual(chapters.items.map(c=>c.id),[1,2,3].map(chapterId));
  assert.deepEqual(chapters.items.map(c=>c.order),[0,1,2]);
  const content = await plugin.getContent({id:'novel:1',chapterId:chapterId(3)});
  validateContentResult(id, 'Rust/Wasm', content);
  assert.equal(content.text,'第一段。\n\n第二段。');
  assert.equal(harness.logEvents.filter(e=>e.event==='source_wasm_ready_abi1').length,1);
});
test('concurrent calls retain separate request state', async (t) => {
  const {plugin} = await setup(t);
  const details = await Promise.all(Array.from({length:12},(_,n)=>plugin.getDetail({id:`novel:${n+1}`})));
  assert.deepEqual(details.map(d=>d.id),Array.from({length:12},(_,n)=>`novel:${n+1}`));
});
test('blocks invalid identities before IO and preserves public block-page errors', async (t) => {
  let requests = 0;
  const {plugin} = await setup(t, async ()=>{ requests++; return new Response('访问异常，请稍后再试'); });
  await assert.rejects(plugin.getDetail({id:'novel:../x'}));
  await assert.rejects(plugin.getContent({id:'novel:1',chapterId:`chapter:${Buffer.from('https://elsewhere.invalid/').toString('base64url')}`}));
  assert.equal(requests,0);
  await assert.rejects(plugin.getDetail({id:'novel:1'}),{code:'source_access_blocked'});
});
test('rejects truncated and looping catalogs instead of reporting a short catalog', async (t) => {
  const {plugin} = await setup(t, async ()=>new Response('<div class="catalog_title">全3章</div><a href="/book/1/1.html">一</a>'));
  await assert.rejects(plugin.getChapters({id:'novel:1'}));
});
test('host stops oversized HTML and rejects calls after deactivation', async (t) => {
  const {plugin} = await setup(t, async ()=>new Response('x'.repeat(4*1024*1024+1)));
  await assert.rejects(plugin.getDetail({id:'novel:1'}),/body_limit/);
  await plugin.deactivate();
  await assert.rejects(plugin.getDetail({id:'novel:1'}),/not_active/);
});
test('deactivation aborts a live pending HTTP operation', async (t) => {
  let started;
  const ready = new Promise((resolve) => { started = resolve; });
  const {plugin} = await setup(t, (_input, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener('abort', () => reject(new Error('test_request_aborted')), {once:true});
    started();
  }));
  const pending = plugin.getDetail({id:'novel:1'});
  const rejected = assert.rejects(pending,/test_request_aborted/);
  await ready;
  await plugin.deactivate();
  await rejected;
});
test('the built binary has no imports and enforces its 64 MiB linear memory ceiling', async () => {
  const module = await WebAssembly.compile(binary);
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const {memory, abi_version: version} = new WebAssembly.Instance(module, {}).exports;
  assert.equal(version(), 1);
  memory.grow(1024 - memory.buffer.byteLength / 65536);
  assert.equal(memory.buffer.byteLength, 64 * 1024 * 1024);
  assert.throws(() => memory.grow(1), RangeError);
});
test('artifact is deterministic, self contained and cold installs in the real Runtime', async (t) => {
  const first = await buildPluginArtifactForProject(fileURLToPath(root));
  const second = await buildPluginArtifactForProject(fileURLToPath(root));
  assert.deepEqual(first.bytes,second.bytes);
  const data = await mkdtemp(join(tmpdir(),'mgread-wasm-install-'));
  t.after(()=>rm(data,{recursive:true,force:true}));
  const artifact = new URL(`../artifacts/${first.fileName}`,import.meta.url);
  const installed = await new PluginInstaller(data).installArtifact(fileURLToPath(artifact));
  assert.equal(installed.pendingActivation,true);
  const manager = new PluginManager(data);
  t.after(()=>manager.close());
  await manager.initialize();
  const items = await manager.listInstalled();
  assert.equal(items[0].status,'active');
  // The public empty second suggestions page still executes the binary after cold activation.
  const suggestions = await manager.searchSuggestions(id,{cursor:'search-suggestions-page:2',pageSize:5},new AbortController().signal,String(Date.now()+10000));
  assert.deepEqual(suggestions.items,[]);
});
