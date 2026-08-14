# App diagnostics core

This directory owns the Flutter/application-side diagnostics management contract.
It does not contain Runtime transport or HTTP interception.

Current implementation:

- bounded tagged `DiagnosticValue` and its stable codec;
- immutable event envelope, trace context and future-field preservation;
- event/schema registry for existing app infrastructure;
- central privacy policy for secret fields, URLs, headers and stack fingerprints;
- process-scoped `DiagnosticsManager`, lazy enablement and exactly-one-terminal
  owner spans;
- query, capture, attachment, retention and export ports consumed by later
  storage and viewer packages;
- a bounded priority-aware event queue with batch commits and aggregated drop
  reporting;
- an app-owned Drift/SQLite index running on a background executor;
- immutable content-addressed attachment objects, streaming limits, SHA-256,
  range reads, reader leases and crash/staging reconciliation;
- explicit capture sessions with component/origin allowlists, duration, session,
  attachment and global quotas;
- age/byte retention, WAL checkpointing and stable cursor pagination.

The manager is injected from the app composition root. Features receive only the
narrow manager/query port they need. Production code must never construct event
names dynamically, retain raw exceptions, or bypass the privacy policy with
`print`, `debugPrint`, arbitrary files or direct SQL.

`AppDiagnosticsService` is the composition facade. Features receive its narrow
`DiagnosticsManager`, `DiagnosticsQuery`, `DiagnosticsCapture` or
`DiagnosticsMaintenance` view; database paths, direct SQL and object keys are not
part of the public API. Encoding, SQLite work and file hashing stay off the UI
isolate, while event admission remains synchronous, bounded and fail-open.

D1 contracts and D2 app storage are implemented here. Runtime/HTTP instrumentation
remains owned by `../mg_read_runtime` (D3). Structured-tree rendering, export and
the dedicated debugger UI arrive in D4. `restrictedRaw` remains deliberately
disabled until the separately reviewed encrypted D5 store exists.
