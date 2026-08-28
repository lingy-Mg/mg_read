/** Builds the Android browser fixture with the repository's canonical packer. */
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPluginArtifactForProject } from '../../mgread-discovery-demo/tools/mgread.mjs';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));
const artifact = await buildPluginArtifactForProject(projectRoot);
const output = resolve(projectRoot, 'artifacts', artifact.fileName);
await mkdir(resolve(projectRoot, 'artifacts'), { recursive: true });
await rm(output, { force: true });
await writeFile(output, artifact.bytes, { mode: 0o444 });
process.stdout.write(`${artifact.fileName}\n`);
