import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Application port for saving one typed discovery result to the local shelf.
abstract interface class DiscoveryBookshelfSaver {
  Future<void> save({
    required PluginSourceDescriptor source,
    required PluginContentSummary content,
  });
}

/// Main-app adapter that writes only through the public Content Library API.
final class ContentLibraryDiscoveryBookshelfSaver
    implements DiscoveryBookshelfSaver {
  const ContentLibraryDiscoveryBookshelfSaver(this._library);

  final ContentLibrary _library;

  @override
  Future<void> save({
    required PluginSourceDescriptor source,
    required PluginContentSummary content,
  }) async {
    await _library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: content.title,
        author: content.author,
        kind: switch (content.contentKind) {
          PluginContentKind.novel => ContentKind.novel,
          PluginContentKind.manga => ContentKind.manga,
        },
        pluginId: source.id,
        pluginVersion: source.pluginVersion,
        remoteContentId: content.id,
      ),
    );
  }
}

/// Test-only default: real app composition overrides this with Content Library.
final discoveryBookshelfSaverProvider = Provider<DiscoveryBookshelfSaver>(
  (Ref ref) => const _UnavailableDiscoveryBookshelfSaver(),
);

final class _UnavailableDiscoveryBookshelfSaver
    implements DiscoveryBookshelfSaver {
  const _UnavailableDiscoveryBookshelfSaver();

  @override
  Future<void> save({
    required PluginSourceDescriptor source,
    required PluginContentSummary content,
  }) => Future<void>.error(StateError('Local bookshelf is unavailable.'));
}
