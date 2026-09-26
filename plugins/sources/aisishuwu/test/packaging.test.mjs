/**
 * MgRead 发布 artifact 的离线契约测试。
 *
 * 职责：
 * - 验证 single-file 信封、确定性、摘要、图标和版本覆盖。
 * - 验证缺省 single-file、显式 archive 兼容与关键失败门禁。
 *
 * 注意：
 * - 临时 fixture 只使用本地文件，不访问网络或修改插件工作区。
 */

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { inflateRawSync } from 'node:zlib';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const packageJson = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
const tool = await import(new URL(`../${packageJson.bin.mgread}`, import.meta.url));

test('single-file artifact is canonical, deterministic, hashed, and self-contained', async () => {
  const first = await tool.buildPluginArtifact();
  const second = await tool.buildPluginArtifact();
  assert.equal(first.format, 'singleFile');
  assert.equal(first.fileName, `${packageJson.mgread.id}-${packageJson.version}.mgplugin.js`);
  assert.deepEqual(first.bytes, second.bytes);

  const { envelope, canonicalEnvelope, code } = decodeSingleFile(first.bytes);
  assert.equal(canonicalEnvelope, canonicalJson(envelope));
  assert.equal(envelope.formatVersion, 1);
  assert.equal(envelope.descriptor.name, packageJson.name);
  assert.equal(envelope.descriptor.version, packageJson.version);
  assert.equal(envelope.descriptor.type, 'module');
  assert.equal(envelope.descriptor.main, 'dist/index.mjs');
  assert.equal(envelope.descriptor.engines.node, '>=24');
  assert.equal(envelope.descriptor.mgread.packageMode, 'single-file');
  assert.equal(envelope.codeBytes, code.length);
  assert.equal(envelope.codeSha256, sha256(code));
  assert.equal(first.bytes.subarray(0, 2).toString(), '//');
  assert.notEqual(first.bytes.subarray(0, 2).toString(), 'PK');
  assert.equal(code.includes(Buffer.from('sourceMappingURL=')), false);

  if (packageJson.mgread.icon !== undefined) {
    const icon = await readFile(resolve(root, packageJson.mgread.icon));
    assert.equal(envelope.descriptor.mgread.icon, packageJson.mgread.icon);
    assert.equal(envelope.icon.mediaType, 'image/png');
    assert.equal(envelope.icon.bytes, icon.length);
    assert.equal(envelope.icon.sha256, sha256(icon));
    assert.deepEqual(Buffer.from(envelope.icon.data, 'base64'), icon);
  } else {
    assert.equal(envelope.icon, undefined);
  }

  const overridden = await tool.buildPluginArtifact({ versionOverride: '9.8.7-devsync.1' });
  assert.equal(overridden.fileName, `${packageJson.mgread.id}-9.8.7-devsync.1.mgplugin.js`);
  assert.equal(decodeSingleFile(overridden.bytes).envelope.descriptor.version, '9.8.7-devsync.1');
});

test('packageMode defaults to single-file and archive remains explicit', async (t) => {
  const defaultRoot = await createFixture(t, {});
  const single = await tool.buildPluginArtifactForProject(defaultRoot);
  assert.equal(single.format, 'singleFile');
  assert.equal(single.fileName, 'org.example.fixture-1.2.3.mgplugin.js');

  const archiveRoot = await createFixture(t, { packageMode: 'archive' });
  const first = await tool.buildPluginArtifactForProject(archiveRoot);
  const second = await tool.buildPluginArtifactForProject(archiveRoot);
  assert.equal(first.format, 'archive');
  assert.equal(first.fileName, 'org.example.fixture-1.2.3.mgplugin');
  assert.equal(first.bytes.subarray(0, 2).toString(), 'PK');
  assert.deepEqual(first.bytes, second.bytes);
  assert.deepEqual(listZipEntries(first.bytes), ['dist/index.mjs', 'package.json']);
  assert.equal(listZipEntries(first.bytes).some((name) => name === 'package-lock.json' || name.startsWith('node_modules/')), false);
  const overridden = await tool.buildPluginArtifactForProject(archiveRoot, {
    versionOverride: '1.2.4-devsync.1',
  });
  assert.equal(JSON.parse(readZipEntry(overridden.bytes, 'package.json')).version, '1.2.4-devsync.1');
  assert.deepEqual(listZipEntries(overridden.bytes), ['dist/index.mjs', 'package.json']);
});

test('single-file rejects sidecars and oversized icons, while preserving unresolved source code', async (t) => {
  const sidecarRoot = await createFixture(t, {});
  await mkdir(resolve(sidecarRoot, 'assets'));
  await writeFile(resolve(sidecarRoot, 'assets/rules.txt'), 'sidecar');
  await assert.rejects(
    tool.buildPluginArtifactForProject(sidecarRoot),
    /does not publish sidecar resources/,
  );

  const externalRoot = await createFixture(t, {});
  const externalCode = "export { value } from 'missing-package';\n";
  await writeFile(resolve(externalRoot, 'dist/index.mjs'), externalCode);
  const externalArtifact = await tool.buildPluginArtifactForProject(externalRoot);
  assert.equal(decodeSingleFile(externalArtifact.bytes).code.toString(), externalCode);

  const dynamicRoot = await createFixture(t, {});
  const dynamicCode = 'export const load = (name) => import(name);\n';
  await writeFile(resolve(dynamicRoot, 'dist/index.mjs'), dynamicCode);
  const dynamicArtifact = await tool.buildPluginArtifactForProject(dynamicRoot);
  assert.equal(decodeSingleFile(dynamicArtifact.bytes).code.toString(), dynamicCode);

  const iconRoot = await createFixture(t, { icon: 'assets/icon.png' });
  await mkdir(resolve(iconRoot, 'assets'));
  const oversized = Buffer.alloc(256 * 1024 + 1);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(oversized);
  await writeFile(resolve(iconRoot, 'assets/icon.png'), oversized);
  await assert.rejects(tool.buildPluginArtifactForProject(iconRoot), /icon exceeds/i);
});

async function createFixture(t, mgreadOverrides) {
  const fixtureRoot = await mkdtemp(join(tmpdir(), 'mgread-pack-test-'));
  t.after(() => rm(fixtureRoot, { force: true, recursive: true }));
  await mkdir(resolve(fixtureRoot, 'dist'), { recursive: true });
  await writeFile(resolve(fixtureRoot, 'dist/index.mjs'), 'export const value = 1;\n');
  const fixturePackage = {
    name: '@mgread-plugin/fixture',
    version: '1.2.3',
    type: 'module',
    main: 'dist/index.mjs',
    engines: { node: '24.16.0 || 24.21.0 || 26.9.0 || 26.10.0' },
    mgread: {
      schemaVersion: 1,
      id: 'org.example.fixture',
      displayName: 'Fixture',
      pluginApi: 1,
      contentKinds: ['novel'],
      ...mgreadOverrides,
    },
  };
  await writeFile(resolve(fixtureRoot, 'package.json'), `${JSON.stringify(fixturePackage, null, 2)}\n`);
  await writeFile(
    resolve(fixtureRoot, 'package-lock.json'),
    `${JSON.stringify({ name: fixturePackage.name, version: fixturePackage.version, lockfileVersion: 3, requires: true, packages: { '': { name: fixturePackage.name, version: fixturePackage.version } } }, null, 2)}\n`,
  );
  await mkdir(resolve(fixtureRoot, 'node_modules/example-package'), { recursive: true });
  await writeFile(resolve(fixtureRoot, 'node_modules/example-package/index.js'), 'fixture dependency\n');
  await writeFile(resolve(fixtureRoot, 'README.md'), '# Fixture\n');
  await writeFile(resolve(fixtureRoot, 'LICENSE'), 'MIT\n');
  return fixtureRoot;
}

function decodeSingleFile(bytes) {
  const newline = bytes.indexOf(10);
  assert.ok(newline > 0 && newline < 512 * 1024);
  const line = bytes.subarray(0, newline).toString('utf8');
  const prefix = '// @mgread-plugin-v1 ';
  assert.ok(line.startsWith(prefix));
  const canonicalEnvelope = Buffer.from(line.slice(prefix.length), 'base64url').toString('utf8');
  return {
    envelope: JSON.parse(canonicalEnvelope),
    canonicalEnvelope,
    code: bytes.subarray(newline + 1),
  };
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function readZipEntry(bytes, expectedName) {
  let offset = 0;
  while (bytes.readUInt32LE(offset) === 0x04034b50) {
    const method = bytes.readUInt16LE(offset + 8);
    const compressedSize = bytes.readUInt32LE(offset + 18);
    const nameSize = bytes.readUInt16LE(offset + 26);
    const extraSize = bytes.readUInt16LE(offset + 28);
    const bodyOffset = offset + 30 + nameSize + extraSize;
    const name = bytes.subarray(offset + 30, offset + 30 + nameSize).toString('utf8');
    if (name === expectedName) {
      const body = bytes.subarray(bodyOffset, bodyOffset + compressedSize);
      return (method === 8 ? inflateRawSync(body) : body).toString('utf8');
    }
    offset = bodyOffset + compressedSize;
  }
  throw new Error(`ZIP entry is missing: ${expectedName}`);
}

function listZipEntries(bytes) {
  const names = [];
  let offset = 0;
  while (offset + 4 <= bytes.length && bytes.readUInt32LE(offset) === 0x04034b50) {
    const compressedSize = bytes.readUInt32LE(offset + 18);
    const nameSize = bytes.readUInt16LE(offset + 26);
    const extraSize = bytes.readUInt16LE(offset + 28);
    names.push(bytes.subarray(offset + 30, offset + 30 + nameSize).toString('utf8'));
    offset += 30 + nameSize + extraSize + compressedSize;
  }
  return names;
}
