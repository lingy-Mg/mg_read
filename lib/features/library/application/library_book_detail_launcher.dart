import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// Typed inputs for the shared source-detail presentation of a shelf item.
final class LibraryBookDetailLaunchData {
  const LibraryBookDetailLaunchData({
    required this.pluginId,
    required this.remoteContentId,
    required this.initialContent,
    required this.initialCatalog,
    required this.sourceName,
  });

  final String pluginId;
  final String remoteContentId;
  final PluginContentSummary initialContent;
  final PluginChaptersResult initialCatalog;
  final String sourceName;
}

/// Resolves a stable shelf ID without exposing Content Library persistence.
abstract interface class LibraryBookDetailLauncher {
  Future<LibraryBookDetailLaunchData> load(String bookId);
}

final libraryBookDetailLauncherProvider = Provider<LibraryBookDetailLauncher?>(
  (Ref ref) => null,
);
