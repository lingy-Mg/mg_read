/// Exports a leased video cache file through the platform's save dialog.
///
/// On Android, SAF owns failed-output cleanup. Desktop copies stage beside the
/// selected destination so an interrupted copy leaves the previous file intact.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:mg_read/features/import_export/data/android_backup_file_exporter.dart';

bool get canExportSourceVideo => Platform.isAndroid || Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<bool> exportSourceVideo(File file, String fileName, String mimeType) async {
  if (Platform.isAndroid) {
    return const AndroidBackupFileExporter().exportFile(file.path, fileName: fileName, mimeType: mimeType, deleteSourceAfterExport: false);
  }
  if (!canExportSourceVideo) throw UnsupportedError('Video export is unavailable on this platform.');
  final location = await getSaveLocation(suggestedName: fileName, confirmButtonText: '导出');
  if (location == null) return false;
  final destination = File(location.path);
  if (await destination.exists() && await FileSystemEntity.identical(file.path, destination.path)) return true;
  final staging = await destination.parent.createTemp('.mgread-video-');
  final stagedFile = File.fromUri(staging.uri.resolve('video.partial'));
  try {
    await file.copy(stagedFile.path);
    await stagedFile.rename(destination.path);
    return true;
  } finally {
    try {
      if (await stagedFile.exists()) await stagedFile.delete();
      await staging.delete();
    } on FileSystemException {
      // Cleanup must preserve the original export result.
    }
  }
}
