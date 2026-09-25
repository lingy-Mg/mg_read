/** Compile-time consumer proof: Context comes from the existing public API. */
import type { MgReadPluginContext, PluginJsonValue } from '@mgread/source-api';
import { createWasmSource } from '@mgread/source-wasm';
declare const context: MgReadPluginContext;
const source = createWasmSource(new Uint8Array());
const activated: Promise<void> = source.activate(context);
const result: Promise<PluginJsonValue> = source.search({ query: 'test', cursor: null, pageSize: 5 });
void activated;
void result;
