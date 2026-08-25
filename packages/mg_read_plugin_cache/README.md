# MgRead Plugin HTML Cache

`@mgread/plugin-html-cache` is a small Node 24 ESM library for standard MgRead
content-source plugins. It keeps bounded, atomic, SHA-256-keyed HTML cache
records under the Runtime-provided absolute `ctx.cacheDir` only.

It is deliberately not published to npm. A source declares the local package
as `file:./packages/mgread-plugin-html-cache`; its build runs
`tools/sync_plugin_html_cache.mjs`, and `mgread pack` automatically includes
that `packages/` directory in the `.mgplugin`. Runtime then restores it as the
ordinary locked `node_modules/@mgread/plugin-html-cache` dependency during
installation, with no network download or install script.

Use `serveStaleWhileRevalidate` only for low-volatility discovery projections.
Use `allowStaleOnError: false` for detail and catalog paths that require a
strict maximum age.
