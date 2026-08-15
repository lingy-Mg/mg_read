# AGENTS.md

## Current standard-Node plugin architecture scope

This repository owns the complete MgRead standalone Plugin Runtime: the Node
Runtime Core, platform adapters, Flutter-facing Runtime Facade, shared schema,
fixtures, Runtime Store and all plugin capabilities. The accepted replacement
architecture is ADR-0015 in this monorepo root. Plugins are
standard Node.js projects with `package.json.mgread`, npm lockfile v3, ordinary
multi-file output and ordinary `node_modules`; the former manifest/default-export
template fixture and its special CLI/RPC switch are obsolete and must not return.

The current implementation may use a Runtime-owned temporary data root in tests.
Production data-root resolution remains inside this package/platform adapter;
`mg_read` must never provide a path, database, Cookie, callback, HostPort or raw
transport object. Windows source-tree evidence does not claim Android/Javet,
macOS signing/package integration or final application packaging acceptance.

The cross-package architecture contract is maintained in the monorepo root at
../../docs/architecture/. The Runtime-specific entrypoint is
docs/standalone-runtime-contract.md and the ownership decision is
../../docs/architecture/adr/0008-standalone-plugin-runtime-boundary.md.
Before changing Runtime contracts, read those files plus the root architecture
README, 03-runtime-lifecycle.md, 05-transport-protocol.md and relevant ADRs.
This repository may not silently change an accepted MgRead ADR.

## Non-negotiable runtime rules

- One application process owns one Node Runtime and one V8 VM only.
- Android will use one Javet NodeRuntime on its dedicated background thread.
  The Android implementation must not introduce an engine pool, Worker, child
  process, second VM, or native Node addon. Windows/macOS use the separately
  specified single bundled Node child process owned by this Runtime.
- Windows and macOS will launch the exact Node version recorded in
  docs/runtime-version-matrix.md. They must not depend on a user's PATH or
  global Node installation.
- Runtime business traffic is WS control plane plus loopback HTTP data plane.
  stdio is limited to lifecycle, structured logging, and ready messages.
- Runtime owns all plugin/content persistence: installation/version state,
  library/metadata, reader state, bookmarks, downloads, cache, files, Cookie,
  plugin KV, settings and diagnostics. It must resolve and manage its own data
  root and Store; it must never receive a Flutter database path or connection.
- Runtime diagnostics follow root ADR-0016: only bounded UTF-8 `.txt`
  segments may be persisted. Default/key-only logging must never read, clone,
  serialize, buffer, or write HTTP bodies, HTML, JSON documents, novel content,
  or arbitrary object dumps. Those details are eligible only while an explicit,
  time/byte/allowlist-bounded debug session is active; they first enter a
  bounded memory spool, and only `persistToText` may create a detail TXT.
  Diagnostics must not create SQLite/WAL/binary indexes, and pressure or writer
  failure must never fail plugin/HTTP business work.
- Plugin diagnostics are mandatory end-to-end evidence, not optional console
  output. For every capability, Runtime must record control receipt/admission,
  queue wait, validation, dispatch, plugin invocation, cancellation/deadline
  handling and one terminal outcome. The plugin wrapper must preserve the
  Runtime trace relationship, and the script must use public `ctx.log` for
  small structured start/branch/fetch/parse/result/terminal phase events.
  `ctx.http` remains the only network path and owns HTTP lifecycle telemetry.
  Never log URLs, query values, request/response bodies, HTML, content, user
  input, credentials, Cookies, tokens or raw exceptions; use low-cardinality
  operation/count/byte/duration/error-code projections only. Capability work
  is incomplete unless tests cover correlated success plus applicable
  timeout/cancel/error events and secret/content canaries across Facade,
  Runtime and plugin layers.
- The main application may only call the versioned Runtime Facade. Do not add a
  HostPort, host.* RPC, callback, database/path, Cookie/file service or platform
  channel injection point as a shortcut. Implement required capabilities here
  or return a stable unsupported result until this repository owns them.
- Android Javet Adapter, desktop launcher, Runtime Supervisor, WS/HTTP client
  and server, resource handling and Flutter-facing integration are Runtime
  internals. They must not be implemented in the root application code.
- A loaded plugin is cold-activated only on the next application process start.
- Plugins use Node's standard module loader and share the one module cache. Do
  not create plugin VMs/Contexts, custom ESM loaders, dependency resolvers or
  module-instance isolation.

## Version and dependency policy

- Keep every version exact: Javet, Node, npm, TypeScript, and every npm
  dependency. Do not introduce range operators.
- Treat the Javet Android version and the desktop Node binary as an atomic
  compatibility unit. Do not update Node independently of Javet.
- Only pure JavaScript/TypeScript npm packages are allowed. A dependency that
  contains or builds a native addon requires explicit architecture approval.
- `package.json` plus npm `package-lock.json` v3 are the only plugin dependency
  contract. Do not add manifests, bundles, shared dependency declarations or a
  custom lock. Runtime restores the lock layout, stores registry packages by
  integrity, and uses hardlink with copy fallback to create normal node_modules.
- Runtime never executes install scripts or npm/pnpm. Git dependencies, native
  addons and package-external `file:` dependencies are unsupported. Full package
  resources, JSON, Wasm, templates and in-archive `file:` packages are retained.
- The Runtime Store backend is not selected in M1.1. Do not add a SQLite/native
  storage dependency merely to replace the old Flutter database; first record
  the cross-platform, no-native-addon and lifecycle probe evidence in the
  Runtime contract and version/probe documentation.
- Preserve the selected version evidence and pending probe boundaries in
  docs/runtime-version-matrix.md whenever the matrix changes.

## Repository layout

- src/ contains only Runtime Core code that is in scope for the current milestone.
- protocol/ contains compatibility metadata and the current standard-plugin
  desktop fixture, including the versioned rich content schema exercised by
  discover/search/detail/chapters/content. Broader cross-platform fixtures
  arrive with their platform capabilities.
- probes/ contains executable dependency audits and documented future platform
  probes. It is not production platform code.
- test/ contains small Node ESM tests. Do not make build output the source of
  truth.
- Future platform adapters, Runtime Store and Flutter integration packages belong
  in this repository and must remain behind the versioned Facade; do not create
  their implementation in the main application repository.
- `packages/mgread_plugin_runtime` is the Runtime-owned Flutter integration
  package. Its `desktopForTesting` and `debug*` APIs are test-only helpers, not
  permission to add a HostPort, main-app callback, path, database, Cookie or
  platform-channel injection surface.
- Runtime tests use standard-project fixtures under `test/fixtures`; they must
  exercise the same package/lock validation, install and cold-load path as
  production. The official author template is
  `../../templates/mg_read_plugin_template`, not a special Runtime module.

## Required verification

Use the exact Node and npm versions pinned by .node-version and package.json.
For an implementation change, run:

~~~
npm ci
npm run typecheck
npm test
npm run check:no-native-addons
~~~

For desktop communication changes also run `npm run test:flutter-desktop`.
Node tests must cover package/lock validation, archive safety, integrity,
hardlink/copy fallback, cold activation/rollback, GC and plugin invocation. The
Flutter command must exercise a typed Facade call through the same installed
standard plugin path. They cover the current Windows desktop host only. Do not
report Android/Javet or macOS acceptance from them.

Report separately which checks ran on the current host and which Android or
macOS probes remain unrun. Do not call static checks a platform lifecycle
acceptance.

## Git and scope discipline

- Keep this package independent from root application code. A Runtime-only task
  must not edit root app, reader-plugin or template code without explicit approval.
- Inspect git status before editing. Preserve unrelated changes.
- Do not commit unless explicitly asked. When asked to commit, stage only
  task-owned files.
