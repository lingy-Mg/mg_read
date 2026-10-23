/// Verifies a real audio progress row survives killing its SQLite writer while
/// the next update is uncommitted. Reopens the same on-disk ContentLibrary,
/// without relying on engine shutdown, lifecycle callbacks or process cleanup.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  test('restart after killing the writer restores its committed chapter and time', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-audio-process-restart-');
    addTearDown(() => root.delete(recursive: true));
    final library = await ContentLibrary.open(dataRoot: root);
    late final LibraryItemId itemId;
    try {
      final item = await library.addLibraryItem(
        const BookshelfAddRequest(
          title: '强杀进度测试',
          author: null,
          kind: ContentKind.audio,
          pluginId: 'fixture',
          pluginVersion: '1.0.0',
          remoteContentId: 'audio-1',
        ),
      );
      itemId = item.id;
      await library.saveProgress(
        LibraryAudioPlaybackProgress(
          itemId: itemId,
          chapterId: 'chapter-1',
          position: const Duration(seconds: 42),
          updatedAtUtc: DateTime.utc(2026, 10, 23),
        ),
      );
    } finally {
      await library.close();
    }
    final helper = File('test/features/media/application/support/audio_progress_crash_probe.dart').absolute.path;
    final writer = await Process.start(_dartExecutable(), <String>['run', helper, root.path, itemId.value]);
    final errors = writer.stderr.transform(utf8.decoder).join();
    int? writerPid;
    addTearDown(() async {
      if (writerPid != null) Process.killPid(writerPid);
      writer.kill();
      await writer.exitCode.timeout(const Duration(seconds: 10));
    });
    final ready = await writer.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 20));
    expect(ready, startsWith('audio-uncommitted-ready:'));
    writerPid = int.parse(ready.split(':').last);
    expect(Process.killPid(writerPid), isTrue);
    await writer.exitCode.timeout(const Duration(seconds: 10));
    writerPid = null;
    final processDiagnostics = await errors;

    final reopened = await ContentLibrary.open(dataRoot: root);
    try {
      final restored = await reopened.loadProgress(itemId) as LibraryAudioPlaybackProgress;
      expect(restored.chapterId, 'chapter-2', reason: processDiagnostics);
      expect(restored.position, const Duration(seconds: 60));
      // The uncommitted chapter-3 / 71-second update must be rolled back whole.
      await reopened.saveProgress(
        LibraryAudioPlaybackProgress(
          itemId: itemId,
          chapterId: 'chapter-2',
          position: const Duration(seconds: 65),
          updatedAtUtc: DateTime.utc(2026, 10, 23),
        ),
      );
      expect((await reopened.loadProgress(itemId) as LibraryAudioPlaybackProgress).position, const Duration(seconds: 65));
    } finally {
      await reopened.close();
    }
  });
}

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}'
      'dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}',
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) throw StateError('Unable to locate Flutter-bundled Dart.');
    directory = parent;
  }
}
