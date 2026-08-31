/**
 * 爱丽丝书屋的静态 Plugin API 与发布元数据契约测试。
 *
 * 职责：固定命名导出、插件 ID、single-file 模式与内嵌图标声明。
 * 注意：不访问来源站点，线上行为由独立 live smoke 覆盖。
 */

import test from 'node:test';

import {
  assertStandardSourceContract,
  loadSourcePackage,
} from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';

test('exports the standard Plugin API v1 entry points and hot-search extension', async () => {
  assertStandardSourceContract({
    plugin,
    packageJson: await loadSourcePackage(new URL('../package.json', import.meta.url)),
    pluginId: 'org.mgread.aisishuwu',
    optionalExports: ['searchSuggestions'],
  });
});
