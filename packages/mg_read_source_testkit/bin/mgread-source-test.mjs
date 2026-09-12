#!/usr/bin/env node
/** 纯 Node.js 数据源开发检查入口；控制台只输出每源一行与最终报告。 */
import { relative } from 'node:path';

import {
  SourceTestFailure,
  parseSourceTestArguments,
  runSourceProjects,
} from '../index.js';

try {
  const options = parseSourceTestArguments(process.argv.slice(2));
  const report = await runSourceProjects(options);
  for (const source of report.sources) {
    const status = source.status === 'passed' ? 'PASS' : source.status === 'partial' ? 'PARTIAL' : 'FAIL';
    const detail = source.status === 'passed'
      ? `chapters=${source.summary.chapterItems} samples=${source.summary.contentSamples} ${formatResourceGroups(source.summary.resourceGroups)}`
      : source.status === 'partial'
        ? `chapters=${source.summary.chapterItems} samples=${source.summary.contentSamples} ${formatResourceGroups(source.summary.resourceGroups)}`
      : `${source.failure.stage} ${source.failure.code}${source.summary?.resourceGroups ? ` ${formatResourceGroups(source.summary.resourceGroups)}` : ''}`;
    process.stdout.write(`${status} ${source.source} ${detail} ${source.durationMs}ms\n`);
  }
  if (options.reportPath !== null) {
    process.stdout.write(`REPORT ${relative(process.cwd(), options.reportPath)}\n`);
  }
  process.exitCode = report.status === 'passed' ? 0 : 1;
} catch (error) {
  const failure = error instanceof SourceTestFailure
    ? error
    : new SourceTestFailure('source_cli_failed', 'cli', {});
  process.stderr.write(`FAIL cli ${failure.stage} ${failure.code}\n`);
  process.exitCode = 2;
}

function formatResourceGroups(groups) {
  if (groups === null || typeof groups !== 'object') return 'resources=unknown';
  return `resources=${Object.entries(groups)
    .map(([name, value]) => `${name}:${value?.status ?? 'unknown'}`)
    .join(',')}`;
}
