/// Javet channel regression: a large selection finalizes once and reports catalog failures.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('65 Android sources are staged before a single finalization', () async {
    const channel = MethodChannel('mgread_plugin_runtime/android');
    const progress = MethodChannel('mgread_plugin_runtime/android/progress');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final stagingDirectory = await Directory.systemTemp.createTemp(
      'mgread-android-plugin-staging-',
    );
    final stagedFiles = <File>[];
    var began = 0;
    var finalized = 0;
    messenger.setMockMethodCallHandler(progress, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>?;
      switch (call.method) {
        case 'invoke':
          if (args!['method'] == 'plugins.transfer.plan.v2') {
            final params = args['params'] as Map<Object?, Object?>;
            final artifacts = params['artifacts'] as List<Object?>;
            return jsonEncode({
              'ok': true,
              'result': [
                for (final raw in artifacts)
                  {
                    'id': (raw as Map)['id'],
                    'version': '1.0.0',
                    'action': 'missing',
                    'receiverVersion': null,
                  },
              ],
            });
          }
          expect(args['method'], 'plugins.list.v1');
          expect(finalized, 1);
          return jsonEncode({
            'ok': true,
            'result': [
              for (var index = 0; index < 65; index++)
                {
                  'id': 'org.test.$index',
                  'name': 'fixture',
                  'displayName': 'fixture',
                  'description': '',
                  'iconUrl': null,
                  'activeVersion': index == 64 ? null : '1.0.0',
                  'pendingVersion': null,
                  'enabled': index != 64,
                  'status': index == 64 ? 'quarantined' : 'active',
                  'contentKinds': ['novel'],
                  'sourceUrl': null,
                },
            ],
          });
        case 'beginPluginTransfer':
          final id = 'transfer-${began++}';
          final file = File('${stagingDirectory.path}/$id.part')..createSync();
          stagedFiles.add(file);
          return <String, Object?>{'id': id, 'temporaryPath': file.path};
        case 'finishPluginTransferBatch':
          expect(began, 65);
          expect(stagedFiles, hasLength(65));
          expect(
            await Future.wait(stagedFiles.map((file) => file.length())),
            everyElement(1),
          );
          expect(args!['ids'], hasLength(65));
          finalized++;
          return null;
        case 'dispose':
          return null;
        default:
          fail('Unexpected platform method: ${call.method}');
      }
    });
    final runtime = PluginRuntime.androidForTesting();
    addTearDown(() async {
      await runtime.debugDispose();
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(progress, null);
      await stagingDirectory.delete(recursive: true);
    });
    final result = await runtime.importPluginArtifacts([
      for (var index = 0; index < 65; index++)
        (
          artifact: PluginTransferArtifact(
            bytes: 1,
            developmentFingerprint: null,
            developmentRevision: null,
            format: PluginArtifactFormat.singleFile,
            pluginId: 'org.test.$index',
            provenance: PluginArtifactProvenance.installed,
            checksum: '00000000',
            version: '1.0.0',
          ),
          bytes: Stream<List<int>>.value([index]),
        ),
    ]);
    expect(finalized, 1);
    expect(
      result.where(
        (item) => item.status == PluginTransferImportStatus.installed,
      ),
      hasLength(64),
    );
    expect(result.last.status, PluginTransferImportStatus.failed);
  });

  test(
    'Dart writes a large artifact to the Android staging path before finalize',
    () async {
      const channel = MethodChannel('mgread_plugin_runtime/android');
      const progress = MethodChannel('mgread_plugin_runtime/android/progress');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final stagingDirectory = await Directory.systemTemp.createTemp(
        'mgread-android-plugin-large-staging-',
      );
      const artifactBytes = 488865;
      File? stagedFile;
      messenger.setMockMethodCallHandler(progress, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map<Object?, Object?>?;
        switch (call.method) {
          case 'invoke':
            if (args!['method'] == 'plugins.transfer.plan.v2') {
              final params = args['params'] as Map<Object?, Object?>;
              final artifacts = params['artifacts'] as List<Object?>;
              return jsonEncode({
                'ok': true,
                'result': [
                  for (final raw in artifacts)
                    {
                      'id': (raw as Map)['id'],
                      'version': '1.1.0',
                      'action': 'upgrade',
                      'receiverVersion': '1.0.0',
                    },
                ],
              });
            }
            expect(args['method'], 'plugins.list.v1');
            return jsonEncode({
              'ok': true,
              'result': [
                {
                  'id': 'org.test.large',
                  'name': 'large',
                  'displayName': 'large',
                  'description': '',
                  'iconUrl': null,
                  'activeVersion': '1.1.0',
                  'pendingVersion': null,
                  'enabled': true,
                  'status': 'active',
                  'contentKinds': ['novel'],
                  'sourceUrl': null,
                },
              ],
            });
          case 'beginPluginTransfer':
            stagedFile = File('${stagingDirectory.path}/large-transfer.part')
              ..createSync();
            return <String, Object?>{
              'id': 'large-transfer',
              'temporaryPath': stagedFile!.path,
            };
          case 'finishPluginTransferBatch':
            expect(args!['ids'], <String>['large-transfer']);
            expect(await stagedFile!.length(), artifactBytes);
            return null;
          case 'dispose':
            return null;
          default:
            fail('Unexpected platform method: ${call.method}');
        }
      });
      final runtime = PluginRuntime.androidForTesting();
      addTearDown(() async {
        await runtime.debugDispose();
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(progress, null);
        await stagingDirectory.delete(recursive: true);
      });

      final result = await runtime.importPluginArtifacts([
        (
          artifact: PluginTransferArtifact(
            bytes: artifactBytes,
            developmentFingerprint: null,
            developmentRevision: null,
            format: PluginArtifactFormat.singleFile,
            pluginId: 'org.test.large',
            provenance: PluginArtifactProvenance.installed,
            checksum: '00000000',
            version: '1.1.0',
          ),
          bytes: Stream<List<int>>.value(List<int>.filled(artifactBytes, 7)),
        ),
      ]);

      expect((await stagedFile!.readAsBytes()).length, artifactBytes);
      expect((await stagedFile!.readAsBytes()).first, 7);
      expect(result.single.status, PluginTransferImportStatus.installed);
    },
  );
}
