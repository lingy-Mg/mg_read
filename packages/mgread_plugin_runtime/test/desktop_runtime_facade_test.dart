import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test('production Facade construction is process-wide singleton', () {
    expect(identical(PluginRuntime(), PluginRuntime()), isTrue);
  });

  test(
    'Flutter Facade starts one bundled desktop Node Runtime and shares the WS bridge',
    () async {
      final repositoryRoot = Directory.current.parent.parent;
      final fixture = await _desktopFixture(repositoryRoot);
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
      );
      addTearDown(runtime.debugDispose);

      // Exercise the same 128-call connection bound advertised by hello. All
      // callers must share one child startup and one internal WebSocket bridge.
      final results = await Future.wait<RuntimePingResult>(
        List<Future<RuntimePingResult>>.generate(
          128,
          (_) => runtime.invoke(const RuntimePingInvocation()),
        ),
      );

      expect(runtime.debugDesktopProcessStartCount, 1);
      for (final result in results) {
        expect(result.isHealthy, isTrue);
        expect(result.nodeVersion, fixture['nodeVersion']);
        expect(result.runtimeVersion, fixture['runtimeVersion']);
      }
    },
  );

  test(
    'Flutter Facade lists and searches an installed standard Node plugin',
    () async {
      final repositoryRoot = Directory.current.parent.parent;
      final runtimeDataRoot = await _stageInstalledStandardPlugin();
      addTearDown(() => runtimeDataRoot.delete(recursive: true));
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
      );
      final diagnostics = <RuntimeDiagnostic>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      addTearDown(() async {
        await subscription.cancel();
        await runtime.debugDispose();
      });

      final plugins = await runtime.invoke(const InstalledPluginsInvocation());
      final result = await runtime.invoke(
        const PluginSearchInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          keyword: 'Flutter',
        ),
      );
      await _waitForDiagnosticCodes(
        diagnostics,
        const <String>[
          'plugin_load_started',
          'plugin_log_emitted',
          'plugin_load_completed',
          'plugin_runtime_initialized',
          'plugin_invocation_started',
          'plugin_invocation_completed',
        ],
      );

      expect(plugins, hasLength(1));
      expect(plugins.single.id, 'org.mgread.flutter.fixture');
      expect(plugins.single.activeVersion, '1.0.0');
      expect(result.pluginId, 'org.mgread.flutter.fixture');
      expect(result.items.single.id, 'flutter:Flutter');
      expect(result.items.single.title, '标准 Node：Flutter');
    },
  );

  test('closed test Runtime rejects another Facade capability call', () async {
    final runtime = PluginRuntime.desktopForTesting(
      runtimeRepositoryRoot: Directory.current.parent.parent,
    );
    addTearDown(runtime.debugDispose);

    await runtime.invoke(const RuntimePingInvocation());
    await runtime.debugDispose();

    await expectLater(
      runtime.invoke(const RuntimePingInvocation()),
      throwsA(
        isA<PluginRuntimeException>().having(
          (error) => error.code,
          'code',
          'runtime_unavailable',
        ),
      ),
    );
  });

  test(
    'Facade reports a missing packaged Node executable with a stable reason',
    () async {
      final repositoryRoot = Directory.current.parent.parent;
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        nodeExecutableOverride: File(
          <String>[
            repositoryRoot.path,
            'missing-node.exe',
          ].join(Platform.pathSeparator),
        ),
      );
      final diagnostics = <RuntimeDiagnostic>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      addTearDown(() async {
        await subscription.cancel();
        await runtime.debugDispose();
      });

      final error = await _captureRuntimeFailure(
        runtime.invoke(const RuntimePingInvocation()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(error.code, 'runtime_node_executable_missing');
      expect(
        error.diagnostics.map((diagnostic) => diagnostic.code),
        contains('runtime_node_executable_missing'),
      );
      expect(
        diagnostics.map((diagnostic) => diagnostic.code),
        contains('runtime_node_executable_missing'),
      );
    },
  );

  test(
    'Facade reports a missing packaged main script with a stable reason',
    () async {
      final repositoryRoot = Directory.current.parent.parent;
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        entrypointOverride: File(
          <String>[
            repositoryRoot.path,
            'missing-runtime-main.mjs',
          ].join(Platform.pathSeparator),
        ),
      );
      addTearDown(runtime.debugDispose);

      final error = await _captureRuntimeFailure(
        runtime.invoke(const RuntimePingInvocation()),
      );

      expect(error.code, 'runtime_entrypoint_missing');
      expect(
        error.diagnostics.map((diagnostic) => diagnostic.code),
        contains('runtime_entrypoint_missing'),
      );
    },
  );

  test(
    'Facade preserves a structured Node startup failure diagnostic',
    () async {
      final repositoryRoot = Directory.current.parent.parent;
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        entrypointOverride: File(
          <String>[
            repositoryRoot.path,
            'test',
            'fixtures',
            'fatal-before-ready.mjs',
          ].join(Platform.pathSeparator),
        ),
      );
      addTearDown(runtime.debugDispose);

      final error = await _captureRuntimeFailure(
        runtime.invoke(const RuntimePingInvocation()),
      );

      expect(error.code, 'runtime_start_failed');
      expect(
        error.diagnostics.map((diagnostic) => diagnostic.code),
        contains('test_startup_failure'),
      );
    },
  );
}

/// Captures the Facade's safe exception while failing tests that unexpectedly pass.
Future<PluginRuntimeException> _captureRuntimeFailure(
  Future<Object?> future,
) async {
  try {
    await future;
  } on PluginRuntimeException catch (error) {
    return error;
  }
  fail('Expected the Runtime operation to fail.');
}

/// Reads the checked-in cross-language desktop fixture through a typed JSON boundary.
Future<Map<String, Object?>> _desktopFixture(Directory repositoryRoot) async {
  final fixtureFile = File(
    <String>[
      repositoryRoot.path,
      'protocol',
      'fixtures',
      'standard-node-plugin-v1.json',
    ].join(Platform.pathSeparator),
  );
  final Object? decoded = jsonDecode(await fixtureFile.readAsString());
  expect(decoded, isA<Map<Object?, Object?>>());
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> entry
        in (decoded as Map<Object?, Object?>).entries)
      if (entry.key case final String key) key: entry.value,
  };
}

/// Waits only for child stderr delivery; it never retries a Runtime operation.
Future<void> _waitForDiagnosticCodes(
  List<RuntimeDiagnostic> diagnostics,
  List<String> requiredCodes,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (DateTime.now().isBefore(deadline)) {
    final observedCodes = diagnostics
        .map((diagnostic) => diagnostic.code)
        .toSet();
    if (requiredCodes.every(observedCodes.contains)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  fail(
    'Timed out waiting for Runtime diagnostics. Observed: '
    '${diagnostics.map((diagnostic) => diagnostic.code).join(', ')}',
  );
}

Future<Directory> _stageInstalledStandardPlugin() async {
  final root = await Directory.systemTemp.createTemp(
    'mgread-flutter-plugin-runtime-',
  );
  final pluginRoot = Directory(
    <String>[
      root.path,
      'plugins',
      'org.mgread.flutter.fixture',
    ].join(Platform.pathSeparator),
  );
  final versionRoot = Directory(
    <String>[
      pluginRoot.path,
      'versions',
      '1.0.0',
    ].join(Platform.pathSeparator),
  );
  final dist = Directory(
    <String>[versionRoot.path, 'dist'].join(Platform.pathSeparator),
  );
  await dist.create(recursive: true);
  await File(
    <String>[versionRoot.path, 'package.json'].join(Platform.pathSeparator),
  ).writeAsString('''
{
  "name": "@mgread-plugin/flutter-fixture",
  "version": "1.0.0",
  "type": "module",
  "main": "dist/index.mjs",
  "engines": { "node": ">=24 <25" },
  "mgread": {
    "schemaVersion": 1,
    "id": "org.mgread.flutter.fixture",
    "pluginApi": 1,
    "contentKinds": ["novel"]
  }
}
''');
  await File(
    <String>[versionRoot.path, 'package-lock.json'].join(
      Platform.pathSeparator,
    ),
  ).writeAsString('''
{
  "name": "@mgread-plugin/flutter-fixture",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "@mgread-plugin/flutter-fixture",
      "version": "1.0.0"
    }
  }
}
''');
  await File(
    <String>[dist.path, 'index.mjs'].join(Platform.pathSeparator),
  ).writeAsString('''
let context;
export async function activate(nextContext) {
  context = nextContext;
  context.log.info('flutter_fixture_activated');
}
export async function search(keyword) {
  return [{
    id: `flutter:\${keyword}`,
    title: `标准 Node：\${keyword}`,
    author: context.plugin.id,
  }];
}
''');
  await File(
    <String>[pluginRoot.path, 'pending'].join(Platform.pathSeparator),
  ).writeAsString('1.0.0\n');
  return root;
}
