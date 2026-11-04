/// Cold-start preference, fallback and atomic persistence failure coverage.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  late Directory root;
  late File preference;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-desktop-settings-');
    preference = File('${root.path}/backend.txt');
  });
  tearDown(() => root.delete(recursive: true));
  DesktopRuntimeSettings settings({bool bun = true}) =>
      DesktopRuntimeSettings.forTesting(
        preferenceFile: preference,
        supportsBun: bun,
      );

  test(
    'Node to Bun to Node preserves the active host until cold start',
    () async {
      final first = settings();
      await first.initialize();
      expect(first.active, DesktopRuntimeBackend.node);
      await first.select(DesktopRuntimeBackend.bun);
      await first.initialize();
      expect(first.active, DesktopRuntimeBackend.node);
      expect(first.restartRequired, isTrue);
      final second = settings();
      await second.initialize();
      expect(second.active, DesktopRuntimeBackend.bun);
      expect(second.restartRequired, isFalse);
      await second.select(DesktopRuntimeBackend.node);
      final third = settings();
      await third.initialize();
      expect(third.active, DesktopRuntimeBackend.node);
      expect(await File('${preference.path}.next').exists(), isFalse);
    },
  );

  test(
    'missing Bun and unknown preferences recover to the bundled Node',
    () async {
      for (final stored in ['bun', 'unknown', '']) {
        await preference.writeAsString(stored);
        final current = settings(bun: false);
        await current.initialize();
        expect(current.active, DesktopRuntimeBackend.node);
        await expectLater(
          current.select(DesktopRuntimeBackend.bun),
          throwsUnsupportedError,
        );
        expect(current.selected, DesktopRuntimeBackend.node);
      }
    },
  );

  test(
    'failed write does not change selection and the next save can succeed',
    () async {
      final current = settings();
      await current.initialize();
      await Directory('${preference.path}.next').create();
      await expectLater(
        current.select(DesktopRuntimeBackend.bun),
        throwsA(isA<FileSystemException>()),
      );
      expect(current.selected, DesktopRuntimeBackend.node);
      await Directory('${preference.path}.next').delete();
      await current.select(DesktopRuntimeBackend.bun);
      expect(current.selected, DesktopRuntimeBackend.bun);
    },
  );

  test(
    'damaged or unreadable preference does not block application startup',
    () async {
      await preference.writeAsBytes([0xff, 0xfe]);
      final damaged = settings();
      await damaged.initialize();
      expect(damaged.active, DesktopRuntimeBackend.node);
      await preference.delete();
      await Directory(preference.path).create();
      final unreadable = settings();
      await unreadable.initialize();
      expect(unreadable.active, DesktopRuntimeBackend.node);
      await expectLater(
        unreadable.select(DesktopRuntimeBackend.bun),
        throwsA(isA<FileSystemException>()),
      );
      expect(unreadable.selected, DesktopRuntimeBackend.node);
    },
  );

  test(
    'concurrent saves serialize without losing the last selection',
    () async {
      final current = settings();
      await Future.wait([
        current.select(DesktopRuntimeBackend.bun),
        current.select(DesktopRuntimeBackend.node),
      ]);
      expect((await preference.readAsString()).trim(), 'node');
      expect(current.restartRequired, isFalse);
    },
  );
}
