#!/usr/bin/env node
/**
 * Source-local deterministic MgRead single-file artifact builder.
 * It intentionally supports only this plugin's declared Node 24 single-file mode
 * and embeds the one declared PNG icon into the artifact envelope.
 */
import { createHash } from 'node:crypto';
import { lstat, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { builtinModules } from 'node:module';
import { dirname, extname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build, stop } from 'esbuild';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const headerPrefix = '// @mgread-plugin-v1 ';
const headerLimit = 512 * 1024;
const iconLimit = 256 * 1024;
const artifactLimit = 32 * 1024 * 1024;
const bundleExtensions = new Set(['.js', '.mjs', '.cjs', '.json']);
const nodeBuiltins = new Set(
  builtinModules.flatMap((name) => [
    name,
    name.startsWith('node:') ? name.slice(5) : `node:${name}`,
  ]),
);

export async function buildPluginArtifact({ versionOverride } = {}) {
  const original = JSON.parse(
    await readFile(resolve(projectRoot, 'package.json'), 'utf8'),
  );
  const version = versionOverride ?? original.version;
  validatePackage(original, version);
  const packageJson = structuredClone(original);
  packageJson.version = version;

  let result;
  try {
    result = await build({
      absWorkingDir: projectRoot,
      entryPoints: [packageJson.main],
      bundle: true,
      charset: 'utf8',
      conditions: ['node', 'import', 'default'],
      external: [...nodeBuiltins],
      format: 'esm',
      legalComments: 'none',
      logLevel: 'silent',
      mainFields: ['module', 'main'],
      metafile: true,
      minify: false,
      platform: 'node',
      sourcemap: false,
      target: 'node24',
      treeShaking: true,
      write: false,
    });
  } catch (error) {
    throw new Error(`Single-file bundle failed: ${formatBuildError(error)}`);
  } finally {
    await stop();
  }

  if (result.warnings.length !== 0 || result.outputFiles.length !== 1) {
    throw new Error('Single-file build must emit one warning-free JavaScript file.');
  }
  for (const input of Object.keys(result.metafile.inputs)) {
    if (!bundleExtensions.has(extname(input).toLowerCase())) {
      throw new Error(`Unsupported bundled resource: ${input}`);
    }
  }
  for (const output of Object.values(result.metafile.outputs)) {
    for (const dependency of output.imports) {
      if (!dependency.external || !nodeBuiltins.has(dependency.path)) {
        throw new Error(`Only Node builtin externals are allowed: ${dependency.path}`);
      }
    }
  }

  const code = Buffer.from(result.outputFiles[0].contents);
  validateBundleCode(code);
  const descriptor = {
    name: packageJson.name,
    version: packageJson.version,
    type: 'module',
    main: 'dist/index.mjs',
    engines: { node: packageJson.engines.node },
    mgread: {
      schemaVersion: packageJson.mgread.schemaVersion,
      id: packageJson.mgread.id,
      displayName: packageJson.mgread.displayName,
      description: packageJson.mgread.description,
      pluginApi: packageJson.mgread.pluginApi,
      contentKinds: [...packageJson.mgread.contentKinds],
      packageMode: 'single-file',
      ...(packageJson.mgread.icon === undefined
        ? {}
        : { icon: packageJson.mgread.icon }),
    },
  };
  const envelope = {
    formatVersion: 1,
    descriptor,
    codeBytes: code.length,
    codeSha256: sha256(code),
  };
  if (packageJson.mgread.icon !== undefined) {
    envelope.icon = await readIcon(packageJson.mgread.icon);
  }
  const header = Buffer.from(
    `${headerPrefix}${Buffer.from(canonicalJson(envelope)).toString('base64url')}\n`,
  );
  if (header.length > headerLimit) {
    throw new Error(`Single-file header exceeds ${headerLimit} bytes.`);
  }
  const bytes = Buffer.concat([header, code]);
  if (bytes.length > artifactLimit) {
    throw new Error(`Plugin artifact exceeds ${artifactLimit} bytes.`);
  }
  return {
    bytes,
    fileName: `${packageJson.mgread.id}-${packageJson.version}.mgplugin.js`,
    format: 'singleFile',
  };
}

function validatePackage(value, version) {
  if (
    typeof value?.name !== 'string' ||
    typeof version !== 'string' ||
    !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version) ||
    value?.type !== 'module' ||
    value?.main !== 'dist/index.mjs' ||
    value?.engines?.node !== '>=24 <25' ||
    value?.mgread?.schemaVersion !== 1 ||
    value?.mgread?.pluginApi !== 1 ||
    value?.mgread?.packageMode !== 'single-file' ||
    typeof value?.mgread?.id !== 'string' ||
    !/^[a-z0-9]+(?:[.-][a-z0-9]+)+$/u.test(value.mgread.id) ||
    typeof value?.mgread?.displayName !== 'string' ||
    !Array.isArray(value?.mgread?.contentKinds) ||
    value.mgread.contentKinds.length === 0 ||
    value.mgread.contentKinds.some(
      (kind) => kind !== 'novel' && kind !== 'manga',
    ) ||
    (value.mgread.icon !== undefined && typeof value.mgread.icon !== 'string') ||
    value.manifest !== undefined ||
    value.sharedDependencies !== undefined ||
    value.bundledDependencies !== undefined
  ) {
    throw new Error('package.json is not a supported single-file plugin project.');
  }
}

async function readIcon(iconPath) {
  const normalized = iconPath.replaceAll('\\', '/').replace(/^\.\/+/u, '');
  if (
    !normalized.startsWith('assets/') ||
    normalized.split('/').includes('..') ||
    extname(normalized).toLowerCase() !== '.png'
  ) {
    throw new Error('mgread.icon must name a PNG below assets/.');
  }
  const absolute = resolve(projectRoot, ...normalized.split('/'));
  const details = await lstat(absolute);
  if (!details.isFile() || details.isSymbolicLink()) {
    throw new Error('mgread.icon must name a regular file.');
  }
  const bytes = await readFile(absolute);
  if (bytes.length > iconLimit) {
    throw new Error(`Plugin icon exceeds ${iconLimit} bytes.`);
  }
  if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error('mgread.icon is not a valid PNG file.');
  }
  return {
    mediaType: 'image/png',
    bytes: bytes.length,
    sha256: sha256(bytes),
    data: bytes.toString('base64'),
  };
}

function validateBundleCode(code) {
  const source = code.toString('utf8');
  const executable = source
    .replace(/\/\*[\s\S]*?\*\//gu, '')
    .replace(/^\s*\/\/.*$/gmu, '');
  if (/\bimport\s*\(/u.test(executable)) {
    throw new Error('Dynamic import is not supported by single-file artifacts.');
  }
  if (/import\.meta\.url/u.test(source) || /sourceMappingURL=/u.test(source)) {
    throw new Error('Single-file artifact contains an unsupported sidecar reference.');
  }
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(',')}]`;
  }
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function formatBuildError(error) {
  if (Array.isArray(error?.errors) && error.errors[0]?.text !== undefined) {
    return error.errors[0].text;
  }
  return error instanceof Error ? error.message : String(error);
}

if (
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  if (process.argv[2] !== 'pack' || process.argv.length !== 3) {
    throw new Error('Usage: mgread pack');
  }
  const artifact = await buildPluginArtifact();
  const artifactRoot = resolve(projectRoot, 'artifacts');
  const target = resolve(artifactRoot, artifact.fileName);
  await mkdir(artifactRoot, { recursive: true });
  await rm(target, { force: true });
  await writeFile(target, artifact.bytes, { mode: 0o444 });
  process.stdout.write(
    `${relative(projectRoot, target).replaceAll('\\', '/')}\n`,
  );
}
