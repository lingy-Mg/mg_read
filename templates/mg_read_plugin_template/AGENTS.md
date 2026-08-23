# AGENTS.md

The monorepo root `../../AGENTS.md` applies. For template work, read only this
file, this package README, and the root standard-plugin/content-contract docs
that the change affects.

This repository is the official blank MgRead plugin project template.

- A plugin is a standard Node.js 24 project. `package.json.mgread` is the only
  MgRead metadata source and npm `package-lock.json` v3 is the only exact
  dependency graph.
- Never add `manifest.json`, bundle output, `sharedDependencies`,
  `bundledDependencies`, a custom dependency lock, a plugin VM, or a custom
  module loader.
- TypeScript is compiled by `tsc` into ordinary multiple files under `dist/`.
- Keep all versions exact. Runtime dependencies must be pure JS/ESM/CommonJS;
  Git dependencies, install-time native builds, and native addons are not
  supported. `file:` dependencies must stay under `packages/`.
- `.mgplugin` is only a ZIP transport container and must not contain
  `node_modules`.
- Plugin API v1 uses the six required named exports
  `activate/discover/search/getDetail/getChapters/getContent`; sources that can
  provide hot terms may additionally export `searchSuggestions`. Content objects
  keep every fixed nullable key and use explicit `null`; collections always use
  arrays, while missing keys, `undefined`, blank sentinel strings and arbitrary
  metadata maps are invalid.
- Do not add a real source, credentials, account flow, or network target to the
  blank template. Tests must remain deterministic and local.
- Every production plugin capability must use public `ctx.log` for structured
  phase events (start, validation/branch, fetch handoff, parse, result
  projection and exactly one terminal outcome). Runtime supplies the trace/span
  relationship and `ctx.http` owns HTTP lifecycle logging; never use
  `console.*`, custom log files, URLs/query values, user input, body/HTML/text,
  credentials, Cookies, tokens or raw exceptions. Capability tests must assert
  correlated script/Runtime events for success and applicable
  timeout/cancel/error paths, with secret/content canaries.
- Cache only cacheable, repeatable remote GET display projections: discovery/search
  lists refresh after 10 minutes, and detail/catalog projections after 1 hour.
  Cache under a versioned child of the Runtime-provided absolute `ctx.cacheDir`
  only, using hashed request keys, atomic writes, a 1 MiB-entry/100 MiB-plugin
  LRU limit, single-flight requests and stale data only after refresh failure.
  Never cache chapter/media bytes, login/Cookie/credential data, write responses,
  or app-owned business data. Cache I/O/corruption/eviction failures are misses,
  not capability failures; tests cover persistence, TTL, offline fallback,
  capacity and the directory boundary.

Before delivery run the pinned Node/npm toolchain, `npm ci`, `npm run verify`,
and `npm run pack:plugin`.
