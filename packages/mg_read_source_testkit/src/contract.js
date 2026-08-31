/**
 * 数据源静态契约与 inline 结果大小断言。
 *
 * 职责：验证 Plugin API v1 导出、package 元数据和控制面 JSON 大小；不加载 Runtime 私有实现。
 */
import { readFile } from 'node:fs/promises';

import { SourceTestFailure, failureFromCause } from './diagnostics.js';

export const standardSourceExports = Object.freeze([
  'activate',
  'discover',
  'getChapters',
  'getContent',
  'getDetail',
  'search',
]);

export async function loadSourcePackage(packageJsonUrl) {
  try {
    return JSON.parse(await readFile(packageJsonUrl, 'utf8'));
  } catch (error) {
    throw failureFromCause('source_package_invalid', 'contract.package', error);
  }
}

export function assertStandardSourceContract({
  plugin,
  packageJson,
  pluginId,
  optionalExports = [],
  packageMode = 'single-file',
  icon,
}) {
  const expectedExports = [...standardSourceExports, ...optionalExports].sort();
  const actualExports = plugin === null || typeof plugin !== 'object'
    ? []
    : Object.keys(plugin).sort();
  if (!sameStrings(actualExports, expectedExports)) {
    throw new SourceTestFailure('source_contract_exports', 'contract.exports', {
      expected: expectedExports,
      actual: actualExports,
    });
  }
  for (const exportName of expectedExports) {
    if (typeof plugin[exportName] !== 'function') {
      throw new SourceTestFailure('source_contract_export_type', 'contract.exports', {
        exportName,
        actualType: typeof plugin[exportName],
      });
    }
  }

  const metadata = packageJson?.mgread;
  const actual = {
    id: metadata?.id ?? null,
    pluginApi: metadata?.pluginApi ?? null,
    packageMode: metadata?.packageMode ?? null,
    icon: metadata?.icon ?? null,
    main: packageJson?.main ?? null,
  };
  const expected = {
    id: pluginId,
    pluginApi: 1,
    packageMode,
    icon: icon === undefined ? actual.icon : icon,
    main: 'dist/index.mjs',
  };
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new SourceTestFailure('source_contract_metadata', 'contract.metadata', {
      expected,
      actual,
    });
  }
  return Object.freeze({
    exports: Object.freeze(expectedExports),
    metadata: Object.freeze(actual),
  });
}

export function assertInlineJsonSize(value, { maximumBytes, stage = 'inline-result' }) {
  const actualBytes = Buffer.byteLength(JSON.stringify(value), 'utf8');
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    throw new SourceTestFailure('source_inline_limit_invalid', stage, {});
  }
  if (actualBytes > maximumBytes) {
    throw new SourceTestFailure('source_inline_result_oversized', stage, {
      actualBytes,
      maximumBytes,
    });
  }
  return actualBytes;
}

function sameStrings(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}
