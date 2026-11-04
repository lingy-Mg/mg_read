/// Verifies the real OS handoff waits before a successor opens shared state.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/desktop_restart.dart';

void main() {
  test('ordinary startup keeps arguments and invalid restart parents fail', () async {
    expect(await awaitDesktopRestartParent(['book.epub']), ['book.epub']);
    for (final args in [
      ['--mgread-restart-parent=bad'],
      ['--mgread-restart-parent=$pid'],
      ['--mgread-restart-parent=0'],
      ['--mgread-restart-parent=12', '--mgread-restart-parent=13'],
    ]) {
      await expectLater(awaitDesktopRestartParent(args), throwsFormatException);
    }
  });

  test('successor waits for a real parent and consumes the private flag', () async {
    final node = Platform.isWindows
        ? 'packages/mg_read_node_runtime/tools/node-v26.10.0-win-x64/node.exe'
        : 'packages/mg_read_node_runtime/tools/node-v26.10.0-darwin-arm64/bin/node';
    final child = await Process.start(node, ['-e', 'console.log("ready"); setTimeout(()=>process.exit(0), 400)']);
    addTearDown(() async {
      child.kill();
      await child.exitCode;
    });
    await child.stdout.first;
    final watch = Stopwatch()..start();
    final args = await awaitDesktopRestartParent(['--mgread-restart-parent=${child.pid}', 'book.epub']);
    expect(args, ['book.epub']);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
    expect(await child.exitCode, 0);
  }, skip: !Platform.isWindows && !Platform.isMacOS);
}
