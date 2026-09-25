/**
 * Binary source ABI v1 adapter, bundled into each distributable source.
 * Owns one lazy Wasm instance and bounded HTTP continuations. Rust owns all
 * routing, parsing and result projection; only the public Context performs IO.
 * No WASI, native addon, filesystem import, subprocess or second JS VM is used.
 * Trusted plugins share V8: synchronous guest CPU cannot be preempted here.
 */
import { Buffer } from 'node:buffer';

const messageLimit = 8 * 1024 * 1024;
const bodyLimit = 4 * 1024 * 1024;
const memoryLimit = 64 * 1024 * 1024;
const methods = ['discover', 'search', 'searchSuggestions', 'getDetail', 'getChapters', 'getContent'];

export function createWasmSource(binary) {
  if (!(binary instanceof Uint8Array) || binary.byteLength > messageLimit) throw new Error('wasm_binary_invalid');
  let context;
  let guest;
  let loading;
  let generation = 0;
  const pending = new Set();

  async function load() {
    if (guest) return guest;
    if (!loading) {
      const epoch = generation;
      loading = WebAssembly.compile(binary).then((module) => {
        if (WebAssembly.Module.imports(module).length !== 0) throw new Error('wasm_imports_unsupported');
        const instance = new WebAssembly.Instance(module, {});
        const exports = instance.exports;
        if (!(exports.memory instanceof WebAssembly.Memory) ||
            ['abi_version', 'alloc', 'release', 'invoke', 'result_len'].some((key) => typeof exports[key] !== 'function') ||
            exports.abi_version() !== 1 || exports.memory.buffer.byteLength > memoryLimit) throw new Error('wasm_abi_invalid');
        if (epoch !== generation) throw new Error('wasm_source_deactivated');
        guest = exports;
        context.log.info('source_wasm_ready_abi1');
        return guest;
      }).catch((error) => { loading = undefined; throw error; });
    }
    return loading;
  }

  function call(exports, value) {
    const input = Buffer.from(JSON.stringify(value));
    if (input.length > messageLimit) throw new Error('wasm_input_limit');
    let inputPtr;
    let outputPtr;
    let outputLength;
    try {
      inputPtr = exports.alloc(input.length) >>> 0;
      if (inputPtr === 0 || inputPtr + input.length > exports.memory.buffer.byteLength) throw new Error('wasm_input_pointer');
      new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);
      outputPtr = exports.invoke(inputPtr, input.length) >>> 0;
      outputLength = exports.result_len() >>> 0;
      if (!outputPtr || outputLength > messageLimit || outputPtr + outputLength > exports.memory.buffer.byteLength ||
          exports.memory.buffer.byteLength > memoryLimit) throw new Error('wasm_output_limit');
      return JSON.parse(Buffer.from(exports.memory.buffer, outputPtr, outputLength).toString('utf8'));
    } finally {
      if (outputPtr && outputLength && outputPtr + outputLength <= exports.memory.buffer.byteLength) exports.release(outputPtr, outputLength);
      if (inputPtr && inputPtr + input.length <= exports.memory.buffer.byteLength) exports.release(inputPtr, input.length);
    }
  }

  async function fetchText(host, request, controller) {
    const url = new URL(request.url);
    if (url.protocol !== 'https:' || url.username || url.password) throw new Error('wasm_http_url_invalid');
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await host.http.fetch(url, { headers: request.headers, signal: controller.signal });
      if (!response.ok) { await response.body?.cancel(); throw new Error(`wasm_http_${response.status}`); }
      const reader = response.body?.getReader();
      if (!reader) throw new Error('wasm_http_body_missing');
      const chunks = [];
      let length = 0;
      try {
        while (true) {
          const item = await reader.read();
          if (item.done) break;
          length += item.value.byteLength;
          if (length > bodyLimit) throw new Error('wasm_http_body_limit');
          chunks.push(Buffer.from(item.value));
        }
      } finally { await reader.cancel().catch(() => {}); }
      return { body: Buffer.concat(chunks).toString('utf8') };
    } finally { clearTimeout(timer); }
  }

  function resources(host, value, depth = 0) {
    if (depth > 48) throw new Error('wasm_result_depth');
    if (Array.isArray(value)) return value.map((item) => resources(host, item, depth + 1));
    if (value === null || typeof value !== 'object') return value;
    if (Object.keys(value).length === 1 && Object.hasOwn(value, '$resource')) return host.resource.proxy(value.$resource);
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, resources(host, item, depth + 1)]));
  }

  async function invoke(method, request) {
    const host = context;
    const epoch = generation;
    if (!host) throw new Error('wasm_source_not_active');
    const exports = await load();
    const controllers = new Set();
    let requestCount = 0;
    const started = Date.now();
    let input = { method, request };
    try {
      for (let step = 0; step < 128; step++) {
        if (epoch !== generation) throw new Error('wasm_source_deactivated');
        if (Date.now() - started > 90000) throw new Error('wasm_invocation_deadline');
        const output = call(exports, input);
        if (output.kind === 'result') return resources(host, output.value);
        if (output.kind === 'error') {
          if (output.code === 'source_access_blocked') host.errors.raise('source_access_blocked');
          throw new Error('wasm_source_operation_failed');
        }
        if (output.kind !== 'http' || !Array.isArray(output.requests) || !output.requests.length ||
            output.requests.length > 4 || (requestCount += output.requests.length) > 128) throw new Error('wasm_step_invalid');
        const responses = await Promise.all(output.requests.map(async (request) => {
          const controller = new AbortController();
          controllers.add(controller); pending.add(controller);
          try { return await fetchText(host, request, controller); }
          catch (error) {
            if (request.optional === true) return { error: 'http_failed' };
            throw error;
          } finally { pending.delete(controller); controllers.delete(controller); }
        }));
        input = { method, request, state: output.state, responses };
      }
      throw new Error('wasm_step_limit');
    } finally { for (const controller of controllers) controller.abort(); }
  }

  return Object.freeze({
    async activate(host) { if (context) throw new Error('wasm_source_already_active'); context = host; },
    async deactivate() {
      generation++;
      for (const controller of pending) controller.abort();
      pending.clear(); context = undefined; guest = undefined; loading = undefined;
    },
    ...Object.fromEntries(methods.map((method) => [method, (request) => invoke(method, request)])),
  });
}
