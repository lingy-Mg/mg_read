# AGENTS.md

This package is one real MgRead content-source plugin, not a Runtime or an
application feature.

- Keep the standard Node 24 project format: `package.json.mgread`, lockfile v3,
  normal multi-file ESM output, and the six named Plugin API v1 exports.
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
- `npm run test:live` is an explicit online smoke test required for a source
  change: it calls the target's category, search, detail, catalog, and content
  URLs without saving returned HTML or chapter content. Do not turn it into a
  routine CI dependency.

Before delivery use the Node 24.16.0 toolchain from
`../mg_read_runtime/tools/node-v24.16.0-win-x64`, then run `npm ci` and
`npm run verify`.
