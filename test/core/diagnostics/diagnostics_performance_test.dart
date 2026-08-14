import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'diagnostics_testkit.dart';

void main() {
  test(
    'reports disabled and persistent diagnostics performance baselines',
    () async {
      const disabledEventCount = 50000;
      const enabledEventCount = 20000;
      final disabledSink = RecordingDiagnosticEventSink(
        minimumSeverity: DiagnosticSeverity.fatal,
      );
      final disabledManager = DiagnosticsManager(
        sink: disabledSink,
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
        idGenerator: SequentialDiagnosticIdGenerator(),
        clock: FixedDiagnosticClock(),
        sourceRunId: 'run_000000000000000000009000',
      );
      var disabledBuilderCalls = 0;
      final disabledLatencies = <int>[];
      final disabledTotal = Stopwatch()..start();
      for (var index = 0; index < disabledEventCount; index += 1) {
        final call = Stopwatch()..start();
        disabledManager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () {
            disabledBuilderCalls += 1;
            return DiagnosticObjectValue(<String, DiagnosticValue>{
              'toRoute': DiagnosticValue.string('library'),
            });
          },
        );
        call.stop();
        disabledLatencies.add(call.elapsedMicroseconds);
      }
      disabledTotal.stop();
      await disabledManager.close();

      final root = await Directory.systemTemp.createTemp(
        'mg-read-diagnostics-benchmark-',
      );
      final rssBefore = ProcessInfo.currentRss;
      final service = await AppDiagnosticsService.open(
        dataRoot: root,
        configuration: const PersistentDiagnosticsConfiguration(
          maxQueueEvents: 8192,
          maxQueueBytes: 8 * 1024 * 1024,
          priorityReservedEvents: 512,
          priorityReservedBytes: 1024 * 1024,
        ),
        idGenerator: SequentialDiagnosticIdGenerator(),
        clock: FixedDiagnosticClock(),
        buildMode: 'benchmark',
        platform: 'windows-test',
      );
      try {
        final enabledLatencies = <int>[];
        final enabledTotal = Stopwatch()..start();
        for (var index = 0; index < enabledEventCount; index += 1) {
          final call = Stopwatch()..start();
          service.manager.emit(
            AppDiagnosticEvents.routeChanged,
            attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
              'toRoute': DiagnosticValue.string('library'),
            }),
          );
          call.stop();
          enabledLatencies.add(call.elapsedMicroseconds);
        }
        final rssAfterAdmission = ProcessInfo.currentRss;
        await service.manager.flush(timeout: const Duration(seconds: 15));
        enabledTotal.stop();
        final rssAfterFlush = ProcessInfo.currentRss;
        final writer = service.writerStatistics;
        final storage = await service.getStatistics();
        final report = <String, Object?>{
          'disabled': _latencyReport(
            disabledLatencies,
            disabledTotal.elapsedMicroseconds,
          ),
          'enabled': _latencyReport(
            enabledLatencies,
            enabledTotal.elapsedMicroseconds,
          ),
          'writer': <String, Object?>{
            'accepted': writer.acceptedEvents,
            'committed': writer.committedEvents,
            'dropped': writer.droppedEvents,
            'queueHighWater': writer.queueHighWater,
            'queueByteHighWater': writer.queueByteHighWater,
            'lastBatchSize': writer.lastBatchSize,
            'lastCommitMicros': writer.lastCommitMicros,
            'writerErrors': writer.writerErrors,
            'encodingOffloaded': writer.eventEncodingOffloaded,
          },
          'storage': <String, Object?>{
            'events': storage.eventCount,
            'segments': storage.segmentCount,
            'eventTextBytes': storage.eventTextBytes,
            'detailTextBytes': storage.detailTextBytes,
            'memoryDetailBytes': storage.memoryDetailBytes,
            'physicalBytes': storage.physicalStoredBytes,
          },
          'memory': <String, Object?>{
            'rssBefore': rssBefore,
            'rssAfterAdmission': rssAfterAdmission,
            'rssAfterFlush': rssAfterFlush,
            'observedPeak': max(
              rssBefore,
              max(rssAfterAdmission, rssAfterFlush),
            ),
            'rssDelta': rssAfterFlush - rssBefore,
          },
        };
        stdout.writeln('MG_READ_DIAGNOSTICS_BENCHMARK ${jsonEncode(report)}');

        expect(disabledBuilderCalls, 0);
        expect(writer.queueHighWater, lessThanOrEqualTo(8192));
        expect(writer.queueByteHighWater, lessThanOrEqualTo(8 * 1024 * 1024));
        expect(writer.writerErrors, 0, reason: writer.lastWriterFailureType);
        expect(writer.eventEncodingOffloaded, isTrue);
        expect(storage.physicalStoredBytes, lessThan(64 * 1024 * 1024));
      } finally {
        await service.close();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Map<String, Object> _latencyReport(List<int> samples, int elapsedMicros) {
  final sorted = List<int>.of(samples)..sort();
  int percentile(double value) {
    final index = ((sorted.length - 1) * value).round();
    return sorted[index];
  }

  return <String, Object>{
    'count': samples.length,
    'elapsedMicros': elapsedMicros,
    'throughputPerSecond': elapsedMicros == 0
        ? 0
        : (samples.length * Duration.microsecondsPerSecond / elapsedMicros)
              .round(),
    'p50Micros': percentile(0.50),
    'p95Micros': percentile(0.95),
    'p99Micros': percentile(0.99),
  };
}
