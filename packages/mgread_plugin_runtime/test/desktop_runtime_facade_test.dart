import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

part 'desktop_runtime_facade_startup_part.dart';
part 'desktop_runtime_facade_lifecycle_part.dart';

void main() {
  _registerDesktopRuntimeStartupTests();
  _registerDesktopRuntimeLifecycleTests();
}

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

Future<void> _waitForFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for ${file.path}.');
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
    <String>[pluginRoot.path, 'versions', '1.0.0'].join(Platform.pathSeparator),
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
  "engines": { "node": "24.16.0 || 24.21.0 || 26.9.0 || 26.10.0" },
  "mgread": {
    "schemaVersion": 1,
    "id": "org.mgread.flutter.fixture",
    "displayName": "Flutter 标准测试数据源",
    "pluginApi": 1,
    "contentKinds": ["novel"],
    "r18": true
  }
}

''');
  await File(
    <String>[
      versionRoot.path,
      'package-lock.json',
    ].join(Platform.pathSeparator),
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
function summary(query) {
  const id = `flutter:\${query}`;
  return {
    id,
    title: `标准 Node：\${query}`,
    contentKind: 'novel', coverOrientation: 'square',
    author: context.plugin.id,
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh-CN',
    status: 'ongoing',
    access: 'free',
    wordCount: 123456,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: '2026-08-15T00:00:00Z',
    latestChapter: {
      id: `\${id}:chapter-1`,
      title: '第一章',
      url: null,
      updatedAt: '2026-08-15T00:00:00Z',
    },
    categories: [],
    tags: [],
    attributes: [],
  };
}
export async function discover(request) {
  if (request.target === 'slow-nested' || (request.target === null && request.pageSize === 50)) {
    await new Promise((resolve) => setTimeout(resolve, 5500));
  }
  if (request.target === 'slow-timeout') {
    await new Promise((resolve) => setTimeout(resolve, 15000));
  }
  return {
    kind: 'document',
    document: { components: [{
      type: 'section',
      id: 'featured-section',
      title: '精选',
      subtitle: null,
      icon: 'recommendation',
      children: [{
        type: 'contentCollection',
        id: 'featured',
        layout: 'featured',
        continuation: null,
        items: [{
          content: summary('发现'),
          rank: null,
          metric: null,
          recommendation: null,
        }],
      }, ...['coverGrid', 'shelf', 'compact'].map((layout) => ({
        type: 'contentCollection',
        id: `layout-\${layout}`,
        layout,
        continuation: null,
        items: [{
          content: summary(layout),
          rank: layout === 'compact' ? 1 : null,
          metric: null,
          recommendation: null,
        }],
      })), {
        type: 'categoryCollection',
        id: 'category-chips',
        layout: 'chips',
        categories: [{ id: 'video', title: '视频', target: 'video', count: null, url: null, icon: 'video' }],
      }],
    }] },
  };
}
export async function search(request) {
  return { items: [summary(request.query)], nextCursor: null, totalCount: 1 };
}
export async function getDetail(request) {
  return {
    ...summary(request.id),
    id: request.id,
    aliases: [],
    catalogUrl: null,
  };
}
export async function getChapters(request) {
  const count = request.id === 'flutter:large-catalog' ? 733 : 1;
  return {
    items: Array.from({ length: count }, (_, index) => ({
      id: `\${request.id}:chapter-\${index + 1}`,
      title: `第\${index + 1}章\${'大'.repeat(60)}`,
      order: index,
      url: null,
      volumeTitle: null,
      wordCount: 12,
      updatedAt: null,
      isLocked: false,
      attributes: [],
    })),
  };
}
export async function getContent(request) {
  if (request.chapterId === 'manga') return { contentKind: 'manga', chapterId: request.chapterId, title: null, updatedAt: null, text: null, pages: [{ id: 'page:0', index: 0, url: 'https://example.invalid/page/0', mimeType: null, width: null, height: null }] };
  return {
    contentKind: 'novel',
    chapterId: request.chapterId,
    title: '第一章',
    updatedAt: null,
    text: 'Flutter 标准正文。',
    pages: [],
  };
}
''');
  await File(
    <String>[pluginRoot.path, 'pending'].join(Platform.pathSeparator),
  ).writeAsString('1.0.0\n');
  final artifactRoot = Directory(
    <String>[
      root.path,
      'plugin-archives',
      'org.mgread.flutter.fixture',
    ].join(Platform.pathSeparator),
  );
  await artifactRoot.create(recursive: true);
  await File(
    <String>[
      artifactRoot.path,
      '1.0.0.mgplugin.js',
    ].join(Platform.pathSeparator),
  ).writeAsString('/* MgRead test single-file artifact. */\n');
  return root;
}

Future<void> _writeDevelopmentPlugin(
  Directory developmentRoot,
  String prefix,
) async {
  final projectRoot = Directory(
    <String>[developmentRoot.path, 'live-source'].join(Platform.pathSeparator),
  );
  final dist = Directory(
    <String>[projectRoot.path, 'dist'].join(Platform.pathSeparator),
  );
  final src = Directory(
    <String>[projectRoot.path, 'src'].join(Platform.pathSeparator),
  );
  await Future.wait(<Future<void>>[
    dist.create(recursive: true),
    src.create(recursive: true),
  ]);
  const packageName = '@mgread-plugin/flutter-live';
  const version = '0.1.0';
  await File(
    <String>[projectRoot.path, 'package.json'].join(Platform.pathSeparator),
  ).writeAsString(
    '${jsonEncode(<String, Object?>{
      'name': packageName,
      'version': version,
      'type': 'module',
      'main': 'dist/index.mjs',
      'scripts': <String, String>{'build': 'node build.mjs'},
      'engines': <String, String>{'node': '24.16.0 || 24.21.0 || 26.9.0 || 26.10.0'},
      'mgread': <String, Object?>{
        'schemaVersion': 1,
        'id': 'org.example.flutter-live',
        'displayName': 'Flutter Live',
        'pluginApi': 1,
        'contentKinds': <String>['novel'],
      },
    })}\n',
  );
  await File(
    <String>[
      projectRoot.path,
      'package-lock.json',
    ].join(Platform.pathSeparator),
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
  await File(
    <String>[projectRoot.path, 'build.mjs'].join(Platform.pathSeparator),
  ).writeAsString(
    "import { copyFile } from 'node:fs/promises';\n"
    "await copyFile(new URL('./src/index.mjs', import.meta.url), "
    "new URL('./dist/index.mjs', import.meta.url));\n",
  );
  final source =
      '''
export function activate() {} const summary = (query) => ({
  id: 'live:' + query,
  title: ${jsonEncode(prefix)} + '：' + query,
  contentKind: 'novel', author: null, url: null, coverUrl: null, description: null, language: null, status: 'unknown', access: 'unknown',
  wordCount: null, chapterCount: 0, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [],
});
export function discover() { return { kind: 'document', document: { components: [] } }; } export function search(request) { return { items: [summary(request.query)], nextCursor: null, totalCount: 1 }; }
export function getDetail(request) { return { ...summary(request.id), id: request.id, aliases: [], catalogUrl: null }; } export function getChapters() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getContent(request) { return { contentKind: 'novel', chapterId: request.chapterId, title: null, updatedAt: null, text: 'text', pages: [] }; }
''';
  await File(
    <String>[src.path, 'index.mjs'].join(Platform.pathSeparator),
  ).writeAsString(source);
  if (!await File(
    <String>[dist.path, 'index.mjs'].join(Platform.pathSeparator),
  ).exists()) {
    await File(
      <String>[dist.path, 'index.mjs'].join(Platform.pathSeparator),
    ).writeAsString(source);
  }
}
