# MgRead Plugin Cache

`@mgread/plugin-cache` is a small Node 24 ESM library for standard MgRead
content-source plugins. It keeps bounded, atomic, SHA-256-keyed text and
validated JSON projection records under the Runtime-provided absolute
`ctx.cacheDir` only.

It is deliberately not published to npm. A source declares the local package
as `file:./packages/mgread-plugin-cache`; its build runs
`tools/sync_plugin_cache.mjs`, and `mgread pack` automatically includes
that `packages/` directory in the `.mgplugin`. Runtime then restores it as the
ordinary locked `node_modules/@mgread/plugin-cache` dependency during
installation, with no network download or install script.

Use `serveStaleWhileRevalidate` for low-volatility discovery list/detail
projections so an old projection renders immediately and one background refresh
updates the next visit. Use `allowStaleOnError: false` for a user-opened detail
or catalog that requires a strict maximum age. Never cache chapter text, media,
Cookie, credentials or raw user input. JSON callers must provide a decoder;
invalid records become cache misses.
