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
- query, capture, attachment, retention and export ports consumed by the
  storage and viewer features;
- a bounded priority-aware event queue with batch commits and aggregated drop
  reporting;
- app-owned, bounded UTF-8 event TXT segments encoded in a background isolate;
- an 8 MiB bounded detail-memory spool with optional, explicit debug-only TXT
  persistence, SHA-256, range reads, leases and crash/staging reconciliation;
- explicit capture sessions with component/origin allowlists, duration, session,
  attachment and global quotas;
- age/byte retention, TXT rotation/tail recovery and stable cursor pagination;
- composition-root wiring plus bootstrap, lifecycle, route, settings,
  persistence, content-library, library-load and reader-launch instrumentation;
- a dedicated app/Runtime viewer with separate paged feeds, lazy 32 KiB plain
  text previews, bounded `memoryOnly` capture while open and explicit
  `persistToText` mode;
- sink-failure isolation, concurrent-close coordination and secret-canary
  assertions for existing application critical paths.

The manager is injected from the app composition root. Features receive only the
narrow manager/query port they need. Production code must never construct event
names dynamically, retain raw exceptions, or bypass the privacy policy with
`print`, `debugPrint`, arbitrary files or direct SQL.

`AppDiagnosticsService` is the composition facade. Features receive its narrow
`DiagnosticsManager`, `DiagnosticsQuery`, `DiagnosticsCapture` or
`DiagnosticsMaintenance` view; TXT paths and detail keys are not part of the
public API. Encoding, text-catalog rebuild and hashing stay off the UI
isolate, while event admission remains synchronous, bounded and fail-open.

D1 contracts, D2 app storage, D3 Runtime/HTTP instrumentation and the core D4
debugger are implemented. Incremental structured-tree navigation and explicit
export remain separate follow-up capabilities. `restrictedRaw` remains
deliberately disabled until the separately reviewed encrypted D5 store exists.
