/**
 * 数据源项目的纯 Node.js 单源/全源驱动。
 *
 * 职责：发现标准来源项目、使用当前 Node 工具链构建、加载 dist 并执行有界 live 链路，最后写紧凑报告。
 */
import { spawn } from 'node:child_process';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { delimiter, dirname, isAbsolute, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { assertStandardSourceContract, loadSourcePackage } from './contract.js';
import { SourceTestFailure, failureFromCause } from './diagnostics.js';
import { collectDiscoveryContent, collectDiscoveryTargets, runReadingSourceFlow } from './flow.js';
import { createSourceTestHarness } from './harness.js';
import { probeReachableResource } from './resource.js';

const maximumBuildOutputCharacters = 2400;
const defaultStageTimeoutMs = 90000;

export function parseSourceTestArguments(arguments_, { cwd = process.cwd() } = {}) {
  let all = false;
  let source = null;
  let reportPath = null;
  let skipBuild = false;
  let repositoryRoot = resolve(cwd);
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === '--all') {
      all = true;
    } else if (argument === '--skip-build') {
      skipBuild = true;
    } else if (argument === '--source') {
      source = requireValue(arguments_, ++index, '--source');
    } else if (argument.startsWith('--source=')) {
      source = requireInlineValue(argument, '--source');
    } else if (argument === '--report') {
      reportPath = resolve(cwd, requireValue(arguments_, ++index, '--report'));
    } else if (argument.startsWith('--report=')) {
      reportPath = resolve(cwd, requireInlineValue(argument, '--report'));
    } else if (argument === '--repository-root') {
      repositoryRoot = resolve(cwd, requireValue(arguments_, ++index, '--repository-root'));
    } else if (argument.startsWith('--repository-root=')) {
      repositoryRoot = resolve(cwd, requireInlineValue(argument, '--repository-root'));
    } else {
      throw new SourceTestFailure('source_cli_argument_unknown', 'cli.arguments', {});
    }
  }
  if (all === (source !== null)) {
    throw new SourceTestFailure('source_cli_selection_invalid', 'cli.arguments', {
      all,
      hasSource: source !== null,
    });
  }
  return Object.freeze({ all, source, repositoryRoot, reportPath, skipBuild });
}

export async function discoverSourceProjects(repositoryRoot) {
  const sourcesRoot = join(repositoryRoot, 'plugins', 'sources');
  let entries;
  try {
    entries = await readdir(sourcesRoot, { withFileTypes: true });
  } catch (error) {
    throw failureFromCause('source_projects_unavailable', 'projects.discover', error);
  }
  const projects = [];
  for (const entry of entries.filter((item) => item.isDirectory()).sort((left, right) => left.name.localeCompare(right.name))) {
    const root = join(sourcesRoot, entry.name);
    const packagePath = join(root, 'package.json');
    try {
      await access(packagePath);
    } catch (_) {
      continue;
    }
    const packageJson = await loadSourcePackage(pathToFileURL(packagePath));
    if (!Array.isArray(packageJson?.mgread?.contentKinds) || packageJson.mgread.contentKinds.length === 0) continue;
    projects.push(Object.freeze({
      directory: entry.name,
      pluginId: packageJson.mgread.id,
      root,
      packageJson,
    }));
  }
  return Object.freeze(projects);
}

export async function runSourceProjects(options) {
  const startedAt = new Date();
  const available = await discoverSourceProjects(options.repositoryRoot);
  const selected = options.all
    ? available
    : available.filter((project) =>
        project.directory === options.source
        || project.pluginId === options.source
        || project.packageJson.name === options.source);
  if (selected.length === 0) {
    throw new SourceTestFailure('source_project_not_found', 'projects.select', {});
  }
  const results = [];
  for (const project of selected) {
    results.push(await runProject(project, options));
  }
  const passed = results.filter((result) => result.status === 'passed').length;
  const report = Object.freeze({
    schemaVersion: 1,
    mode: options.all ? 'all' : 'single',
    status: passed === results.length ? 'passed' : 'failed',
    startedAt: startedAt.toISOString(),
    durationMs: Date.now() - startedAt.getTime(),
    totals: Object.freeze({ sources: results.length, passed, failed: results.length - passed }),
    sources: Object.freeze(results),
  });
  if (options.reportPath !== null) await writeReport(options.reportPath, report);
  return report;
}

async function runProject(project, options) {
  const started = Date.now();
  let harness;
  try {
    if (!options.skipBuild) await runBuild(project);
    const mainPath = resolve(project.root, project.packageJson.main);
    await access(mainPath);
    const plugin = await import(`${pathToFileURL(mainPath).href}?source-test=${Date.now()}`);
    const optionalExports = typeof plugin.searchSuggestions === 'function' ? ['searchSuggestions'] : [];
    assertStandardSourceContract({
      plugin,
      packageJson: project.packageJson,
      pluginId: project.pluginId,
      optionalExports,
      packageMode: project.packageJson.mgread.packageMode,
      icon: project.packageJson.mgread.icon,
    });
    harness = await createSourceTestHarness({
      plugin,
      pluginId: project.pluginId,
      version: project.packageJson.version,
      fetch: globalThis.fetch,
      prefix: 'mgread-source-cli-',
      runtimeVersion: 'source-testkit-cli',
    });
    const acceptance = await readAcceptance(project.root);
    const discovery = await runProjectStage(
      'discover.root',
      () => plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 }),
    );
    let discoveryItems = collectDiscoveryContent(discovery);
    if (discoveryItems.length === 0) {
      for (const target of collectDiscoveryTargets(discovery).slice(0, 6)) {
        const child = await runProjectStage(
          'discover.target',
          () => plugin.discover({ target, cursor: null, collectionId: null, pageSize: 20 }),
        );
        discoveryItems = collectDiscoveryContent(child);
        if (discoveryItems.length > 0) break;
      }
    }
    if (discoveryItems.length === 0) {
      throw new SourceTestFailure('source_discovery_empty', 'discover', {});
    }
    let suggestionItems = [];
    if (typeof plugin.searchSuggestions === 'function') {
      const suggestions = await runProjectStage(
        'searchSuggestions',
        () => plugin.searchSuggestions({ cursor: null, pageSize: 8 }),
      );
      suggestionItems = Array.isArray(suggestions?.items) ? suggestions.items : [];
    }
    const query = discoveryItems.map((item) => nonBlank(item?.title)).find(Boolean)
      ?? suggestionItems.map((item) => nonBlank(item?.query)).find(Boolean)
      ?? nonBlank(acceptance.searchQuery);
    if (query === null) throw new SourceTestFailure('source_search_query_missing', 'search', {});
    const flow = await withTimeout(
      runReadingSourceFlow({
        plugin,
        searchRequest: { query, cursor: null, pageSize: 8 },
      }),
      'flow',
      defaultStageTimeoutMs * 4,
    );
    const resource = await probeFirstReachableResource(harness.resourceRequests);
    return Object.freeze({
      pluginId: project.pluginId,
      source: project.directory,
      version: project.packageJson.version,
      status: 'passed',
      durationMs: Date.now() - started,
      summary: Object.freeze({
        discoveryItems: discoveryItems.length,
        searchItems: flow.summary.searchItems,
        suggestionItems: suggestionItems.length,
        chapterItems: flow.summary.chapterItems,
        contentKind: flow.summary.contentKind,
        contentSamples: flow.summary.contentSamples,
        contentUnits: flow.summary.contentUnits,
        resources: harness.resourceRequests.length,
        resourceStatus: resource.status,
      }),
    });
  } catch (error) {
    const failure = error instanceof SourceTestFailure
      ? error
      : failureFromCause('source_project_failed', 'project', error);
    return Object.freeze({
      pluginId: project.pluginId,
      source: project.directory,
      version: project.packageJson.version,
      status: 'failed',
      durationMs: Date.now() - started,
      failure: failure.toJSON(),
    });
  } finally {
    await harness?.cleanup().catch(() => {});
  }
}

async function runBuild(project) {
  if (typeof project.packageJson?.scripts?.build !== 'string') {
    throw new SourceTestFailure('source_build_script_missing', 'build', {});
  }
  const npmCli = await findBundledNpmCli();
  const result = await spawnBounded(process.execPath, [npmCli, 'run', 'build'], project.root);
  if (result.exitCode !== 0) {
    throw new SourceTestFailure('source_build_failed', 'build', {
      exitCode: result.exitCode,
      outputCharacters: result.output.length,
    });
  }
}

async function findBundledNpmCli() {
  const executableDirectory = dirname(process.execPath);
  const candidates = [
    resolve(executableDirectory, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    resolve(executableDirectory, '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
  ];
  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch (_) {
      // Try the next bundled Node layout.
    }
  }
  throw new SourceTestFailure('source_npm_cli_missing', 'build', {
    executable: process.execPath,
  });
}

async function readAcceptance(projectRoot) {
  try {
    return JSON.parse(await readFile(join(projectRoot, 'test', 'acceptance.json'), 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return Object.freeze({});
    throw failureFromCause('source_acceptance_config_invalid', 'config', error);
  }
}

async function probeFirstReachableResource(requests) {
  if (!Array.isArray(requests) || requests.length === 0) return Object.freeze({ status: 'notRegistered' });
  const groups = [
    { pattern: /image|cover/u, mime: /^image\//u },
    { pattern: /audio/u, mime: /^(audio\/|application\/octet-stream)/u },
    { pattern: /hls|video/u, mime: /^(video\/|application\/|text\/plain)/u },
  ];
  for (const group of groups) {
    const candidates = requests.filter((request) => group.pattern.test(String(request?.kind ?? '')));
    if (candidates.length === 0) continue;
    try {
      const result = await probeReachableResource({
        requests: candidates.map((request) => ({ ...request, kind: 'candidate' })),
        expectedKind: 'candidate',
        expectedContentType: group.mime,
        maximumAttempts: Math.min(candidates.length, 8),
      });
      return Object.freeze({ status: 'reachable', bytesRead: result.bytesRead, contentType: result.contentType });
    } catch (error) {
      if (error instanceof SourceTestFailure) continue;
      throw error;
    }
  }
  return Object.freeze({ status: 'unverified' });
}

function withTimeout(future, stage, timeoutMs = defaultStageTimeoutMs) {
  let timer;
  return Promise.race([
    future,
    new Promise((_, reject) => {
      timer = setTimeout(
        () => reject(new SourceTestFailure('source_stage_timeout', stage, { timeoutMs })),
        timeoutMs,
      );
    }),
  ]).finally(() => clearTimeout(timer));
}

async function runProjectStage(stage, action) {
  try {
    return await withTimeout(Promise.resolve().then(action), stage);
  } catch (error) {
    if (error instanceof SourceTestFailure) throw error;
    throw failureFromCause(`source_${stage.replaceAll('.', '_')}_failed`, stage, error);
  }
}

function spawnBounded(command, arguments_, cwd) {
  return new Promise((resolvePromise, reject) => {
    const executableDirectory = dirname(process.execPath);
    const path = [executableDirectory, process.env.PATH].filter(Boolean).join(delimiter);
    const child = spawn(command, arguments_, {
      cwd,
      env: { ...process.env, PATH: path },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    let output = '';
    const append = (chunk) => {
      if (output.length >= maximumBuildOutputCharacters) return;
      output += chunk.toString('utf8').slice(0, maximumBuildOutputCharacters - output.length);
    };
    child.stdout.on('data', append);
    child.stderr.on('data', append);
    child.once('error', (error) => reject(failureFromCause('source_build_start_failed', 'build', error)));
    child.once('close', (exitCode) => resolvePromise({ exitCode: exitCode ?? -1, output }));
  });
}

async function writeReport(path, report) {
  const resolvedPath = isAbsolute(path) ? path : resolve(path);
  await mkdir(dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
}

function requireValue(arguments_, index, option) {
  const value = arguments_[index];
  if (typeof value !== 'string' || value.length === 0 || value.startsWith('--')) {
    throw new SourceTestFailure('source_cli_value_missing', 'cli.arguments', { option });
  }
  return value;
}

function requireInlineValue(argument, option) {
  const value = argument.slice(option.length + 1);
  if (value.length === 0) throw new SourceTestFailure('source_cli_value_missing', 'cli.arguments', { option });
  return value;
}

function nonBlank(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  return normalized.length === 0 ? null : normalized;
}
