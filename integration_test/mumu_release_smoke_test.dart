/// MuMu acceptance of the real application, local TXT/EPUB readers and Runtime.
/// Uses the app's normal Android data root and bundled, self-authored documents.
/// TV source/media cases use controlled fixtures, not live playback evidence.
/// Build profile with MGREAD_APPLICATION_ID_SUFFIX=tvqa; verify APK badging
/// before drive --use-application-binary --keep-app-running. Never clear data.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/local_import/application/local_import_controller.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'tv_mumu_navigation_test.dart' as tv;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final evidence = <String, Object?>{};
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!.addAll(evidence);
  });
  testWidgets('MuMu real startup, Runtime, TXT and EPUB reader round trips', (tester) async {
    expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'tvqa');
    Widget? app;
    final capture = GlobalKey();
    await bootstrapMgReadApp(televisionDetector: () async => false, appRunner: (widget) => app = widget);
    await tester.pumpWidget(RepaintBoundary(key: capture, child: app!));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    final container = ProviderScope.containerOf(tester.element(find.byType(MgReadApp)));
    await _wait(tester, () => container.read(appStartupControllerProvider).state.status == AppStartupStatus.ready);
    final settings = container.read(appSettingsProvider);
    await settings.set(AppSettingKeys.tvMode, false);
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    final library = await container.read(localContentLibraryProvider)();
    final runtime = container.read(pluginRuntimeFacadeProvider);
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    final status = await runtime.invoke(const RuntimeStatusInvocation());
    expect(status.isHealthy, isTrue);
    expect(status.platform, 'android');
    evidence['runtimeSmoke'] = {'healthy': true, 'kind': status.runtimeKind, 'arch': status.arch, 'nodeVersion': ping.nodeVersion};

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final image = await _image();
    final inputs = <(String, List<int>)>[
      ('MuMu-$stamp.txt', utf8.encode('第一章 测试\n\nMUMU_TXT_BODY 自有测试正文。\n\n第二章 继续\n\n后续章节正文。')),
      ('MuMu-text-$stamp.epub', _epub(image, comic: false)),
      ('MuMu-comic-$stamp.epub', _epub(image, comic: true)),
    ];
    final screenshots = <String, String>{};
    final router = container.read(appRouterProvider);
    final results = <Map<String, Object?>>[];
    for (var index = 0; index < inputs.length; index++) {
      final (name, bytes) = inputs[index];
      final prepared = await library.prepareLocalImport(
        LocalImportInput(fileName: name, bytes: bytes.length, openRead: () => Stream.value(bytes)),
      );
      expect(prepared.status, LocalImportStatus.awaitingConfirmation, reason: prepared.errorCode);
      final imported = await library.commitLocalImport(prepared.id);
      expect(imported.status, LocalImportStatus.succeeded, reason: imported.errorCode);
      final id = imported.itemId!;
      router.go('/local-document/${Uri.encodeComponent(id.value)}');
      await _wait(tester, () => find.text('开始阅读').evaluate().isNotEmpty);
      await tester.tap(find.text('开始阅读'));
      final comic = index == 2;
      Future<void> waitForContent() => _wait(tester, () {
        if (!comic) return find.textContaining(index == 0 ? 'MUMU_TXT_BODY' : 'MUMU_EPUB_BODY', findRichText: true).evaluate().isNotEmpty;
        return find
            .descendant(of: find.byType(ComicReaderView), matching: find.byType(RawImage))
            .evaluate()
            .any((element) => (element.widget as RawImage).image != null);
      });
      await waitForContent();
      screenshots['local-reader-$index'] = await _capture(capture);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await _wait(tester, () => find.text('开始阅读').evaluate().isNotEmpty);
      await _wait(tester, () => find.byType(TextReaderView).evaluate().isEmpty && find.byType(ComicReaderView).evaluate().isEmpty);
      final progress = await library.loadProgress(id);
      expect(progress, isNotNull, reason: 'Android reader must persist progress on exit');
      await tester.tap(find.text('开始阅读'));
      await waitForContent();
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await _wait(tester, () => find.text('开始阅读').evaluate().isNotEmpty);
      results.add({
        'format': index == 0
            ? 'txt'
            : comic
            ? 'image-epub'
            : 'text-epub',
        'opened': true,
        'progressSaved': true,
        'reopened': true,
      });
    }
    evidence['localReaders'] = results;
    evidence['mumuSmokeScreenshots'] = screenshots;
  }, timeout: const Timeout(Duration(minutes: 4)));
  tv.main();
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) {
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Android page did not reach its expected usable state');
}

Future<String> _capture(GlobalKey key) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final frame = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = (await frame.toByteData(format: ui.ImageByteFormat.png))!;
    return base64Encode(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  } finally {
    frame.dispose();
  }
}

Future<List<int>> _image() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff2563eb), BlendMode.src);
  canvas.drawRect(const Rect.fromLTWH(60, 80, 280, 440), Paint()..color = const Color(0xfffbbf24));
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 600);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

List<int> _epub(List<int> image, {required bool comic}) {
  final archive = Archive();
  void add(String path, String text) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(text)));
  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'OPS/book.opf',
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">mumu-${comic ? 'comic' : 'text'}</dc:identifier><dc:title>MuMu ${comic ? 'Comic' : 'Text'} EPUB</dc:title></metadata><manifest><item id="body" href="body.xhtml" media-type="application/xhtml+xml"/><item id="page" href="page.png" media-type="image/png"/></manifest><spine><itemref idref="body"/></spine></package>',
  );
  add(
    'OPS/body.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>MuMu</title></head><body>${comic ? '<img src="page.png"/><img src="page.png"/>' : '<h1>MuMu</h1><p>MUMU_EPUB_BODY 自有文字 EPUB 正文。</p>'}</body></html>',
  );
  archive.addFile(ArchiveFile.bytes('OPS/page.png', image));
  return ZipEncoder().encode(archive);
}
