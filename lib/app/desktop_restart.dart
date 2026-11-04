/// Owns desktop cold-restart handoff. The successor waits for the old process
/// before opening databases or starting Runtime, so two hosts never share data
/// during a switch. Only the executable of this App is launched, without shell.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

const _restartPrefix = '--mgread-restart-parent=';

Future<void> restartDesktopApp() async {
  await Process.start(Platform.resolvedExecutable, ['$_restartPrefix$pid'], mode: ProcessStartMode.detached, runInShell: false);
  exit(0);
}

/// Consumes the private restart option before local-import/CLI argument parsing.
Future<List<String>> awaitDesktopRestartParent(List<String> arguments) async {
  final restart = arguments.where((value) => value.startsWith(_restartPrefix)).toList();
  if (restart.isEmpty) return arguments;
  final parent = restart.length == 1 ? int.tryParse(restart.single.substring(_restartPrefix.length)) : null;
  if (parent == null || parent <= 1 || parent == pid || !(Platform.isWindows || Platform.isMacOS)) {
    throw const FormatException('Invalid desktop restart parent.');
  }
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final open = kernel.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
    final wait = kernel.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>('WaitForSingleObject');
    final close = kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
    final handle = open(0x00100000, 0, parent);
    if (handle != 0) {
      try {
        while (true) {
          final status = wait(handle, 0);
          if (status == 0) break;
          if (status != 258) throw StateError('Cannot wait for desktop restart parent.');
          if (DateTime.now().isAfter(deadline)) throw TimeoutException('Desktop restart parent did not exit.');
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      } finally {
        close(handle);
      }
    }
  } else {
    final kill = DynamicLibrary.process().lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('kill');
    while (kill(parent, 0) == 0) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Desktop restart parent did not exit.');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
  return arguments.where((value) => !value.startsWith(_restartPrefix)).toList();
}
