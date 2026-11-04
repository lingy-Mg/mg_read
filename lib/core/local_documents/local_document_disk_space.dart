/// Best-effort free-space lookup for local-document staging.
///
/// The caller remains responsible for handling `null` and for errors that can
/// occur after this check; available space can change before a write begins.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Returns bytes available to the current user on [directory]'s volume.
///
/// Unsupported platforms, unavailable native utilities, malformed output and
/// all lookup failures return `null` so this advisory check never blocks an
/// otherwise valid import.
Future<int?> availableLocalDocumentBytes(Directory directory) async {
  try {
    if (Platform.isWindows) return _windowsAvailableBytes(directory);
    if (Platform.isMacOS || Platform.isAndroid || Platform.isLinux) {
      final process = await Process.start('df', <String>['-Pk', directory.path], runInShell: false);
      try {
        final output = process.stdout.toList();
        final errors = process.stderr.drain<void>();
        final status = await process.exitCode.timeout(const Duration(seconds: 3));
        await errors;
        if (status != 0) return null;
        return _availableBytesFromDf(String.fromCharCodes((await output).expand((chunk) => chunk)));
      } finally {
        process.kill();
      }
    }
  } on Object {
    return null;
  }
  return null;
}

int? _windowsAvailableBytes(Directory directory) {
  final path = directory.absolute.path.toNativeUtf16();
  final available = calloc<Uint64>();
  try {
    final api = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
          int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
        >('GetDiskFreeSpaceExW');
    if (api(path, available, nullptr, nullptr) == 0) return null;
    return available.value;
  } finally {
    calloc.free(available);
    calloc.free(path);
  }
}

int? _availableBytesFromDf(String output) {
  for (final line in output.split('\n').skip(1).toList(growable: false).reversed) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 5) continue;
    final availableKilobytes = int.tryParse(fields[3]);
    if (availableKilobytes == null || availableKilobytes < 0) continue;
    return availableKilobytes * 1024;
  }
  return null;
}
