# MgRead Plugin Cache

`@mgread/plugin-cache` is a small Node 24 ESM library for standard MgRead
content-source plugins. It keeps bounded, atomic, SHA-256-keyed text and
validated JSON projection records under the Runtime-provided absolute
`ctx.cacheDir` only.

It is deliberately not published to npm. Every source declares the one shared
repository package as `file:../../../packages/mg_read_plugin_cache`. `npm ci`
links that one source into the development dependency graph; the single-file
packager still bundles it into each self-contained artifact. There is no
per-source `packages/mgread-plugin-cache` copy or sync step.

Pass the plugin context's `log` object as `logger` to emit bounded cache
lifecycle events into Runtime Debug. Cache logging never changes cache results.

Use `serveStaleWhileRevalidate` for low-volatility discovery list/detail
projections so an old projection renders immediately and one background refresh
updates the next visit. Use `allowStaleOnError: false` for a user-opened detail
or catalog that requires a strict maximum age. Never cache chapter text, media,
Cookie, credentials or raw user input. JSON callers must provide a decoder;
invalid records become cache misses.
