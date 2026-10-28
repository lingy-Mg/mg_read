/** Source maintenance metadata survives packaging/restarts and gates discovery without removing cached content. */
import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createPluginSingleFile, parsePluginSingleFile, PluginInstaller, PluginManager, readPluginProject } from '../dist/index.js';
import { parsePluginPackageDescriptor } from '../dist/plugin-package.js';

const fixture = new URL('./fixtures/standard-plugin/', import.meta.url);
test('validates source states and keeps legacy metadata available by default', async () => {
  const pkg = JSON.parse(await readFile(new URL('package.json', fixture), 'utf8'));
  assert.equal(parsePluginPackageDescriptor(pkg, '.').sourceState, undefined);
  for (const state of ['available', 'disabled', 'invalid']) {
    pkg.mgread.sourceState = state;
    assert.equal(parsePluginPackageDescriptor(pkg, '.').sourceState, state);
  }
  for (const value of ['broken', null, true, 1]) {
    pkg.mgread.sourceState = value;
    assert.throws(() => parsePluginPackageDescriptor(pkg, '.'), {code:'plugin_package_invalid'});
  }
  pkg.mgread.sourceState = 'invalid';
  for (const value of ['', ' ', 12, 'x'.repeat(241)]) {
    pkg.mgread.sourceStateReason = value;
    assert.throws(() => parsePluginPackageDescriptor(pkg, '.'), {code:'plugin_package_invalid'});
  }
});

for (const state of ['disabled', 'invalid']) test(`${state} persists through install, enable switch and cold restart; content remains accessible and update recovers`, async t => {
  const root = await mkdtemp(join(tmpdir(), 'mgread-source-state-'));
  t.after(() => rm(root, {recursive:true,force:true}));
  const project = join(root, 'project');
  await cp(fixture, project, {recursive:true});
  const pkg = JSON.parse(await readFile(join(project,'package.json'),'utf8'));
  pkg.mgread.packageMode = 'single-file';
  pkg.mgread.sourceState = state;
  pkg.mgread.sourceStateReason = 'Website playback disabled';
  await writeFile(join(project,'package.json'),JSON.stringify(pkg));
  const id = pkg.mgread.id;
  const artifact = join(root,'source.mgplugin.js');
  await createPluginSingleFile(project,artifact);
  assert.equal((await parsePluginSingleFile(artifact)).descriptor.mgread.sourceState,state);
  const dataRoot = join(root,'runtime');
  await new PluginInstaller(dataRoot).installArtifact(artifact);
  let manager = new PluginManager(dataRoot);
  t.after(() => manager.close());
  await manager.initialize();
  await manager.setEnabled(id,false);
  await manager.setEnabled(id,true);
  await manager.close();
  manager = new PluginManager(dataRoot);
  await manager.initialize();
  const snap = (await manager.listInstalled())[0];
  assert.equal(snap.sourceState,state);
  assert.equal(snap.sourceStateReason,pkg.mgread.sourceStateReason);
  assert.equal(snap.enabled,true);
  const signal = new AbortController().signal;
  const deadline = () => String(Date.now()+10000);
  await assert.rejects(manager.discover(id,{target:null,cursor:null,collectionId:null,pageSize:20},signal,deadline()),{code:'plugin_disabled'});
  await assert.rejects(manager.search(id,{query:'fixture',cursor:null,pageSize:20},signal,deadline()),{code:'plugin_disabled'});
  await assert.rejects(manager.searchSuggestions(id,{cursor:null,pageSize:20},signal,deadline()),{code:'plugin_disabled'});
  const detail = await manager.getDetail(id,{id:'fixture:cached'},signal,deadline());
  assert.equal(detail.id,'fixture:cached');
  const chapters = await manager.getChapters(id,{id:'fixture:cached'},signal,deadline());
  const content = await manager.getContent(id,{id:'fixture:cached',chapterId:chapters.items[0].id},signal,deadline());
  assert.equal(content.contentKind,'novel');
  await manager.close();
  pkg.version = '1.0.1';
  pkg.mgread.sourceState = 'available';
  delete pkg.mgread.sourceStateReason;
  await writeFile(join(project,'package.json'),JSON.stringify(pkg));
  const restoredArtifact = join(root,'restored.mgplugin.js');
  await createPluginSingleFile(project,restoredArtifact);
  await new PluginInstaller(dataRoot).installArtifact(restoredArtifact);
  manager = new PluginManager(dataRoot);
  await manager.initialize();
  assert.equal((await manager.listInstalled())[0].sourceState,'available');
  assert.ok((await manager.search(id,{query:'restored',cursor:null,pageSize:20},signal,deadline())).items.length>0);
});
