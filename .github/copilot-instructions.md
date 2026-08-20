# MgRead AI instructions

Start with the repository [AGENTS.md](../AGENTS.md), then use
[docs/development/README.md](../docs/development/README.md) to load only the
documents required by the current task. Do not preload all architecture or ADR
files.

This is one monorepo: the root is the Flutter application,
`packages/mg_read_reader_ui` is the reader plugin, and
`packages/mg_read_runtime` owns the plugin Runtime and its internal transport.
Preserve unrelated working-tree changes and follow the nearest nested
`AGENTS.md` for package-specific deltas.
