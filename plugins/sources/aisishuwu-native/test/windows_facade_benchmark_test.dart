/// Opt-in paired live benchmark for the installed Alice JS and native Facades.
/// Each measured method gets a fresh worker and cleared persistent cache; the
/// report contains timing, memory, counts, and content hashes only.
// ignore_for_file: invalid_use_of_visible_for_testing_member
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

const _bookId = 'novel:52801';
const _nativePluginId = 'org.mgread.aisishuwu.native';
const _nativeVersion = '0.1.0';
const _javascriptNodeVersion = '26.10.0';
const _operations = <String>['detail', 'catalog', 'content'];
final _unicodeWhitespace = RegExp(r'[\u0009-\u000D\u001C-\u001F\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]');

void main() {
  test(
    'paired live JS and native Alice Facade timings',
    () async {
      final root = Directory.current.absolute;
      final nativeRuntimeHost = File(
        _path(root, <String>['packages', 'mg_read_native_runtime', 'dist', 'windows-x86_64', 'mgread-native-host.exe']),
      );
      final nativeArtifact = File(
        _path(root, <String>['plugins', 'sources', 'aisishuwu-native', 'dist', 'aisishuwu-native-$_nativeVersion.mgplugin']),
      );
      final javascriptSourceRoot = Directory(_path(root, <String>['plugins', 'sources', 'aisishuwu']));
      final nodeRuntimeRoot = Directory(_path(root, <String>['packages', 'mg_read_node_runtime']));
      final pinnedNode = File(_path(nodeRuntimeRoot, <String>['tools', 'node-v26.10.0-win-x64', 'node.exe']));
      expect(await nativeRuntimeHost.exists(), isTrue);
      expect(await nativeArtifact.exists(), isTrue);
      expect(await pinnedNode.exists(), isTrue);

      final packageManifest =
          jsonDecode(await File(_path(javascriptSourceRoot, <String>['package.json'])).readAsString()) as Map<String, Object?>;
      final sourceManifest = packageManifest['mgread']! as Map<String, Object?>;
      final javascriptPluginId = sourceManifest['id']! as String;
      final javascriptVersion = packageManifest['version']! as String;
      final javascriptArtifact = File(
        _path(javascriptSourceRoot, <String>['artifacts', '$javascriptPluginId-$javascriptVersion.mgplugin.js']),
      );
      expect(await javascriptArtifact.exists(), isTrue);

      final nativeDataRoot = await Directory.systemTemp.createTemp('mgread-alice-native-bench-');
      final javascriptDataRoot = await Directory.systemTemp.createTemp('mgread-alice-js-bench-');
      addTearDown(() async {
        try {
          await _removeTemporaryRoot(nativeDataRoot);
        } finally {
          await _removeTemporaryRoot(javascriptDataRoot);
        }
      });

      final nativeBytes = await nativeArtifact.readAsBytes();
      final javascriptBytes = await javascriptArtifact.readAsBytes();
      final proxy = _environmentProxy();

      // Install through the public transfer API, then dispose these setup
      // workers. Every benchmark sample starts a fresh installed worker.
      final nativeInstaller = _nativeRuntime(nativeRuntimeHost, nativeDataRoot);
      try {
        await _installArtifact(
          nativeInstaller,
          bytes: nativeBytes,
          pluginId: _nativePluginId,
          version: _nativeVersion,
          format: PluginArtifactFormat.archive,
        );
      } finally {
        await nativeInstaller.debugDispose();
      }
      final javascriptInstaller = _javascriptRuntime(nodeRuntimeRoot, pinnedNode, javascriptDataRoot);
      try {
        await _installArtifact(
          javascriptInstaller,
          bytes: javascriptBytes,
          pluginId: javascriptPluginId,
          version: javascriptVersion,
          format: PluginArtifactFormat.singleFile,
        );
      } finally {
        await javascriptInstaller.debugDispose();
      }

      // Resolve one identical chapter ID before measurement. These preflight
      // workers are discarded so their in-memory caches cannot warm samples.
      final nativePreflight = _nativeRuntime(nativeRuntimeHost, nativeDataRoot);
      late final String firstChapterId;
      try {
        await nativePreflight.configurePluginHttpProxy(proxy);
        final catalog = await nativePreflight.invoke(const SourceChaptersInvocation(pluginId: _nativePluginId, id: _bookId));
        expect(catalog.items, isNotEmpty);
        firstChapterId = catalog.items.first.id;
      } finally {
        await nativePreflight.debugDispose();
      }
      final javascriptPreflight = _javascriptRuntime(nodeRuntimeRoot, pinnedNode, javascriptDataRoot);
      try {
        await javascriptPreflight.configurePluginHttpProxy(proxy);
        final catalog = await javascriptPreflight.invoke(SourceChaptersInvocation(pluginId: javascriptPluginId, id: _bookId));
        expect(catalog.items, isNotEmpty);
        expect(catalog.items.first.id, firstChapterId);
      } finally {
        await javascriptPreflight.debugDispose();
      }

      final pairResults = <Map<String, Object?>>[];
      for (var pairIndex = 0; pairIndex < 3; pairIndex += 1) {
        final order = pairIndex.isEven ? <String>['native', 'javascript'] : <String>['javascript', 'native'];
        final measurements = <String, Map<String, _Measurement>>{
          'native': <String, _Measurement>{},
          'javascript': <String, _Measurement>{},
        };
        final executionOrder = <String>[];
        for (final operation in _operations) {
          for (final backend in order) {
            executionOrder.add('$backend:$operation');
            measurements[backend]![operation] = await _measureOperation(
              backend: backend,
              operation: operation,
              firstChapterId: firstChapterId,
              nativeRuntimeHost: nativeRuntimeHost,
              nodeRuntimeRoot: nodeRuntimeRoot,
              pinnedNode: pinnedNode,
              nativeDataRoot: nativeDataRoot,
              javascriptDataRoot: javascriptDataRoot,
              javascriptPluginId: javascriptPluginId,
              proxy: proxy,
            );
          }
        }

        final native = measurements['native']!;
        final javascript = measurements['javascript']!;
        pairResults.add(<String, Object?>{
          'pair': pairIndex + 1,
          'executionOrder': executionOrder,
          'native': _measurementsJson(native),
          'javascript': _measurementsJson(javascript),
          'outputParity': <String, Object?>{
            'detailChapterCount': native['detail']!.observed['chapterCount'] == javascript['detail']!.observed['chapterCount'],
            'catalogIdsSha256': native['catalog']!.observed['catalogIdsSha256'] == javascript['catalog']!.observed['catalogIdsSha256'],
            'contentSha256': native['content']!.observed['contentSha256'] == javascript['content']!.observed['contentSha256'],
            'contentWhitespaceNormalizedSha256':
                native['content']!.observed['contentWhitespaceNormalizedSha256'] ==
                javascript['content']!.observed['contentWhitespaceNormalizedSha256'],
          },
        });
      }

      final report = <String, Object?>{
        'benchmark': 'windows-public-facade-live-http',
        'bookId': _bookId,
        'firstChapterIdSha256': sha256.convert(utf8.encode(firstChapterId)).toString(),
        'pairCount': pairResults.length,
        'proxyConfigured': proxy != null,
        'proxyPolicy': 'same sanitized endpoint passed to both facades',
        'cachePolicy':
            'each case clears persistent plugin cache on a worker, disposes it, then recreates the same backend on the same data root; cache clear excluded',
        'timingPolicy':
            'startup includes runtime creation, proxy configuration, and first ping; source operation starts after startup and status sampling',
        'contentHashPolicy': <String, Object?>{
          'raw': 'SHA-256 of the UTF-8 content text; preserves whitespace',
          'whitespaceNormalized':
              'Remove U+0009-U+000D, U+001C-U+001F, U+0020, U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028-U+2029, U+202F, U+205F, and U+3000; then SHA-256 the UTF-8 text. Raw hash remains reported.',
        },
        'javascript': <String, Object?>{
          'pluginId': javascriptPluginId,
          'pluginVersion': javascriptVersion,
          'nodeVersion': _javascriptNodeVersion,
        },
        'native': <String, Object?>{'pluginId': _nativePluginId, 'pluginVersion': _nativeVersion},
        'pairedSamples': pairResults,
        'mediansMs': _medianSummary(pairResults),
        'performanceWinner': null,
      };
      final reportDirectory = Directory(_path(root, <String>['plugins', 'sources', 'aisishuwu-native', 'artifacts', 'native-runtime']));
      await reportDirectory.create(recursive: true);
      await File(
        _path(reportDirectory, <String>['windows-facade-benchmark.json']),
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip:
        !Platform.isWindows ||
        Platform.environment['MGREAD_NATIVE_FACADE_BENCHMARK'] != '1' ||
        !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME'),
  );
}

PluginRuntime _nativeRuntime(File host, Directory dataRoot) =>
    PluginRuntime.nativeForTesting(executablePath: host.path, dataRoot: dataRoot.path, testMode: false);

PluginRuntime _javascriptRuntime(Directory runtimeRoot, File nodeExecutable, Directory dataRoot) =>
    PluginRuntime.desktopForTesting(runtimeRepositoryRoot: runtimeRoot, runtimeDataRoot: dataRoot, nodeExecutableOverride: nodeExecutable);

Future<void> _installArtifact(
  PluginRuntime runtime, {
  required List<int> bytes,
  required String pluginId,
  required String version,
  required PluginArtifactFormat format,
}) async {
  final result = await runtime.importPluginArtifacts(<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>[
    (
      artifact: PluginTransferArtifact(
        bytes: bytes.length,
        developmentFingerprint: null,
        developmentRevision: null,
        format: format,
        pluginId: pluginId,
        provenance: PluginArtifactProvenance.installed,
        checksum: _crc32(bytes),
        version: version,
      ),
      bytes: Stream<List<int>>.value(bytes),
    ),
  ]);
  expect(result, hasLength(1));
}

Future<_Measurement> _measureOperation({
  required String backend,
  required String operation,
  required String firstChapterId,
  required File nativeRuntimeHost,
  required Directory nodeRuntimeRoot,
  required File pinnedNode,
  required Directory nativeDataRoot,
  required Directory javascriptDataRoot,
  required String javascriptPluginId,
  required Uri? proxy,
}) async {
  final native = backend == 'native';
  final pluginId = native ? _nativePluginId : javascriptPluginId;

  // Clear durable cache from a disposable worker. The measurement worker is
  // then created from the same backend and data root, so neither its in-memory
  // maps nor its runtime process has seen a source request for this case.
  final resetRuntime = native
      ? _nativeRuntime(nativeRuntimeHost, nativeDataRoot)
      : _javascriptRuntime(nodeRuntimeRoot, pinnedNode, javascriptDataRoot);
  try {
    await resetRuntime.configurePluginHttpProxy(proxy);
    await resetRuntime.invoke(const RuntimePingInvocation());
    final cleared = await resetRuntime.invoke(ClearPluginCacheInvocation(pluginId: pluginId));
    expect(cleared.items, hasLength(1));
    expect(cleared.items.single.status, PluginCacheClearStatus.cleared);
  } finally {
    await resetRuntime.debugDispose();
  }

  final startup = Stopwatch()..start();
  final runtime = native
      ? _nativeRuntime(nativeRuntimeHost, nativeDataRoot)
      : _javascriptRuntime(nodeRuntimeRoot, pinnedNode, javascriptDataRoot);
  try {
    await runtime.configurePluginHttpProxy(proxy);
    await runtime.invoke(const RuntimePingInvocation());
    final startupMs = startup.elapsedMilliseconds;
    final startupStatus = await runtime.invoke(const RuntimeStatusInvocation());
    if (native) {
      expect(startupStatus.runtimeKind, 'native-rust');
    } else {
      expect(startupStatus.nodeVersion, _javascriptNodeVersion);
    }
    expect(startupStatus.plugins.any((plugin) => plugin.id == pluginId), isTrue);

    final operationWatch = Stopwatch()..start();
    final observed = <String, Object?>{};
    switch (operation) {
      case 'detail':
        final detail = await runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: _bookId));
        observed['chapterCount'] = detail.summary.chapterCount;
        break;
      case 'catalog':
        final catalog = await runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: _bookId));
        final ids = catalog.items.map((chapter) => chapter.id).toList();
        expect(ids, isNotEmpty);
        observed['chapterCount'] = ids.length;
        observed['catalogIdsSha256'] = sha256.convert(utf8.encode(ids.join('\n'))).toString();
        break;
      case 'content':
        final content = await runtime.invoke(SourceContentInvocation(pluginId: pluginId, id: _bookId, chapterId: firstChapterId));
        final text = content.text ?? '';
        final bytes = utf8.encode(text);
        expect(bytes, isNotEmpty);
        final normalizedText = text.replaceAll(_unicodeWhitespace, '');
        observed['contentByteCount'] = bytes.length;
        observed['contentSha256'] = sha256.convert(bytes).toString();
        observed['contentWhitespaceNormalizedSha256'] = sha256.convert(utf8.encode(normalizedText)).toString();
        break;
    }
    final operationMs = operationWatch.elapsedMilliseconds;
    final afterStatus = await runtime.invoke(const RuntimeStatusInvocation());
    return _Measurement(
      startupMs: startupMs,
      operationMs: operationMs,
      rssAfterStartupBytes: startupStatus.memory.rss,
      rssAfterOperationBytes: afterStatus.memory.rss,
      observed: observed,
    );
  } finally {
    await runtime.debugDispose();
  }
}

Map<String, Object?> _measurementsJson(Map<String, _Measurement> values) => <String, Object?>{
  for (final entry in values.entries) entry.key: entry.value.toJson(),
};

Map<String, Object?> _medianSummary(List<Map<String, Object?>> pairs) {
  final summary = <String, Object?>{};
  for (final backend in <String>['native', 'javascript']) {
    final operations = <String, Object?>{};
    for (final operation in _operations) {
      final measurements = pairs
          .map((pair) => pair[backend]! as Map<String, Object?>)
          .map((values) => values[operation]! as Map<String, Object?>)
          .toList(growable: false);
      operations[operation] = <String, int>{
        'startupMs': _median(measurements.map((value) => value['startupMs']! as int)),
        'operationMs': _median(measurements.map((value) => value['operationMs']! as int)),
        'rssAfterStartupBytes': _median(measurements.map((value) => value['rssAfterStartupBytes']! as int)),
        'rssAfterOperationBytes': _median(measurements.map((value) => value['rssAfterOperationBytes']! as int)),
      };
    }
    summary[backend] = operations;
  }
  return summary;
}

int _median(Iterable<int> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

String _crc32(List<int> bytes) {
  var value = 0xffffffff;
  for (final byte in bytes) {
    value ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      value = value.isOdd ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
  }
  return ((value ^ 0xffffffff) & 0xffffffff).toRadixString(16).padLeft(8, '0');
}

String _path(Directory root, List<String> parts) => <String>[root.path, ...parts].join(Platform.pathSeparator);

Uri? _environmentProxy() {
  const names = <String>['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy'];
  String? raw;
  for (final name in names) {
    final value = Platform.environment[name];
    if (value != null && value.trim().isNotEmpty) {
      raw = value.trim();
      break;
    }
  }
  if (raw == null) return null;
  final candidate = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
  if (candidate == null ||
      !const <String>{'http', 'https'}.contains(candidate.scheme) ||
      candidate.host.isEmpty ||
      candidate.path.isNotEmpty && candidate.path != '/' ||
      candidate.hasQuery ||
      candidate.hasFragment) {
    throw StateError('The environment proxy endpoint is invalid.');
  }
  final port = candidate.hasPort
      ? candidate.port
      : candidate.scheme == 'https'
      ? 443
      : 80;
  return Uri(scheme: candidate.scheme, host: candidate.host, port: port);
}

Future<void> _removeTemporaryRoot(Directory target) async {
  if (!await target.exists()) return;
  final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
  final resolvedTarget = await target.resolveSymbolicLinks();
  if (!resolvedTarget.startsWith('$temporaryRoot${Platform.pathSeparator}')) {
    throw StateError('Refusing cleanup outside the temporary benchmark root.');
  }
  final attributes = await Process.run('attrib.exe', <String>['-R', '${target.path}${Platform.pathSeparator}*', '/S', '/D']);
  if (attributes.exitCode != 0) {
    throw StateError('Cannot release benchmark artifact attributes.');
  }
  await target.delete(recursive: true);
}

final class _Measurement {
  const _Measurement({
    required this.startupMs,
    required this.operationMs,
    required this.rssAfterStartupBytes,
    required this.rssAfterOperationBytes,
    required this.observed,
  });

  final int startupMs;
  final int operationMs;
  final int rssAfterStartupBytes;
  final int rssAfterOperationBytes;
  final Map<String, Object?> observed;

  Map<String, Object?> toJson() => <String, Object?>{
    'startupMs': startupMs,
    'operationMs': operationMs,
    'rssAfterStartupBytes': rssAfterStartupBytes,
    'rssAfterOperationBytes': rssAfterOperationBytes,
    ...observed,
  };
}
