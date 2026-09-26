/// Opt-in Windows acceptance through the production Facade and native host.
/// The report contains only counts, SHA-256 values, timings, and pass state.
// ignore_for_file: invalid_use_of_visible_for_testing_member
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

const _pluginId = 'org.mgread.aisishuwu.native';
const _bookId = 'novel:52801';

void main() {
  test(
    'Windows native Facade imports Alice and reads complete live content',
    () async {
      final root = Directory.current.absolute;
      final hostExecutable = File(
        '${root.path}${Platform.pathSeparator}packages${Platform.pathSeparator}'
        'mg_read_native_runtime${Platform.pathSeparator}dist${Platform.pathSeparator}'
        'windows-x86_64${Platform.pathSeparator}mgread-native-host.exe',
      );
      final artifact = File(
        '${root.path}${Platform.pathSeparator}plugins${Platform.pathSeparator}'
        'sources${Platform.pathSeparator}aisishuwu-native${Platform.pathSeparator}'
        'dist${Platform.pathSeparator}aisishuwu-native-0.2.0.mgplugin',
      );
      expect(await hostExecutable.exists(), isTrue);
      expect(await artifact.exists(), isTrue);

      final dataRoot = await Directory.systemTemp.createTemp('mgread-alice-native-facade-');
      var runtime = PluginRuntime.nativeForTesting(executablePath: hostExecutable.path, dataRoot: dataRoot.path, testMode: false);
      addTearDown(() async {
        try {
          await runtime.debugDispose();
        } finally {
          await _removeTemporaryRoot(dataRoot);
        }
      });

      final evidence = <String, Object?>{};
      final packageBytes = await artifact.readAsBytes();
      evidence['artifactByteCount'] = packageBytes.length;
      evidence['artifactSha256'] = sha256.convert(packageBytes).toString();

      final startup = Stopwatch()..start();
      final initialStatus = await runtime.invoke(const RuntimeStatusInvocation());
      evidence['coldHostMs'] = startup.elapsedMilliseconds;
      expect(initialStatus.runtimeKind, 'native-rust');
      expect(initialStatus.plugins, isEmpty);

      final import = Stopwatch()..start();
      await runtime.importLocalPluginForTesting(artifact.path);
      evidence['importAndRestartMs'] = import.elapsedMilliseconds;
      final installed = await runtime.invoke(const InstalledPluginsInvocation());
      final source = installed.singleWhere((item) => item.id == _pluginId);
      expect(source.status, 'active');
      expect(source.enabled, isTrue);
      expect(source.activeVersion, '0.2.0');

      final proxy = _environmentProxy();
      if (proxy != null) await runtime.configurePluginHttpProxy(proxy);

      final offers = await runtime.invoke(const PluginTransferOfferListInvocation());
      final offer = offers.singleWhere((item) => item.pluginId == _pluginId);
      expect(offer.format, PluginArtifactFormat.archive);
      expect(offer.provenance, PluginArtifactProvenance.installed);
      final exported = await runtime.exportPluginArtifact(
        PluginTransferArtifact(
          bytes: packageBytes.length,
          developmentFingerprint: null,
          developmentRevision: null,
          format: PluginArtifactFormat.archive,
          pluginId: _pluginId,
          provenance: PluginArtifactProvenance.installed,
          checksum: _crc32(packageBytes),
          version: offer.version,
        ),
      );
      final exportBuilder = BytesBuilder(copy: false);
      await for (final chunk in exported) {
        exportBuilder.add(chunk);
      }
      final exportedBytes = exportBuilder.takeBytes();
      expect(exportedBytes, orderedEquals(packageBytes));
      evidence['exportByteCount'] = exportedBytes.length;
      evidence['exportSha256'] = sha256.convert(exportedBytes).toString();

      final liveChain = Stopwatch()..start();
      final home = await runtime.invoke(const SourceDiscoverInvocation(pluginId: _pluginId, pageSize: 8));
      expect(home, isA<PluginDiscoveryDocumentResult>());
      final document = (home as PluginDiscoveryDocumentResult).document;
      evidence['homeComponentCount'] = document.components.length;
      final categories = _categories(
        document.components,
      ).where((category) => category.target.startsWith('category:')).toList(growable: false);
      expect(categories, isNotEmpty);
      evidence['homeCategoryCount'] = categories.length;

      final categoryWatch = Stopwatch()..start();
      final categoryResult = await runtime.invoke(
        SourceDiscoverInvocation(pluginId: _pluginId, target: categories.first.target, pageSize: 3),
      );
      expect(categoryResult, isA<PluginDiscoveryDocumentResult>());
      final categoryItemCount = _contentItemCount((categoryResult as PluginDiscoveryDocumentResult).document.components);
      expect(categoryItemCount, greaterThan(0));
      evidence['categoryItemCount'] = categoryItemCount;
      evidence['categoryDiscoverMs'] = categoryWatch.elapsedMilliseconds;

      final searchWatch = Stopwatch()..start();
      final search = await runtime.invoke(const SourceSearchInvocation(pluginId: _pluginId, query: '修仙', pageSize: 3));
      expect(search.items, isNotEmpty);
      evidence['searchItemCount'] = search.items.length;
      evidence['searchMs'] = searchWatch.elapsedMilliseconds;

      final suggestionWatch = Stopwatch()..start();
      final suggestions = await runtime.invoke(const SourceSearchSuggestionsInvocation(pluginId: _pluginId, pageSize: 8));
      expect(suggestions.items, isNotEmpty);
      evidence['suggestionCount'] = suggestions.items.length;
      evidence['suggestionsMs'] = suggestionWatch.elapsedMilliseconds;

      final detailWatch = Stopwatch()..start();
      final detail = await runtime.invoke(const SourceDetailInvocation(pluginId: _pluginId, id: _bookId));
      evidence['detailMs'] = detailWatch.elapsedMilliseconds;
      expect(detail.summary.chapterCount, greaterThan(0));

      final catalogWatch = Stopwatch()..start();
      final chapters = await runtime.invoke(const SourceChaptersInvocation(pluginId: _pluginId, id: _bookId));
      evidence['catalogMs'] = catalogWatch.elapsedMilliseconds;
      expect(chapters.items, isNotEmpty);
      expect(chapters.items.length, detail.summary.chapterCount);
      expect(chapters.items.map((item) => item.id).toSet().length, chapters.items.length);
      expect(chapters.items.asMap().entries.every((entry) => entry.value.order == entry.key), isTrue);
      evidence['chapterCount'] = chapters.items.length;
      evidence['catalogIdsSha256'] = sha256.convert(utf8.encode(chapters.items.map((item) => item.id).join('\n'))).toString();

      final sampleEvidence = <Map<String, Object?>>[];
      for (final index in <int>{0, chapters.items.length ~/ 2, chapters.items.length - 1}.toList()..sort()) {
        final sampleWatch = Stopwatch()..start();
        final content = await runtime.invoke(
          SourceContentInvocation(pluginId: _pluginId, id: _bookId, chapterId: chapters.items[index].id),
        );
        final bytes = utf8.encode(content.text ?? '');
        expect(bytes, isNotEmpty);
        sampleEvidence.add(<String, Object?>{
          'index': index,
          'byteCount': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'elapsedMs': sampleWatch.elapsedMilliseconds,
        });
      }
      evidence['firstMiddleLastSamples'] = sampleEvidence;

      final coverWatch = Stopwatch()..start();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..findProxy = (_) => 'DIRECT';
      addTearDown(client.close);
      final coverResponse = await (await client.getUrl(detail.summary.coverUrl!)).close();
      expect(coverResponse.statusCode, 200);
      expect(coverResponse.headers.contentType?.mimeType, startsWith('image/'));
      final coverBuilder = BytesBuilder(copy: false);
      var coverByteCount = 0;
      await for (final chunk in coverResponse) {
        coverByteCount += chunk.length;
        if (coverByteCount > 16 * 1024 * 1024) {
          throw StateError('Cover response exceeded the acceptance size limit.');
        }
        coverBuilder.add(chunk);
      }
      final coverBytes = coverBuilder.takeBytes();
      expect(coverBytes, isNotEmpty);
      evidence['coverByteCount'] = coverBytes.length;
      evidence['coverSha256'] = sha256.convert(coverBytes).toString();
      evidence['coverFetchMs'] = coverWatch.elapsedMilliseconds;

      final longCatalog = await runtime.invoke(const SourceChaptersInvocation(pluginId: _pluginId, id: 'novel:3211'));
      expect(longCatalog.items, isNotEmpty);
      final longWatch = Stopwatch()..start();
      final longContent = await runtime.invoke(
        SourceContentInvocation(pluginId: _pluginId, id: 'novel:3211', chapterId: longCatalog.items.first.id),
      );
      final longBytes = utf8.encode(longContent.text ?? '');
      expect(longBytes.length, greaterThan(48 * 1024));
      evidence['longChapterByteCount'] = longBytes.length;
      evidence['longChapterSha256'] = sha256.convert(longBytes).toString();
      evidence['longChapterFetchMs'] = longWatch.elapsedMilliseconds;
      evidence['liveChainMs'] = liveChain.elapsedMilliseconds;

      // Keep a failing upstream proxy alive so a successful post-crash detail
      // call proves the native persistent cache survived the worker crash.
      var offlineProxyRequests = 0;
      final offlineProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      offlineProxy.listen((request) async {
        offlineProxyRequests += 1;
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      });
      addTearDown(() => offlineProxy.close(force: true));
      await runtime.configurePluginHttpProxy(Uri(scheme: 'http', host: '127.0.0.1', port: offlineProxy.port));

      final startsBeforeCrash = runtime.debugDesktopProcessStartCount;
      final workerPid = await _findUniqueNativeWorkerPid(dataRoot);
      expect(Process.killPid(workerPid), isTrue);
      final recoveryWatch = Stopwatch()..start();
      final recoveredPing = await _waitForNativePing(runtime);
      expect(recoveredPing.isHealthy, isTrue);
      final startsAfterCrash = runtime.debugDesktopProcessStartCount;
      expect(startsAfterCrash, greaterThan(startsBeforeCrash));
      evidence['workerStartCountBeforeCrash'] = startsBeforeCrash;
      evidence['workerStartCountAfterCrash'] = startsAfterCrash;
      evidence['workerCrashRecoveryMs'] = recoveryWatch.elapsedMilliseconds;

      final installedAfterCrash = await runtime.invoke(const InstalledPluginsInvocation());
      final recoveredSource = installedAfterCrash.singleWhere((item) => item.id == _pluginId);
      expect(recoveredSource.status, 'active');
      expect(recoveredSource.enabled, isTrue);
      expect(recoveredSource.activeVersion, '0.2.0');

      final restartCacheWatch = Stopwatch()..start();
      final cachedDetail = await runtime.invoke(const SourceDetailInvocation(pluginId: _pluginId, id: _bookId));
      expect(cachedDetail.summary.id, _bookId);
      expect(cachedDetail.summary.chapterCount, detail.summary.chapterCount);
      expect(offlineProxyRequests, 0);
      evidence['restartCacheDetailMs'] = restartCacheWatch.elapsedMilliseconds;
      await expectLater(
        runtime.invoke(const SourceDetailInvocation(pluginId: _pluginId, id: 'novel:987654321')),
        throwsA(isA<PluginRuntimeException>()),
      );
      expect(offlineProxyRequests, greaterThan(0));
      evidence['changedProxyUsedForUncachedRequest'] = true;
      await offlineProxy.close(force: true);

      final startsBeforeDisable = runtime.debugDesktopProcessStartCount;
      final disabled = await runtime.invoke(const SetPluginEnabledInvocation(pluginId: _pluginId, enabled: false));
      expect(disabled.enabled, isFalse);
      expect(runtime.debugDesktopProcessStartCount, startsBeforeDisable + 1);
      await expectLater(
        runtime.invoke(const SourceDetailInvocation(pluginId: _pluginId, id: _bookId)),
        throwsA(isA<PluginRuntimeException>().having((error) => error.code, 'code', 'plugin_disabled')),
      );
      final enabled = await runtime.invoke(const SetPluginEnabledInvocation(pluginId: _pluginId, enabled: true));
      expect(enabled.enabled, isTrue);
      expect(runtime.debugDesktopProcessStartCount, startsBeforeDisable + 2);
      final clearing = await runtime.invoke(const ClearPluginCacheInvocation(pluginId: _pluginId));
      expect(clearing.items.single.bytesRemaining, 0);
      expect(runtime.debugDesktopProcessStartCount, startsBeforeDisable + 3);

      await runtime.invoke(const UninstallPluginInvocation(pluginId: _pluginId));
      expect(await runtime.invoke(const InstalledPluginsInvocation()), isEmpty);
      final transferred = await runtime.importPluginArtifacts([
        (
          artifact: PluginTransferArtifact(
            bytes: packageBytes.length,
            developmentFingerprint: null,
            developmentRevision: null,
            format: PluginArtifactFormat.archive,
            pluginId: _pluginId,
            provenance: PluginArtifactProvenance.installed,
            checksum: _crc32(packageBytes),
            version: '0.2.0',
          ),
          bytes: Stream<List<int>>.value(packageBytes),
        ),
      ]);
      expect(transferred.single.status, PluginTransferImportStatus.installed);
      expect((await runtime.invoke(const InstalledPluginsInvocation())).single.id, _pluginId);
      await runtime.invoke(const UninstallPluginInvocation(pluginId: _pluginId));
      expect(await runtime.invoke(const InstalledPluginsInvocation()), isEmpty);
      evidence['transferImportAndUninstall'] = 'passed';
      evidence['cacheSurvivesWorkerCrashOffline'] = true;
      evidence['status'] = 'passed';
      final reportDirectory = Directory(
        '${root.path}${Platform.pathSeparator}plugins${Platform.pathSeparator}'
        'sources${Platform.pathSeparator}aisishuwu-native${Platform.pathSeparator}'
        'artifacts${Platform.pathSeparator}native-runtime',
      );
      await reportDirectory.create(recursive: true);
      await File(
        '${reportDirectory.path}${Platform.pathSeparator}windows-facade-report.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip:
        !Platform.isWindows ||
        Platform.environment['MGREAD_NATIVE_FACADE_ACCEPTANCE'] != '1' ||
        !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME'),
  );
}

Future<int> _findUniqueNativeWorkerPid(Directory dataRoot) async {
  const script = r'''
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($env:MGREAD_NATIVE_FACADE_DATA_ROOT)
$parent = [int]$env:MGREAD_NATIVE_FACADE_PARENT_PID
$candidates = @(Get-CimInstance -ClassName Win32_Process | Where-Object {
  $_.Name -eq 'mgread-native-host.exe' -and
  $_.ParentProcessId -eq $parent -and
  $_.CommandLine -and
  $_.CommandLine.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($candidates.Count -ne 1) {
  [Console]::Error.WriteLine('Expected exactly one matching native test worker.')
  exit 23
}
[Console]::Out.WriteLine([int]$candidates[0].ProcessId)
''';
  final result = await Process.run(
    'powershell.exe',
    <String>['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
    environment: <String, String>{'MGREAD_NATIVE_FACADE_DATA_ROOT': dataRoot.path, 'MGREAD_NATIVE_FACADE_PARENT_PID': pid.toString()},
  );
  if (result.exitCode != 0) {
    throw StateError('Could not uniquely identify the native test worker.');
  }
  final output = result.stdout.toString().trim();
  final workerPid = int.tryParse(output);
  if (workerPid == null || workerPid <= 0) {
    throw StateError('PowerShell returned an invalid native worker PID.');
  }
  return workerPid;
}

Future<RuntimePingResult> _waitForNativePing(PluginRuntime runtime) async {
  final timeout = Stopwatch()..start();
  PluginRuntimeException? lastFailure;
  while (timeout.elapsed < const Duration(seconds: 30)) {
    try {
      return await runtime.invoke(const RuntimePingInvocation());
    } on PluginRuntimeException catch (error) {
      if (!const <String>{'runtime_process_exited', 'transport_disconnected'}.contains(error.code)) {
        rethrow;
      }
      lastFailure = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  throw StateError(
    'The native worker did not recover after its test crash'
    '${lastFailure == null ? '' : ': ${lastFailure.code}'}.',
  );
}

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
      !const <String>{'http', 'https', 'socks5'}.contains(candidate.scheme) ||
      candidate.host.isEmpty ||
      candidate.path.isNotEmpty && candidate.path != '/' ||
      candidate.hasQuery ||
      candidate.hasFragment) {
    throw StateError('The environment proxy endpoint is invalid.');
  }

  final port = candidate.hasPort
      ? candidate.port
      : switch (candidate.scheme) {
          'https' => 443,
          'socks5' => 1080,
          _ => 80,
        };
  // The public Facade accepts proxy endpoints without embedded credentials.
  // They are intentionally omitted from both requests and the evidence file.
  return Uri(scheme: candidate.scheme, host: candidate.host, port: port);
}

Iterable<PluginDiscoveryCategory> _categories(List<PluginDiscoveryComponent> components) sync* {
  for (final component in components) {
    if (component is PluginDiscoveryCategoryCollectionComponent) {
      yield* component.categories;
    } else if (component is PluginDiscoverySectionComponent) {
      yield* _categories(component.children);
    } else if (component is PluginDiscoveryGroupComponent) {
      yield* _categories(component.children);
    }
  }
}

int _contentItemCount(List<PluginDiscoveryComponent> components) {
  var count = 0;
  for (final component in components) {
    if (component is PluginDiscoveryContentCollectionComponent) {
      count += component.items.length;
    } else if (component is PluginDiscoverySectionComponent) {
      count += _contentItemCount(component.children);
    } else if (component is PluginDiscoveryGroupComponent) {
      count += _contentItemCount(component.children);
    }
  }
  return count;
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

Future<void> _removeTemporaryRoot(Directory target) async {
  if (!await target.exists()) return;
  final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
  final resolvedTarget = await target.resolveSymbolicLinks();
  if (!resolvedTarget.startsWith('$temporaryRoot${Platform.pathSeparator}')) {
    throw StateError('Refusing cleanup outside the temporary test root.');
  }
  if (Platform.isWindows) {
    final attributes = await Process.run('attrib.exe', <String>['-R', '${target.path}${Platform.pathSeparator}*', '/S', '/D']);
    if (attributes.exitCode != 0) {
      throw StateError('Cannot release test artifact attributes.');
    }
  }
  await target.delete(recursive: true);
}
