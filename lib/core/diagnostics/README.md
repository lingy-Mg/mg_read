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
  storage and viewer packages.

The manager is injected from the app composition root. Features receive only the
narrow manager/query port they need. Production code must never construct event
names dynamically, retain raw exceptions, or bypass the privacy policy with
`print`, `debugPrint`, arbitrary files or direct SQL.

The persistent app sink and object store belong to the D2 implementation. Runtime
diagnostics remain owned by `../mg_read_runtime` and are consumed only through its
versioned facade.
