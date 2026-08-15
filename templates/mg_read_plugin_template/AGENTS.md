# AGENTS.md

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
- Plugin API v1 uses the six named exports
  `activate/discover/search/getDetail/getChapters/getContent`. Content objects
  keep every fixed nullable key and use explicit `null`; collections always use
  arrays, while missing keys, `undefined`, blank sentinel strings and arbitrary
  metadata maps are invalid.
- Do not add a real source, credentials, account flow, or network target to the
  blank template. Tests must remain deterministic and local.

Before delivery run the pinned Node/npm toolchain, `npm ci`, `npm run verify`,
and `npm run pack:plugin`.
