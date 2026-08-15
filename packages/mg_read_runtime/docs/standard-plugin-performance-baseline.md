# Standard plugin invocation performance baseline

Snapshot: 2026-08-14, Windows x64, pinned Node 24.16.0, source-tree build. Command:

```powershell
npm run benchmark:plugin
```

The probe installs the standard fixture in a fresh temporary Runtime data root,
warms 100 calls, then measures 1,000 successful searches. `metadataOnly` uses the
real `RuntimeDiagnosticsService` segmented-text writer and one registered
`runtime.plugin-invoke` start/terminal pair per call; total time includes the final
bounded writer flush. Payload capture is off.

| mode | p50 | p95 | p99 | throughput | peak heap | queue HWM | drops | disk growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| diagnostics disabled | 0.0024 ms | 0.0063 ms | 0.0164 ms | 218,060/s | 10,898,272 B | 0 | 0 | 0 B |
| default `metadataOnly` | 0.0157 ms | 0.0375 ms | 0.0666 ms | 23,702/s | 13,916,488 B | 2,000 | 0 | 1,672,493 B |

Interpretation:

- The measured median enqueue overhead is about 0.013 ms per call; p99 remains
  below 0.07 ms for this trivial local plugin.
- The diagnostics run intentionally bursts 2,000 events before the final flush,
  so queue high-water reaches 2,000 but remains below the fixed 4,096-event cap;
  no event is dropped and the queue is empty after flush.
- TXT append/flush and file growth dominate end-to-end throughput. Regular event
  retention remains bounded by the diagnostics service policy; this probe does
  not authorize per-item, per-frame, per-network-chunk, or payload logging.
- Negative post-GC heap deltas are omitted because they reflect collection
  timing; peak heap is the comparable memory measure.

This baseline is reproducible evidence for the current source build, not Android
Javet, macOS, release-mode, final package, or remote-network performance.

## Flutter Facade inspect baseline

`flutter test test/facade_performance_test.dart --reporter expanded` in the
Runtime-owned Flutter package starts a real Node child, concurrently invokes ping
and plugin list, then repeats that inspect 100 times:

| cold inspect | warm p50 | warm p95 | warm p99 | Flutter test-process peak RSS | Runtime data growth |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 155.097 ms | 1.063 ms | 1.781 ms | 2.707 ms | 139,997,184 B | 361,415 B |

The main app's 2-second `runtimeFacade` slow threshold is therefore deliberately
about thirteen times this source-tree cold baseline to absorb host and package I/O
variance while still surfacing a visibly slow start. RSS is the Flutter test
process only; it is not combined Flutter+Node memory evidence.
