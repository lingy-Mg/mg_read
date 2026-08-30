/**
 * 速读谷的静态 Plugin API 与发布元数据契约测试。
 *
 * 职责：固定命名导出、插件 ID、single-file 模式与内嵌图标声明。
 * 注意：不访问来源站点，线上行为由独立 live smoke 覆盖。
 */

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import * as plugin from '../dist/index.mjs';

test('exports standard Plugin API v1 and the Runtime-owned resource handler', async () => {
  assert.deepEqual(Object.keys(plugin).sort(), ['activate', 'discover', 'getChapters', 'getContent', 'getDetail', 'search', 'searchSuggestions']);
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(packageJson.mgread.id, 'org.mgread.shudugu');
  assert.equal(packageJson.main, 'dist/index.mjs');
  assert.equal(packageJson.mgread.packageMode, 'single-file');
  assert.equal(packageJson.mgread.icon, 'assets/icon.png');
});
