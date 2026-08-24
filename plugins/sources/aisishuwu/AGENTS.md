# AGENTS.md

The monorepo root `../../../AGENTS.md` applies. For this source task, read only
this file, the root plugin content contract, and this package README/tests; do
not preload unrelated app or Runtime internals.

This package is one real MgRead content-source plugin, not a Runtime or an
application feature.

- Keep the standard Node 24 project format: `package.json.mgread`, lockfile v3,
  normal multi-file ESM output, the six required Plugin API v1 exports, and
  the optional `searchSuggestions` extension when this source supplies hot terms.
- Production code may use only the public `ctx.http`, `ctx.log`, `ctx.dataDir`,
  and `ctx.cacheDir` capabilities. Never depend on Runtime paths, wire DTOs,
  test launchers, host callbacks, or the main application's database.
- IDs and cursors are plugin-owned opaque values. A site URL is metadata only,
  never the ID passed across the Plugin API boundary.
- Keep every response field required by the v1 contract. Nullable values are
  explicit `null`; collections are always arrays.
- Do not log URLs, search terms, titles, HTML, or chapter text. Never add
  credentials, cookie exports, login automation, anti-bot bypasses, Workers,
  child processes, native addons, Git dependencies, or install scripts.
- Logging is required for every `activate`, `discover`, `search`, `searchSuggestions`, `getDetail`,
  `getChapters` and `getContent` execution. Use only structured `ctx.log`
  phase events for start, validation/branch, remote-fetch handoff, parsing,
  result count/byte projection and exactly one terminal outcome. Runtime owns
  the trace/span relationship and `ctx.http` owns HTTP lifecycle telemetry;
  do not use `console.*`, custom files, URLs/query values, user input, titles,
  HTML/content, credentials, Cookies, tokens or raw exceptions in logs.
- Source changes must extend tests to assert script-stage events can be
  correlated with the Runtime invocation and HTTP terminal event for success,
  plus the applicable timeout/cancel/error case. Include a secret/content
  canary proving prohibited values are absent from default diagnostics.
- `npm test` is the mandatory deterministic offline regression for every source
  change; it must not depend on the target website. `npm run verify` is the
  delivery gate and includes typecheck, offline tests and packaging.
- `npm run test:live` is an explicit online smoke test required after source
  parsing/request changes: it calls the target's category, search, detail,
  catalog, and content URLs without saving returned HTML or chapter content.
  Do not turn it into a routine CI dependency, but do not claim the source
  change is complete when this evidence is absent or failed.
- Windows Debug can load this built workspace directly: run the source
  build/watch command, then call the source from the desktop Debug app. This
  verifies development Runtime loading and does not replace Node tests, live
  smoke, or Android packaged-plugin acceptance.

Before delivery use the Node 24.16.0 toolchain from
`../../../packages/mg_read_runtime/tools/node-v24.16.0-win-x64`, then run `npm ci`,
`npm test`, `npm run verify`, and the applicable `npm run test:live`.
