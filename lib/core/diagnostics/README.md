# App diagnostics core

This directory owns the Flutter/application-side diagnostics management contract.
It does not contain Runtime transport or HTTP interception.

Current implementation:

- bounded tagged `DiagnosticValue` and its stable codec;
- immutable event envelope, trace context and future-field preservation;
- event/schema registry for existing app infrastructure;
- process-scoped `DiagnosticsManager`, lazy enablement and exactly-one-terminal
  owner spans;
- query, capture, attachment, retention and export ports consumed by the
  storage and viewer features;
- a bounded priority-aware event queue with batch commits and aggregated drop
  reporting;
- app-owned, one-file-per-enabled-launch UTF-8 event TXT encoded in a background isolate;
- an 8 MiB bounded detail-memory spool with optional, explicit debug-only TXT
  persistence, SHA-256, range reads, leases and crash/staging reconciliation;
- explicit capture sessions with component/origin allowlists, duration, session,
  attachment and global quotas;
- metadata-only history listing, age/byte retention and selected-file cursor pagination;
- composition-root wiring plus bootstrap, lifecycle, route, settings,
  persistence, content-library, library-load and reader-launch instrumentation;
- a non-release VS Code/process debug-console mirror for the same
  schema-validated event envelopes persisted to TXT;
- a dedicated App viewer with cold file listing, selected-file paging, lazy 32 KiB plain
  text previews, bounded `memoryOnly` capture while open and explicit
  `persistToText` mode;
- sink-failure isolation, concurrent-close coordination and unchanged-value
  round-trip assertions for existing application critical paths.

The manager is injected from the app composition root. Features receive only the
narrow manager/query port they need. Production code must never construct event
names dynamically or bypass the single diagnostics lifecycle with `print`,
`debugPrint`, arbitrary files or direct SQL.

`AppDiagnosticsService` is the composition facade. Features receive its narrow
`DiagnosticsManager`, `DiagnosticsQuery`, `DiagnosticsCapture` or
`DiagnosticsMaintenance` view; TXT paths and detail keys are not part of the
public API. Encoding and selected-file decoding stay off the UI isolate, while
event admission remains synchronous, bounded and fail-open. Supplied event
values and captured detail bytes are stored unchanged; this module has no
privacy inspection or redaction pass.

D1 contracts, D2 app storage, D3 Runtime/HTTP instrumentation and the core D4
debugger are implemented. Incremental structured-tree navigation remains a
separate follow-up capability; file export is explicit and byte-preserving.
