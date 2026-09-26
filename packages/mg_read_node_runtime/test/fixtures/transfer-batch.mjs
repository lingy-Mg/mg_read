/** Isolated single-JS batch fixtures shared by Node and real desktop Facade tests. */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createPluginSingleFile } from "../../dist/plugin-single-file.js";
import { crc32 } from "../../dist/lan-sync-checksum.js";

export async function createTransferBatch(root, count = 40, activation = "") {
  const project = join(root, "project");
  await mkdir(join(project, "dist"), { recursive: true });
  await writeFile(join(project, "dist/index.mjs"), `
export async function activate() { ${activation} }
export function discover() { return {kind: "document", document: {components: []}}; }
export function search() { return {items: [], nextCursor: null, totalCount: 0}; }
export function getDetail() { throw new Error("unused"); }
export function getChapters() { return {items: []}; }
export function getContent() { throw new Error("unused"); }
`);
  const artifacts = [];
  for (let index = 0; index < count; index++) {
    const id = `org.test.batch.${String(index).padStart(3, "0")}`;
    await writeFile(join(project, "package.json"), JSON.stringify({
      name: `@mgread-plugin/batch-${index}`, version: "1.0.0", type: "module",
      main: "dist/index.mjs", engines: {node: ">=24"},
      mgread: {schemaVersion: 1, id, displayName: id, packageMode: "single-file",
        pluginApi: 1, contentKinds: ["novel"]},
    }));
    const path = join(root, `${id}.mgplugin.js`);
    await createPluginSingleFile(project, path);
    const bytes = await readFile(path);
    artifacts.push({path, artifact: {id, version: "1.0.0", bytes: bytes.length,
      checksum: crc32(bytes), format: "singleFile", provenance: "installed",
      developmentFingerprint: null, developmentRevision: null}});
  }
  return artifacts;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  console.log(JSON.stringify(await createTransferBatch(process.argv[2], Number(process.argv[3] ?? 40), process.argv[4] ?? "")));
}
