/** Checks declared offline source tests on pinned desktop runtimes.
 * Builds with the existing fixed Node/npm toolchain, then runs the same files
 * on Node and/or Bun. Keeps every source's result, including failures, in an
 * ignored report directory. Bounded concurrency isolates work by source; each
 * source's commands remain serial and report writes are serialized separately.
 * Never invokes test:live or edits package locks.
 */
import { spawn } from 'node:child_process';
import { mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mapSources } from './source_compatibility_scheduler.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const options = new Map(process.argv.slice(2).map(arg => {
  const [key, ...value] = arg.split('='); return [key, value.join('=') || true];
}));
for (const key of options.keys()) if (!['--engine', '--source', '--skip-build', '--install-dependencies', '--report', '--concurrency'].includes(key)) throw Error(`Unknown option: ${key}`);
const concurrencyValue = options.get('--concurrency') ?? '1';
if (!/^[1-8]$/.test(String(concurrencyValue))) throw Error('concurrency must be an integer from 1 to 8');
const concurrency = Number(concurrencyValue);
const engines = options.get('--engine') ?? 'both';
if (!['node', 'bun', 'both'].includes(engines)) throw Error('engine must be node, bun or both');
if (process.platform !== 'win32') throw Error('This verification runner currently targets Windows x64.');
const runtime = resolve(root, 'packages/mg_read_node_runtime');
const nodeDir = resolve(runtime, 'tools/node-v26.10.0-win-x64');
const executables = { node: resolve(nodeDir, 'node.exe'), bun: resolve(runtime, 'tools/bun-v1.4.4-windows-x64/bun.exe') };
const reportRoot = resolve(root, options.get('--report') ?? 'artifacts/source-runtime-compatibility');
await mkdir(reportRoot, { recursive: true });
const sourceRoot = resolve(root, 'plugins/sources');
const rows = [];
const started = Date.now();
let reportWrites = Promise.resolve();
function persistReport() {
  const snapshot = JSON.stringify({ engines, concurrency, durationMs: Date.now() - started,
    rows: [...rows].sort((left, right) => left.source.localeCompare(right.source)) }, null, 2);
  reportWrites = reportWrites.then(async () => {
    const temporary = resolve(reportRoot, `report.${process.pid}.next`);
    try {
      await writeFile(temporary, snapshot);
      for (let attempt = 0; ; attempt++) {
        try { await rename(temporary, resolve(reportRoot, 'report.json')); break; }
        catch (error) {
          if (attempt === 5 || !['EBUSY', 'EPERM', 'EACCES'].includes(error.code)) throw error;
          await new Promise(resolveDelay => setTimeout(resolveDelay, 50 * (attempt + 1)));
        }
      }
    } finally { await rm(temporary, { force: true }); }
  });
  return reportWrites;
}

// Some audio sources deliberately serialize playback at a 31-second upstream
// interval. Preserve that behavior in offline tests instead of weakening it.
async function execute(executable, args, cwd, logName, timeoutMs = 240_000) {
  const stream = createWriteStream(resolve(reportRoot, logName));
  const started = Date.now();
  const env = { ...process.env, PATH: `${nodeDir};${process.env.PATH ?? process.env.Path ?? ''}` };
  delete env.Path;
  return new Promise(resolveResult => {
    const child = spawn(executable, args, { cwd, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.pipe(stream, { end: false }); child.stderr.pipe(stream, { end: false });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      if (!child.pid) return;
      // npm and node --test have children; ending only their parent can leave
      // build writers alive. Target only this runner's owned process tree.
      const stop = spawn(resolve(process.env.SystemRoot ?? 'C:/Windows', 'System32/taskkill.exe'),
        ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      stop.on('error', () => child.kill());
      stop.on('exit', code => { if (code !== 0) child.kill(); });
    }, timeoutMs);
    child.on('error', error => stream.write(`${error.message}\n`));
    child.on('close', code => {
      clearTimeout(timer);
      stream.end(() => resolveResult({ exitCode: code, timedOut, durationMs: Date.now() - started, log: logName }));
    });
  });
}

const names = (await readdir(sourceRoot)).sort()
  .filter(name => !options.has('--source') || options.get('--source') === name);
await mapSources(names, concurrency, async name => {
  const cwd = resolve(sourceRoot, name);
  let manifest;
  try { manifest = JSON.parse(await readFile(resolve(cwd, 'package.json'), 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  const match = /node\s+--test\s+(.+)$/.exec(manifest.scripts?.test ?? '');
  if (!match) throw Error(`No declared offline Node test entry for ${name}`);
  const files = match[1].trim().split(/\s+/);
  if (files.some(file => !/^test\/[\w./*-]+\.mjs$/.test(file) || file.includes('live'))) throw Error(`Unsupported test path in ${name}`);
  const row = { source: name, pluginId: manifest.mgread.id, tests: files, results: {}, startedAt: new Date().toISOString() };
  if (options.has('--install-dependencies')) {
    row.install = await execute(executables.node, [resolve(nodeDir, 'node_modules/npm/bin/npm-cli.js'), 'ci', '--no-audit', '--no-fund'], cwd, `${name}-install.log`);
  }
  if ((!row.install || row.install.exitCode === 0) && !options.has('--skip-build')) {
    row.build = await execute(executables.node, [resolve(nodeDir, 'node_modules/npm/bin/npm-cli.js'), 'run', 'build'], cwd, `${name}-build.log`);
  }
  if ((!row.install || row.install.exitCode === 0) && (!row.build || row.build.exitCode === 0)) {
    for (const engine of engines === 'both' ? ['node', 'bun'] : [engines]) {
      row.results[engine] = await execute(executables[engine], engine === 'bun' ? ['test', '--timeout', '120000', ...files] : ['--test', ...files], cwd, `${name}-${engine}.log`);
    }
  }
  row.completedAt = new Date().toISOString();
  rows.push(row);
  await persistReport();
  console.log(`${name}: ${row.install && row.install.exitCode !== 0 ? 'INSTALL FAILED' : row.build && row.build.exitCode !== 0 ? 'BUILD FAILED' : Object.entries(row.results).map(([engine, result]) => `${engine}=${result.exitCode}`).join(' ')}`);
});
if (rows.length === 0) throw Error('No sources selected.');
await persistReport();
const failed = rows.filter(row => (row.install && row.install.exitCode !== 0) || (row.build && row.build.exitCode !== 0) || Object.values(row.results).some(result => result.exitCode !== 0));
console.log(`Sources=${rows.length} Passed=${rows.length - failed.length} Failed=${failed.length}`);
process.exitCode = failed.length ? 1 : 0;
