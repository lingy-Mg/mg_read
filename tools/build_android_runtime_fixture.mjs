/** Build the deterministic Android Source fixture into a caller-owned path. */
import { resolve } from "node:path";
import { createPluginSingleFile } from "../packages/mg_read_node_runtime/dist/index.js";

const output = process.argv[2];
if (!output) throw new Error("Missing fixture artifact path.");
const project = resolve("integration_test/fixtures/android-runtime-source");
await createPluginSingleFile(project, resolve(output));
