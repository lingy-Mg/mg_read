/**
 * Debug-only Runtime HTTP inspector.
 *
 * Responsibilities:
 * - own the separately-bound LAN debug listener and its static inspector page;
 * - project source search/discovery results without exposing resource tokens;
 * - retain bounded, in-memory cover probes for the page's fetch/decode flow.
 *
 * Boundaries:
 * - never exposes Runtime RPC, health, cookies, headers, HTML, or raw plugin objects;
 * - delegates all source calls and resource reads to the owning Runtime Core.
 */
import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { networkInterfaces } from "node:os";
import { Readable } from "node:stream";

import type { JsonObject, JsonValue } from "./protocol.js";

const debugHost = "0.0.0.0";
const maxPageSize = 50;
const maxQueryLength = 160;
const probeTtlMs = 15 * 60 * 1_000;
const maxProbeEntries = 300;

export interface RuntimeDebugHttpStatus extends JsonObject {
  readonly enabled: boolean;
  readonly endpoints: readonly string[];
  readonly startedAt: string | null;
}

export interface RuntimeDebugHttpHost {
  readonly discover: (params: JsonObject) => Promise<JsonValue>;
  readonly plugins: () => Promise<JsonValue>;
  readonly search: (params: JsonObject) => Promise<JsonValue>;
  readonly status: () => Promise<JsonObject>;
}

interface DebugProbe {
  readonly coverUrl: string;
  readonly expiresAtMs: number;
}

/** Owns one optional LAN-only Debug listener for an already-running Runtime. */
export class RuntimeDebugHttpServer {
  readonly #host: RuntimeDebugHttpHost;
  readonly #probes = new Map<string, DebugProbe>();
  #server: Server | undefined;
  #startedAt: string | undefined;

  constructor(host: RuntimeDebugHttpHost) {
    this.#host = host;
  }

  async setEnabled(enabled: boolean): Promise<RuntimeDebugHttpStatus> {
    if (!enabled) {
      await this.#stop();
      return this.status();
    }
    if (this.#server === undefined) await this.#start();
    return this.status();
  }

  status(): RuntimeDebugHttpStatus {
    const address = this.#server?.address();
    if (address === undefined || address === null || typeof address === "string") {
      return Object.freeze({ enabled: false, endpoints: Object.freeze([]), startedAt: null });
    }
    const endpoints = debugEndpoints(address.port);
    return Object.freeze({ enabled: true, endpoints, startedAt: this.#startedAt ?? null });
  }

  async dispose(): Promise<void> {
    await this.#stop();
  }

  async #start(): Promise<void> {
    const server = createServer((request, response) => {
      void this.#handle(request, response);
    });
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => {
        server.off("listening", onListening);
        reject(error);
      };
      const onListening = (): void => {
        server.off("error", onError);
        resolve();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen({ host: debugHost, port: 0 });
    });
    this.#server = server;
    this.#startedAt = new Date().toISOString();
  }

  async #stop(): Promise<void> {
    const server = this.#server;
    this.#server = undefined;
    this.#startedAt = undefined;
    this.#probes.clear();
    if (server === undefined) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://runtime-debug.invalid");
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      response.end();
      return;
    }
    try {
      switch (url.pathname) {
        case "/__debug":
          writeHtml(response, visualInspectorHtml);
          return;
        case "/__debug/api/status":
          writeJson(response, 200, await this.#host.status());
          return;
        case "/__debug/api/plugins":
          writeJson(response, 200, { plugins: await this.#host.plugins() });
          return;
        case "/__debug/api/search":
          writeJson(response, 200, await this.#search(url));
          return;
        case "/__debug/api/discover":
          writeJson(response, 200, await this.#discover(url));
          return;
        case "/__debug/api/resource-probe":
          await this.#probe(url, request, response);
          return;
        default:
          writeJson(response, 404, { code: "not_found" });
      }
    } catch (error) {
      writeJson(response, 400, { code: stableDebugError(error) });
    }
  }

  async #search(url: URL): Promise<JsonObject> {
    const pluginId = readPluginId(url);
    const query = requiredText(url.searchParams.get("q"), "query");
    if (query.length > maxQueryLength) throw new Error("query_too_long");
    const pageSize = readPageSize(url);
    const startedAt = performance.now();
    const result = await this.#host.search(Object.freeze({
      cursor: nullableQuery(url, "cursor"),
      pageSize,
      pluginId,
      query,
    }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: this.#projectResult(result) });
  }

  async #discover(url: URL): Promise<JsonObject> {
    const pluginId = readPluginId(url);
    const pageSize = readPageSize(url);
    const startedAt = performance.now();
    const result = await this.#host.discover(Object.freeze({
      collectionId: nullableQuery(url, "collectionId"),
      cursor: nullableQuery(url, "cursor"),
      pageSize,
      pluginId,
      target: nullableQuery(url, "target"),
    }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: this.#projectResult(result) });
  }

  async #probe(url: URL, request: IncomingMessage, response: ServerResponse): Promise<void> {
    this.#pruneProbes();
    const id = requiredText(url.searchParams.get("probeId"), "probeId");
    const probe = this.#probes.get(id);
    if (probe === undefined) {
      writeJson(response, 404, { code: "probe_not_found" });
      return;
    }
    const controller = new AbortController();
    request.once("close", () => controller.abort());
    const upstream = await fetch(probe.coverUrl, { redirect: "follow", signal: controller.signal });
    const headers: Record<string, string> = { "Cache-Control": "no-store" };
    const contentType = upstream.headers.get("content-type");
    const contentLength = upstream.headers.get("content-length");
    if (contentType !== null) headers["Content-Type"] = contentType;
    if (contentLength !== null) headers["Content-Length"] = contentLength;
    response.writeHead(upstream.status, headers);
    const body = upstream.body;
    if (body === null) {
      response.end();
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const stream = Readable.fromWeb(body);
      stream.once("error", reject);
      response.once("error", reject);
      response.once("finish", resolve);
      stream.pipe(response);
    });
  }

  #projectResult(value: JsonValue): JsonValue {
    return projectValue(value, (coverUrl) => this.#retainProbe(coverUrl));
  }

  #retainProbe(coverUrl: string): JsonObject {
    this.#pruneProbes();
    if (this.#probes.size >= maxProbeEntries) this.#probes.delete(this.#probes.keys().next().value as string);
    const id = randomBytes(18).toString("base64url");
    this.#probes.set(id, Object.freeze({ coverUrl, expiresAtMs: Date.now() + probeTtlMs }));
    return Object.freeze({ displayUrl: redactUrl(coverUrl), probeId: id, type: coverUrl.includes("/v1/source-resource/") ? "runtime-proxy" : "ordinary-url" });
  }

  #pruneProbes(): void {
    const now = Date.now();
    for (const [id, probe] of this.#probes) if (probe.expiresAtMs <= now) this.#probes.delete(id);
  }
}

function projectValue(value: JsonValue, retainProbe: (coverUrl: string) => JsonObject): JsonValue {
  if (Array.isArray(value)) return Object.freeze(value.map((item) => projectValue(item, retainProbe)));
  if (value === null || typeof value !== "object") return value;
  const source = value as JsonObject;
  const projected: Record<string, JsonValue> = {};
  for (const key of ["kind", "type", "id", "title", "subtitle", "text", "layout", "target", "collectionId", "cursor", "nextCursor", "totalCount", "count", "elapsedMs", "author", "contentKind", "status", "description", "rank", "recommendation", "label", "value", "selectedTabId", "document", "tabs", "categories", "children", "components", "items", "content", "metric", "continuation"]) {
    const item = source[key];
    if (item !== undefined) projected[key] = projectValue(item, retainProbe);
  }
  const coverUrl = source.coverUrl;
  if (typeof coverUrl === "string") projected.cover = retainProbe(coverUrl);
  if (coverUrl === null) projected.cover = null;
  return Object.freeze(projected);
}

function debugEndpoints(port: number): readonly string[] {
  const hosts = new Set<string>(["127.0.0.1"]);
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) if (address.family === "IPv4" && !address.internal) hosts.add(address.address);
  }
  return Object.freeze([...hosts].map((host) => `http://${host}:${port}/__debug`));
}

function readPluginId(url: URL): string {
  const value = requiredText(url.searchParams.get("pluginId"), "pluginId");
  if (!/^[a-z0-9][a-z0-9.-]{0,127}$/.test(value)) throw new Error("plugin_id_invalid");
  return value;
}

function readPageSize(url: URL): number {
  const value = url.searchParams.get("pageSize");
  if (value === null || value === "") return 20;
  if (!/^\d+$/.test(value)) throw new Error("page_size_invalid");
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maxPageSize) throw new Error("page_size_invalid");
  return parsed;
}

function nullableQuery(url: URL, key: string): string | null {
  const value = url.searchParams.get(key);
  if (value === null || value === "") return null;
  if (value.length > 500) throw new Error("parameter_too_long");
  return value;
}

function requiredText(value: string | null, name: string): string {
  if (value === null || value.trim() === "") throw new Error(`${name}_required`);
  return value.trim();
}

function redactUrl(value: string): string {
  try {
    const url = new URL(value);
    const parts = url.pathname.split("/");
    const token = parts.at(-1);
    if (token !== undefined && token.length > 10) parts[parts.length - 1] = `${token.slice(0, 3)}…${token.slice(-3)}`;
    return `${url.protocol}//${url.host}${parts.join("/")}`;
  } catch {
    return "invalid-url";
  }
}

function stableDebugError(error: unknown): string {
  return error instanceof Error && /^[a-z_]+$/.test(error.message) ? error.message : "debug_request_failed";
}

function writeJson(response: ServerResponse, status: number, body: JsonObject): void {
  response.writeHead(status, { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(body));
}

function writeHtml(response: ServerResponse, body: string): void {
  response.writeHead(200, { "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'self' blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' blob:", "Content-Type": "text/html; charset=utf-8" });
  response.end(body);
}

/** Adds the recursive discovery renderer without granting it raw result access. */
function withDiscoveryRenderer(html: string): string {
  return html.replace(
    "</script></html>",
    `</script><script>${discoveryRendererScript}</script></html>`,
  );
}

const discoveryRendererScript = String.raw`
const discoveryResult=$('discover-result');
discoveryResult.replaceWith(Object.assign(document.createElement('div'),{id:'discover-result'}));
const discoveryPageSize=document.createElement('input');discoveryPageSize.id='discover-size';discoveryPageSize.type='number';discoveryPageSize.min='1';discoveryPageSize.max='50';discoveryPageSize.value='20';const discoveryPageSizeLabel=document.createElement('label');discoveryPageSizeLabel.textContent='pageSize ';discoveryPageSizeLabel.append(discoveryPageSize);$('discover').before(discoveryPageSizeLabel);
function discoveryText(value){return value===null?'--':typeof value==='string'||typeof value==='number'?String(value):''}
function reloadDiscovery(target,collectionId,cursor){if(target!==undefined)$('discover-target').value=target||'';if(collectionId!==undefined)$('discover-collection').value=collectionId||'';if(cursor!==undefined)$('discover-cursor').value=cursor||'';$('discover').click()}
function discoveryAction(value,parent){if(!value||typeof value!=='object')return;const target=typeof value.target==='string'?value.target:undefined,collectionId=typeof value.collectionId==='string'?value.collectionId:undefined,cursor=typeof value.cursor==='string'?value.cursor:typeof value.nextCursor==='string'?value.nextCursor:undefined;if(target===undefined&&collectionId===undefined&&cursor===undefined)return;const button=document.createElement('button');button.textContent=target?'加载分类':'继续加载';button.onclick=()=>reloadDiscovery(target,collectionId,cursor);parent.append(button)}
function renderDiscovery(value,parent,depth){if(Array.isArray(value)){for(const child of value)renderDiscovery(child,parent,depth);return}if(!value||typeof value!=='object')return;const node=document.createElement('div');node.className='item';node.style.marginLeft=Math.min(depth,5)*14+'px';const kind=discoveryText(value.kind||value.type||value.layout||'content item'),title=discoveryText(value.title||value.text||value.name||value.id||'未命名项目');node.innerHTML='<strong>'+esc(kind)+'</strong><div class=meta>'+esc(title)+'</div>';const facts=['id','author','target','collectionId','cursor','nextCursor','totalCount','count'];const detail=facts.filter(key=>value[key]!==undefined&&value[key]!==null).map(key=>key+'：'+discoveryText(value[key])).join(' · ');if(detail){const meta=document.createElement('div');meta.className='meta';meta.textContent=detail;node.append(meta)}parent.append(node);if(value.cover){const cover=document.createElement('div');cover.className='meta';cover.textContent=(value.cover.type||'cover')+' · '+(value.cover.displayUrl||'--');const probeState=document.createElement('div');probeState.className='meta probe';probeState.textContent='等待封面探测';node.append(cover,probeState);if(value.cover.probeId)probe(value.cover.probeId,node)}discoveryAction(value,node);for(const key of ['document','components','children','items','content','categories','continuation'])if(value[key]!==undefined&&value[key]!==null){const children=document.createElement('div');children.className='meta';children.textContent=key;node.append(children);renderDiscovery(value[key],node,depth+1)}}
$('discover').onclick=async()=>{const p=new URLSearchParams({pluginId:$('discover-plugin').value,target:$('discover-target').value,collectionId:$('discover-collection').value,cursor:$('discover-cursor').value,pageSize:$('discover-size').value});const root=$('discover-result');root.innerHTML='加载中…';try{const value=await json('/__debug/api/discover?'+p);root.innerHTML='';const summary=document.createElement('p');summary.textContent='耗时 '+value.elapsedMs+'ms';root.append(summary);renderDiscovery(value.result,root,0)}catch(e){root.textContent='失败：'+e.message}};
`;

const inspectorHtml = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MgRead Runtime Debug</title><style>body{margin:0;background:#f5f6fa;color:#20232a;font:14px system-ui,sans-serif}main{max-width:1120px;margin:auto;padding:20px}section{background:white;border:1px solid #e1e4ea;border-radius:12px;padding:16px;margin:14px 0}h1,h2{margin:0 0 12px}label{display:block;margin:8px 0}input,button{font:inherit;padding:8px;border:1px solid #c9ced8;border-radius:7px}button{background:#2357d9;color:white;cursor:pointer}.warn{color:#9a4300}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px}.item{border-top:1px solid #eee;padding:12px 0}.meta{color:#687080;word-break:break-all}.cover{max-width:96px;max-height:128px;display:block;margin-top:8px}pre{white-space:pre-wrap;word-break:break-word;background:#f6f7f9;padding:10px;border-radius:7px}</style><main><h1>MgRead Runtime Debug</h1><p class="warn">仅 Debug 使用：当前监听可被同一网络设备访问，且未启用认证。</p><section><h2>Runtime 状态</h2><pre id="status">加载中…</pre></section><section><h2>搜索调试</h2><label>书源 ID <input id="search-plugin" value="org.mgread.shudugu"></label><label>关键词 <input id="search-q"></label><label>pageSize <input id="search-size" value="20" type="number" min="1" max="50"></label><button id="search">搜索</button><div id="search-result"></div></section><section><h2>发现调试</h2><label>书源 ID <input id="discover-plugin" value="org.mgread.shudugu"></label><label>target <input id="discover-target"></label><label>collectionId <input id="discover-collection"></label><label>cursor <input id="discover-cursor"></label><button id="discover">加载发现</button><pre id="discover-result"></pre></section></main><script>const $=id=>document.getElementById(id);async function json(path){const r=await fetch(path);const v=await r.json();if(!r.ok)throw Error(v.code||r.status);return v}function esc(v){return String(v??'--').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}async function probe(probeId,node){try{const r=await fetch('/__debug/api/resource-probe?probeId='+encodeURIComponent(probeId));const type=r.headers.get('content-type')||'--',length=r.headers.get('content-length')||'--',blob=await r.blob();const bytes=blob.size;let decoded=false,error='';try{if('createImageBitmap'in window){const b=await createImageBitmap(blob);b.close();decoded=true}else{await new Promise((ok,no)=>{const img=new Image;const u=URL.createObjectURL(blob);img.onload=()=>{URL.revokeObjectURL(u);ok()};img.onerror=()=>{URL.revokeObjectURL(u);no(Error('decode_failed'))};img.src=u}) ;decoded=true}}catch(e){error=e.message||'decode_failed'}node.querySelector('.probe').textContent='HTTP '+r.status+' · '+type+' · 声明 '+length+' · 实际 '+bytes+' bytes · '+(decoded?'可解码':'解码失败 '+error);if(decoded){const img=document.createElement('img');img.className='cover';img.src=URL.createObjectURL(blob);node.append(img)}}catch(e){node.querySelector('.probe').textContent='请求失败：'+e.message}}function renderItems(value,root){const items=value?.items||value?.result?.items||[];root.innerHTML='<p>耗时 '+esc(value.elapsedMs)+'ms，结果 '+items.length+' 条</p>';for(const item of items){const n=document.createElement('div');n.className='item';n.innerHTML='<strong>'+esc(item.title)+'</strong><div class=meta>作者：'+esc(item.author)+' · remote ID：'+esc(item.id)+'</div><div class=meta>'+esc(item.cover?.type||'无封面')+' · '+esc(item.cover?.displayUrl||'--')+'</div><div class="meta probe">等待封面探测</div>';root.append(n);if(item.cover?.probeId)probe(item.cover.probeId,n)}}async function loadStatus(){try{$('status').textContent=JSON.stringify(await json('/__debug/api/status'),null,2)}catch(e){$('status').textContent='失败：'+e.message}}$('search').onclick=async()=>{const p=new URLSearchParams({pluginId:$('search-plugin').value,q:$('search-q').value,pageSize:$('search-size').value});try{renderItems(await json('/__debug/api/search?'+p),$('search-result'))}catch(e){$('search-result').textContent='失败：'+e.message}};$('discover').onclick=async()=>{const p=new URLSearchParams({pluginId:$('discover-plugin').value,target:$('discover-target').value,collectionId:$('discover-collection').value,cursor:$('discover-cursor').value});try{$('discover-result').textContent=JSON.stringify(await json('/__debug/api/discover?'+p),null,2)}catch(e){$('discover-result').textContent='失败：'+e.message}};loadStatus()</script></html>`;

const visualInspectorHtml = String.raw`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MgRead Runtime Debug Inspector</title><style>
:root{color:#18233b;background:#f3f6fb;font:14px Inter,system-ui,sans-serif}*{box-sizing:border-box}body{margin:0}.shell{max-width:1320px;margin:auto;padding:28px 20px 64px}.hero{display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin:8px 0 22px}.eyebrow{margin:0;color:#2563eb;font-weight:800;letter-spacing:.08em;font-size:11px}.hero h1{font-size:28px;margin:5px 0 4px}.sub{color:#64748b;margin:0}.risk{max-width:390px;margin:0;padding:12px 14px;border:1px solid #fed7aa;border-radius:12px;background:#fff7ed;color:#9a3412;line-height:1.5}.panel{background:#fff;border:1px solid #dce4f0;border-radius:16px;padding:18px;margin:16px 0;box-shadow:0 8px 24px rgba(15,23,42,.035)}.panel-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:14px}.panel h2{font-size:18px;margin:0}.hint{color:#64748b;font-size:12px}.status-grid,.book-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px}.stat{background:#f8fafc;border:1px solid #e5eaf2;border-radius:11px;padding:12px}.stat b{display:block;margin-top:5px;word-break:break-word}.form{display:grid;grid-template-columns:1.5fr 1.5fr .7fr auto;gap:10px;align-items:end}.discover-form{grid-template-columns:1.3fr 1fr 1fr 1fr .55fr auto}label{display:grid;gap:5px;color:#475569;font-size:12px;font-weight:700}input,select,button{font:inherit;border-radius:9px;padding:10px}input,select{border:1px solid #cbd5e1;background:white;color:#172033;min-width:0}button{border:0;background:#2563eb;color:white;font-weight:750;cursor:pointer}button:hover{background:#1d4ed8}button.secondary{background:#eef2ff;color:#3730a3;border:1px solid #c7d2fe}.summary{margin:14px 0 4px;color:#475569}.book{display:grid;grid-template-columns:92px 1fr;gap:12px;border:1px solid #e0e7ef;border-radius:13px;padding:11px;background:#fff}.cover-box{display:grid;place-items:center;min-height:126px;border-radius:9px;background:#edf2f7;overflow:hidden;color:#94a3b8}.cover-box img{width:100%;height:126px;object-fit:cover}.book h3{font-size:15px;margin:0 0 4px}.meta{color:#64748b;font-size:12px;line-height:1.55;overflow-wrap:anywhere}.chip{display:inline-block;border-radius:20px;padding:2px 8px;margin:6px 5px 4px 0;background:#e0e7ff;color:#3730a3;font-size:11px;font-weight:700}.probe{margin-top:7px;padding:7px 8px;background:#f8fafc;border-radius:7px;color:#475569;font-size:11px}.tree{display:grid;gap:8px}.tree-node{border-left:3px solid #bfdbfe;background:#f8fafc;border-radius:0 10px 10px 0;padding:10px 12px}.tree-node.depth-1{margin-left:14px;border-left-color:#a7f3d0}.tree-node.depth-2,.tree-node.depth-3,.tree-node.depth-4{margin-left:28px;border-left-color:#fde68a}.node-head{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.kind{font-size:11px;font-weight:800;color:#1d4ed8;text-transform:uppercase}.node-title{font-weight:750}.node-children{display:grid;gap:7px;margin-top:8px}.inline-actions{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}.inline-actions button{font-size:12px;padding:6px 9px}.empty{padding:22px;text-align:center;color:#64748b;border:1px dashed #cbd5e1;border-radius:10px}details{margin-top:14px}summary{cursor:pointer;color:#475569;font-weight:700}pre{max-height:300px;overflow:auto;margin:8px 0 0;padding:12px;border-radius:10px;background:#0f172a;color:#dbeafe;font:12px ui-monospace,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.error{padding:10px;border-radius:9px;background:#fef2f2;color:#b91c1c}.loading{color:#2563eb}@media(max-width:780px){.hero{display:block}.risk{margin-top:12px}.form,.discover-form{grid-template-columns:1fr 1fr}.form button,.discover-form button{grid-column:span 2}.book-grid{grid-template-columns:1fr}}</style></head>
<body><main class="shell"><header class="hero"><div><p class="eyebrow">NODE RUNTIME · DEBUG ONLY</p><h1>MgRead Runtime Debug Inspector</h1><p class="sub">搜索、发现、封面代理与图片解码的同一条 Runtime 调用链。</p></div><p class="risk">局域网调试已开启且无认证。仅在受信任网络中短时使用，完成后请关闭 Flutter 中的调试开关。</p></header>
<section class="panel"><div class="panel-head"><h2>Runtime 状态</h2><span class="hint" id="status-time">加载中…</span></div><div class="status-grid" id="status-grid"></div></section>
<section class="panel"><div class="panel-head"><div><h2>搜索调试</h2><div class="hint">输入关键词后查看结果字段和每张封面的真实探测状态。</div></div></div><div class="form"><label>书源<select id="search-plugin"></select></label><label>关键词<input id="search-q" placeholder="例如：诡秘之主"></label><label>pageSize<input id="search-size" type="number" value="20" min="1" max="50"></label><button id="search" type="button">搜索</button></div><div id="search-view" class="empty">选择书源并执行搜索。</div><details><summary>安全响应摘要</summary><pre id="search-raw">--</pre></details></section>
<section class="panel"><div class="panel-head"><div><h2>发现调试</h2><div class="hint">先加载首页；点击分类或“继续加载”会把 target、collectionId、cursor 自动带回请求。</div></div></div><div class="form discover-form"><label>书源<select id="discover-plugin"></select></label><label>target<input id="discover-target" placeholder="首页可留空"></label><label>collectionId<input id="discover-collection" placeholder="分类 collection"></label><label>cursor<input id="discover-cursor" placeholder="续页 cursor"></label><label>pageSize<input id="discover-size" type="number" value="20" min="1" max="50"></label><button id="discover" type="button">加载发现</button></div><div id="discover-view" class="empty">加载首页发现内容，递归树会显示在这里。</div><details><summary>安全响应摘要</summary><pre id="discover-raw">--</pre></details></section></main>
<script>
const by=id=>document.getElementById(id);const sourceDefaults=['org.mgread.shudugu'];
const text=value=>value===null||value===undefined?'--':String(value);const escape=value=>text(value).replace(/[&<>]/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[char]));
async function api(path){const response=await fetch(path);const body=await response.json();if(!response.ok)throw new Error(body.code||String(response.status));return body}
function viewError(host,error){host.className='error';host.textContent='请求失败：'+(error.message||'unknown_error')}
function setRaw(id,value){by(id).textContent=JSON.stringify(value,null,2)}
function statusCard(label,value){const card=document.createElement('div');card.className='stat';card.innerHTML='<span class="hint">'+escape(label)+'</span><b>'+escape(value)+'</b>';return card}
async function loadStatus(){try{const status=await api('/__debug/api/status');const grid=by('status-grid');grid.replaceChildren(statusCard('状态',status.ok?'ready':status.status||'--'),statusCard('平台',status.platform||'--'),statusCard('Runtime',status.runtimeVersion||'--'),statusCard('Node',status.nodeVersion||'--'),statusCard('插件数',Array.isArray(status.plugins)?status.plugins.length:'--'),statusCard('启动时间',status.startedAt||'--'));by('status-time').textContent='已刷新 '+new Date().toLocaleTimeString()}catch(error){by('status-grid').textContent='状态读取失败：'+error.message}}
function pluginList(payload){const raw=payload.plugins;return Array.isArray(raw)?raw:(raw&&Array.isArray(raw.plugins)?raw.plugins:[])}
function populateSelect(select,plugins){const previous=select.value||sourceDefaults[0];const ids=[...new Set([...sourceDefaults,...plugins.filter(plugin=>plugin&&typeof plugin.id==='string').map(plugin=>plugin.id)])];select.replaceChildren(...ids.map(id=>{const option=document.createElement('option');option.value=id;option.textContent=id;return option}));select.value=ids.includes(previous)?previous:ids[0]}
async function loadPlugins(){try{const data=await api('/__debug/api/plugins');const plugins=pluginList(data);populateSelect(by('search-plugin'),plugins);populateSelect(by('discover-plugin'),plugins)}catch(error){for(const id of ['search-plugin','discover-plugin'])populateSelect(by(id),[])}}
function probeLabel(result){return 'HTTP '+result.status+' · '+result.type+' · 声明 '+result.declared+' · 实际 '+result.bytes+' bytes · '+result.decode}
async function probe(probeId,coverBox,probeHost){try{probeHost.textContent='封面探测中…';const response=await fetch('/__debug/api/resource-probe?probeId='+encodeURIComponent(probeId));const type=response.headers.get('content-type')||'--',declared=response.headers.get('content-length')||'--',blob=await response.blob();let decode='未解码';if(response.ok&&type.startsWith('image/')){const url=URL.createObjectURL(blob);const image=new Image;image.src=url;try{await image.decode();decode='可解码';coverBox.replaceChildren(image)}catch(error){decode='解码失败'}finally{if(decode!=='可解码')URL.revokeObjectURL(url)}}else if(response.ok){decode='非图片 MIME'}probeHost.textContent=probeLabel({status:response.status,type,declared,bytes:blob.size,decode})}catch(error){probeHost.textContent='封面请求失败：'+(error.message||'network_error')}}
function coverCard(value){const box=document.createElement('div');box.className='cover-box';const probeState=document.createElement('div');probeState.className='probe';if(!value){box.textContent='无封面';probeState.textContent='未提供 coverUrl';return {box,probeState}}box.textContent='等待探测';probeState.textContent=value.type+' · '+text(value.displayUrl);if(value.probeId)void probe(value.probeId,box,probeState);return {box,probeState}}
function bookCard(item){const card=document.createElement('article');card.className='book';const cover=coverCard(item.cover);const details=document.createElement('div');details.innerHTML='<h3>'+escape(item.title)+'</h3><div class="meta">作者：'+escape(item.author)+'<br>remote ID：'+escape(item.id)+'</div><span class="chip">'+escape(item.cover?item.cover.type:'无 coverUrl')+'</span>';details.append(cover.probeState);card.append(cover.box,details);return card}
function showBooks(host,payload){host.className='';host.replaceChildren();const items=payload.result&&Array.isArray(payload.result.items)?payload.result.items:[];const summary=document.createElement('p');summary.className='summary';summary.textContent='耗时 '+payload.elapsedMs+' ms · '+items.length+' 条结果';const grid=document.createElement('div');grid.className='book-grid';if(items.length===0)grid.innerHTML='<div class="empty">没有返回搜索结果。</div>';for(const item of items)grid.append(bookCard(item));host.append(summary,grid)}
function actionButton(label,callback){const button=document.createElement('button');button.className='secondary';button.type='button';button.textContent=label;button.onclick=callback;return button}
function discoveryAction(value,node){const target=typeof value.target==='string'?value.target:undefined;const collectionId=typeof value.collectionId==='string'?value.collectionId:undefined;const cursor=typeof value.nextCursor==='string'?value.nextCursor:(typeof value.cursor==='string'?value.cursor:undefined);if(target===undefined&&collectionId===undefined&&cursor===undefined)return;const actions=document.createElement('div');actions.className='inline-actions';actions.append(actionButton(target?'加载分类':'继续加载',()=>{if(target!==undefined)by('discover-target').value=target;if(collectionId!==undefined)by('discover-collection').value=collectionId;if(cursor!==undefined)by('discover-cursor').value=cursor;by('discover').click()}));node.append(actions)}
function renderDiscovery(value,depth){if(Array.isArray(value)){const group=document.createElement('div');group.className='node-children';for(const entry of value)group.append(renderDiscovery(entry,depth));return group}const node=document.createElement('article');node.className='tree-node';node.style.marginLeft=(depth*14)+'px';if(!value||typeof value!=='object'){node.textContent='--';return node}const kind=value.kind||value.type||value.layout||'content item';const title=value.title||value.text||value.label||value.name||value.id||'未命名节点';node.innerHTML='<div class="node-head"><span class="kind">'+escape(kind)+'</span><span class="node-title">'+escape(title)+'</span></div>';const fields=['id','author','target','collectionId','cursor','nextCursor','totalCount','count','rank','recommendation','description','value'];const facts=fields.filter(key=>value[key]!==undefined&&value[key]!==null).map(key=>key+'：'+text(value[key]));if(facts.length){const meta=document.createElement('div');meta.className='meta';meta.textContent=facts.join(' · ');node.append(meta)}if(value.cover){const cover=coverCard(value.cover);const row=document.createElement('div');row.className='book';row.style.marginTop='8px';row.append(cover.box,cover.probeState);node.append(row)}discoveryAction(value,node);const children=['document','components','children','items','content','tabs','categories','metric','continuation'];const rendered=children.filter(key=>value[key]!==undefined&&value[key]!==null);if(rendered.length){const group=document.createElement('div');group.className='node-children';for(const key of rendered){const child=renderDiscovery(value[key],depth+1);child.dataset.field=key;group.append(child)}node.append(group)}return node}
function showDiscovery(host,payload){host.className='tree';host.replaceChildren();const summary=document.createElement('p');summary.className='summary';summary.textContent='耗时 '+payload.elapsedMs+' ms · 已按 document / section / collection / list / carousel / content 递归渲染';host.append(summary,renderDiscovery(payload.result,0))}
by('search').onclick=async()=>{const host=by('search-view');host.className='loading';host.textContent='正在通过 Runtime 搜索…';try{const params=new URLSearchParams({pluginId:by('search-plugin').value,q:by('search-q').value,pageSize:by('search-size').value});const result=await api('/__debug/api/search?'+params);setRaw('search-raw',result);showBooks(host,result)}catch(error){viewError(host,error)}};
by('discover').onclick=async()=>{const host=by('discover-view');host.className='loading';host.textContent='正在通过 Runtime 加载发现…';try{const params=new URLSearchParams({pluginId:by('discover-plugin').value,target:by('discover-target').value,collectionId:by('discover-collection').value,cursor:by('discover-cursor').value,pageSize:by('discover-size').value});const result=await api('/__debug/api/discover?'+params);setRaw('discover-raw',result);showDiscovery(host,result)}catch(error){viewError(host,error)}};
void loadStatus();void loadPlugins();
</script></body></html>`;
