import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/local_import/application/local_import_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ContentLibrary library;
  late LocalImportController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-local-ui-');
    library = await ContentLibrary.open(dataRoot: root);
    controller = LocalImportController(() async => library);
  });

  tearDown(() async {
    controller.dispose();
    await library.close();
    await root.delete(recursive: true);
  });

  test('real TXT preview, encoding option, confirmation and persistent completion', () async {
    final bytes = utf8.encode('第一章 清晨\n\n这是第一段正文。\n\n第二章 远方\n\n这是第二段正文。');
    controller.acceptInputs(<LocalImportInput>[
      LocalImportInput(fileName: '真实样例.txt', bytes: bytes.length, openRead: () => Stream.value(bytes)),
    ]);
    expect(controller.selected, hasLength(1));
    await controller.importSelected();

    final job = controller.jobs.single;
    expect(job.status, LocalImportStatus.awaitingConfirmation);
    expect(controller.previews[job.id]!.join(), contains('这是第一段正文'));
    await controller.setOptions(job.id, const LocalDocumentParseOptions(encoding: 'utf-8', chapterRule: 'chinese'));
    expect(controller.jobs.single.options.chapterRule, 'chinese');
    await controller.commit(job.id, title: '确认后的书名', author: '作者');

    expect(controller.jobs.single.status, LocalImportStatus.succeeded);
    expect(controller.jobs.single.title, '确认后的书名');
    expect(controller.documents.single.title, '确认后的书名');
    final session = await library.openLocalDocumentSession(controller.documents.single.id);
    expect(session, isNotNull);
    final chapter = session!.chapterAt(0)!;
    final body = await session.readChapter(chapter.id);
    expect(body.toString(), contains('这是第一段正文'));
    await session.close();
  });

  test('unsupported and malformed inputs report item-level failures and retry uses staged source', () async {
    controller.acceptInputs(<LocalImportInput>[
      LocalImportInput(fileName: 'image.png', openRead: () => Stream.value(<int>[1])),
    ]);
    expect(controller.selected, isEmpty);
    expect(controller.errors['image.png'], contains('仅支持'));

    final bad = <int>[0xff, 0xfe, 0x41];
    controller.acceptInputs(<LocalImportInput>[
      LocalImportInput(fileName: 'malformed.txt', bytes: bad.length, openRead: () => Stream.value(bad)),
    ]);
    await controller.importSelected(options: const LocalDocumentParseOptions(encoding: 'utf-16le'));
    final failure = controller.jobs.single;
    expect(failure.status, LocalImportStatus.failed);
    await controller.retry(failure.id);
    expect(controller.jobs.where((job) => job.fileName == 'malformed.txt'), hasLength(1));
    expect(controller.jobs.single.id, failure.id);
    expect(controller.jobs.single.status, LocalImportStatus.failed);
  });

  test('persists every batch entry before reading the first file and cancels queued work', () async {
    final sourceOpened = Completer<void>();
    final blockedSource = StreamController<List<int>>();
    final quick = utf8.encode('正文');
    controller.acceptInputs(<LocalImportInput>[
      LocalImportInput(
        fileName: 'blocked.txt',
        openRead: () {
          if (!sourceOpened.isCompleted) sourceOpened.complete();
          return blockedSource.stream;
        },
      ),
      LocalImportInput(fileName: 'queued.txt', bytes: quick.length, openRead: () => Stream.value(quick)),
    ]);

    final import = controller.importSelected();
    await sourceOpened.future.timeout(const Duration(seconds: 5));
    final registered = await library.localImportJobs();
    expect(registered.where((job) => job.fileName == 'blocked.txt'), hasLength(1));
    expect(registered.where((job) => job.fileName == 'queued.txt'), hasLength(1));
    expect(registered.where((job) => job.fileName == 'queued.txt').single.status, LocalImportStatus.queued);

    await controller.stopRemainingBatch();
    await import.timeout(const Duration(seconds: 5));
    await blockedSource.close();
    final finalJobs = await library.localImportJobs();
    expect(finalJobs.where((job) => job.fileName == 'blocked.txt').single.status, LocalImportStatus.cancelled);
    expect(finalJobs.where((job) => job.fileName == 'queued.txt').single.status, LocalImportStatus.cancelled);
  });
}
