import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_local_reader.dart';
import 'package:mg_read/features/reader/presentation/reader_entry_transition.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('local TXT resume anchor remains visible after first frame and completed pagination', (tester) async {
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    late Directory root;
    late ContentLibrary library;
    late NovelReaderLaunchRequest launched;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mgread-local-txt-resume-');
      library = await ContentLibrary.open(dataRoot: root);
      final imported = await _importText(library, _resumeFixture());
      final readingSession = (await library.openLocalDocumentSession(imported.itemId!))!;
      final chapter = readingSession.chapterAt(2)!;
      final rawChapter = await readingSession.readChapter(chapter.id);
      final rawBlocks = (rawChapter['blocks'] as List).cast<Map>();
      final anchor = rawBlocks.singleWhere((block) => block['id'] == 'p18137');
      expect((anchor['text'] as String).substring(59), startsWith('VISIBLE_RESUME_ANCHOR'));
      await library.saveLocalReadingProgress(
        LibraryReadingProgress(
          itemId: imported.itemId!,
          chapterId: chapter.id,
          paragraphId: 'p18137',
          characterOffset: 59,
          chapterIndex: 2,
          chapterFraction: .5,
          bookFraction: .358974,
          updatedAtUtc: DateTime.utc(2026, 11, 4),
        ),
        readingSession.generation,
      );
      await readingSession.close();
      launched = await ContentLibraryLocalReader(library).launch(imported.itemId!.value) as NovelReaderLaunchRequest;
    });
    final controller = TextReaderController();
    final request = NovelReaderLaunchRequest(
      bookId: launched.bookId,
      dataSource: launched.dataSource,
      stateStore: launched.stateStore,
      seed: launched.seed,
      controller: controller,
      chapterPreloadCount: 0,
      preparationKind: launched.preparationKind,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: ReaderEntryTransition(request: request),
      ),
    );
    await _pumpUntil(
      tester,
      () => controller.snapshot.isReady,
      reason:
          'ready=${controller.snapshot.isReady}, loading=${controller.snapshot.isLoading}, '
          'chapter=${controller.snapshot.chapter?.id}, progress=${controller.snapshot.progress?.paragraphId}, '
          'failure=${controller.snapshot.failure}, readerStatus=${find.byKey(const Key('text-reader-status-message')).evaluate().length}',
    );
    expect(controller.snapshot.chapter?.index, 2);
    expect(controller.snapshot.progress?.paragraphId, 'p18137');
    expect(controller.snapshot.progress?.characterOffset, 59);
    expect(find.textContaining('VISIBLE_RESUME_ANCHOR'), findsOneWidget);

    // Entry handoff restores Android's system bars after the immersive cover.
    // Match MuMu's 81 physical-pixel status inset before progressive reflow.
    tester.view.padding = const FakeViewPadding(top: 81);

    // Let the seed catalog prewarm and progressive pagination settle after the
    // immediate resumed frame, matching the delayed MuMu observation window.
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.snapshot.chapter?.index, 2);
    expect(controller.snapshot.progress?.paragraphId, 'p18137');
    expect(controller.snapshot.progress?.characterOffset, 59);
    expect(find.textContaining('VISIBLE_RESUME_ANCHOR'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
    await tester.runAsync(() async {
      await (launched.dataSource as DisposableReaderDataSource).dispose();
      await library.close();
      await root.delete(recursive: true);
    });
  });
}

Future<LocalImportSnapshot> _importText(ContentLibrary library, String text) async {
  final bytes = utf8.encode(text);
  final staged = await library.prepareLocalImport(
    LocalImportInput(fileName: 'resume.txt', bytes: bytes.length, openRead: () => Stream.value(bytes)),
  );
  expect(staged.status, LocalImportStatus.awaitingConfirmation);
  final committed = await library.commitLocalImport(staged.id);
  expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
  return committed;
}

String _resumeFixture() {
  final chapters = <String>[];
  for (var chapter = 1; chapter <= 6; chapter++) {
    final paragraphs = <String>[];
    for (var paragraph = 1; paragraph <= 60; paragraph++) {
      final text = '验收段落$chapter-${paragraph.toString().padLeft(3, '0')}：这是用于 MuMu 完整验收的自有测试文本。选择文件后必须经过受控复制和解析；阅读进度与书签应在关闭、重开和恢复备份后保持。';
      paragraphs.add('$text$text');
    }
    chapters.add('第$chapter章 验收章节$chapter\n\n${paragraphs.join('\n\n')}');
  }
  final text = chapters.join('\n\n');
  final target = text.indexOf('验收段落3-005');
  if (target != 18137) throw StateError('Fixture anchor no longer matches the MuMu original.');
  return '${text.substring(0, target + 59)}VISIBLE_RESUME_ANCHOR${text.substring(target + 59)}';
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition, {required String reason}) async {
  for (var attempt = 0; attempt < 120 && !condition(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 16)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(condition(), isTrue, reason: 'reader did not reach a usable first frame: $reason');
}
