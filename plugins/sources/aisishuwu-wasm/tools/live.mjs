/** Public testkit live acceptance; emits structural evidence only, never book text. */
import { runSourceProjects } from '../../../../packages/mg_read_source_testkit/index.js';
import { fileURLToPath } from 'node:url';
const repositoryRoot = fileURLToPath(new URL('../../../../', import.meta.url));
const report = await runSourceProjects({ repositoryRoot, source: 'aisishuwu-wasm', all: false, skipBuild: true,
  reportPath: fileURLToPath(new URL('../artifacts/live-report.json', import.meta.url)) });
console.log(JSON.stringify({status:report.status,totals:report.totals,durationMs:report.durationMs}));
process.exitCode = report.status === 'passed' ? 0 : 1;
