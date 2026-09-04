/// Windows development-artifact listing timeout regression.
///
/// The fixture deliberately takes longer than the ordinary five-second
/// control window so local export and LAN sync keep their shared packaging
/// path without timing out after the artifact has already been built.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

void main() {
  test(
    'development artifact listing uses the bounded transfer timeout',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-transfer-list-timeout-',
      );
      final developmentRoot = Directory(
        '${root.path}${Platform.pathSeparator}development',
      );
      final runtimeDataRoot = Directory(
        '${root.path}${Platform.pathSeparator}runtime-data',
      );
      await _writeSlowDevelopmentPlugin(developmentRoot);
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
        developmentPluginRoot: developmentRoot,
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await root.delete(recursive: true);
      });

      final artifacts = await runtime.invoke(
        const PluginTransferListInvocation(),
      );

      expect(artifacts, hasLength(1));
      expect(artifacts.single.pluginId, 'org.example.slow-export');
      expect(artifacts.single.format, PluginArtifactFormat.singleFile);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _writeSlowDevelopmentPlugin(Directory developmentRoot) async {
  final projectRoot = Directory(
    '${developmentRoot.path}${Platform.pathSeparator}slow-export',
  );
  final dist = Directory('${projectRoot.path}${Platform.pathSeparator}dist');
  final tools = Directory('${projectRoot.path}${Platform.pathSeparator}tools');
  await dist.create(recursive: true);
  await tools.create(recursive: true);
  const packageName = '@mgread-plugin/slow-export';
  const version = '0.1.0';
  await File(
    '${projectRoot.path}${Platform.pathSeparator}package.json',
  ).writeAsString(
    '${jsonEncode(<String, Object?>{
      'name': packageName,
      'version': version,
      'type': 'module',
      'main': 'dist/index.mjs',
      'engines': <String, String>{'node': '>=24 <25'},
      'mgread': <String, Object?>{
        'schemaVersion': 1,
        'id': 'org.example.slow-export',
        'displayName': 'Slow export fixture',
        'packageMode': 'single-file',
        'pluginApi': 1,
        'contentKinds': <String>['novel'],
      },
    })}\n',
  );
  await File(
    '${projectRoot.path}${Platform.pathSeparator}package-lock.json',
  ).writeAsString(
    '${jsonEncode(<String, Object?>{
      'name': packageName,
      'version': version,
      'lockfileVersion': 3,
      'requires': true,
      'packages': <String, Object?>{
        '': <String, String>{'name': packageName, 'version': version},
      },
    })}\n',
  );
  await File('${dist.path}${Platform.pathSeparator}index.mjs').writeAsString('''
export function activate() {}
export function discover() { return { kind: 'document', document: { components: [] } }; }
export function search() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getDetail(request) { return { id: request.id, title: request.id, contentKind: 'novel', author: null, url: null, coverUrl: null, description: null, language: null, status: 'unknown', access: 'unknown', wordCount: null, chapterCount: 0, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [], aliases: [], catalogUrl: null }; }
export function getChapters() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getContent(request) { return { contentKind: 'novel', chapterId: request.chapterId, title: null, updatedAt: null, text: 'fixture', pages: [] }; }
''');
  await File('${tools.path}${Platform.pathSeparator}mgread.mjs').writeAsString(
    '''
export async function buildPluginArtifact({ versionOverride } = {}) {
  await new Promise((resolve) => setTimeout(resolve, 5500));
  const version = versionOverride ?? '0.1.0';
  return {
    bytes: new TextEncoder().encode('// packaged development artifact'),
    fileName: `org.example.slow-export-\${version}.mgplugin.js`,
    format: 'singleFile',
  };
}
''',
  );
}
