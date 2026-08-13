# MgRead AI instructions

The canonical development instructions are in [AGENTS.md](../AGENTS.md). Read and follow them before editing this repository.

In particular, treat this repository as the Flutter host application and `novel_reader_ui` as a sibling plugin dependency. Import only the plugin's public entry point, keep book data and persisted reader state in host-owned adapters, and preserve unrelated working-tree changes.
