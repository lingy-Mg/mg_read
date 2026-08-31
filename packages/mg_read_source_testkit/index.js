/**
 * MgRead 数据源测试库的唯一公开入口。
 *
 * 职责：只重导出测试侧公共 API；实现按契约、宿主、资源和阅读链路拆分在 `src/`。
 */
export {
  SourceTestFailure,
} from './src/diagnostics.js';
export {
  assertInlineJsonSize,
  assertStandardSourceContract,
  loadSourcePackage,
  standardSourceExports,
} from './src/contract.js';
export { createSourceTestHarness } from './src/harness.js';
export { probeReachableResource } from './src/resource.js';
export {
  collectDiscoveryContent,
  collectDiscoveryTargets,
  runReadingSourceFlow,
} from './src/flow.js';
export {
  discoverSourceProjects,
  parseSourceTestArguments,
  runSourceProjects,
} from './src/project-runner.js';
