import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

void main() {
  test(
    'reports source-tree Facade cold and warm inspect performance',
    () async {
      final repository = nodeRuntimeRepositoryRoot;
      final dataRoot = await Directory.systemTemp.createTemp(
        'mgread-facade-performance-',
      );
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repository,
        runtimeDataRoot: dataRoot,
      );
      try {
        final diskBefore = await _directoryBytes(dataRoot);
        final rssBefore = ProcessInfo.currentRss;
        var peakRss = rssBefore;

        final cold = Stopwatch()..start();
        await _inspect(runtime);
        cold.stop();

        final samples = <int>[];
        for (var index = 0; index < 100; index += 1) {
          final stopwatch = Stopwatch()..start();
          await _inspect(runtime);
          stopwatch.stop();
          samples.add(stopwatch.elapsedMicroseconds);
          peakRss = peakRss < ProcessInfo.currentRss
              ? ProcessInfo.currentRss
              : peakRss;
        }
        samples.sort();
        final diskAfter = await _directoryBytes(dataRoot);
        final report = <String, Object>{
          'coldInspectMs': cold.elapsedMicroseconds / 1000,
          'warmIterations': samples.length,
          'warmP50Ms': _percentile(samples, 0.50) / 1000,
          'warmP95Ms': _percentile(samples, 0.95) / 1000,
          'warmP99Ms': _percentile(samples, 0.99) / 1000,
          'peakRssBytes': peakRss,
          'rssDeltaBytes': ProcessInfo.currentRss - rssBefore,
          'runtimeDataGrowthBytes': diskAfter - diskBefore,
        };
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));

        expect(cold.elapsed, lessThan(const Duration(seconds: 5)));
        expect(samples, hasLength(100));
      } finally {
        await runtime.debugDispose();
        await dataRoot.delete(recursive: true);
      }
    },
  );
}

Future<void> _inspect(PluginRuntime runtime) async {
  await Future.wait<Object>(<Future<Object>>[
    runtime.invoke(const RuntimePingInvocation()),
    runtime.invoke(const InstalledPluginsInvocation()),
  ]);
}

int _percentile(List<int> values, double quantile) {
  final index = ((values.length * quantile).ceil() - 1).clamp(
    0,
    values.length - 1,
  );
  return values[index];
}

Future<int> _directoryBytes(Directory root) async {
  var total = 0;
  if (!await root.exists()) return total;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) total += await entity.length();
  }
  return total;
}
