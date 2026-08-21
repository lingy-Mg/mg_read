import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_text_reader_state_store.dart';
import 'package:mg_read/features/reader/data/transient_source_text_reader.dart';

/// Resolves a persisted shelf source through the typed Runtime gateway.
///
/// Runtime responses are only used as a reader session data source. The
/// bookshelf identity and progress remain app-owned Content Library data.
final class ContentLibrarySourceTextReader implements LibraryReaderLauncher {
  const ContentLibrarySourceTextReader(this._library, this._gateway);

  final ContentLibrary _library;
  final SourceContentGateway _gateway;

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId, {
    ReaderObserver? observer,
  }) async {
    final item = await _library.getLibraryItem(LibraryItemId(libraryItemId));
    if (item == null) throw StateError('The shelf item is unavailable.');
    if (item.kind != ContentKind.novel) {
      throw StateError('Only text novels can be opened by this reader.');
    }
    final source = item.source;
    if (source == null) {
      throw StateError('The shelf item does not retain a readable source.');
    }
    final detail = await _gateway.getDetail(
      pluginId: source.pluginId,
      id: source.remoteContentId,
    );
    if (detail.summary.contentKind != PluginContentKind.novel) {
      throw StateError('The source no longer provides a text novel.');
    }
    final firstCatalogPage = await _gateway.getChapters(
      pluginId: source.pluginId,
      id: source.remoteContentId,
      pageSize: 100,
    );
    if (firstCatalogPage.items.isEmpty) {
      throw StateError('The source returned no readable chapters.');
    }
    final session = TransientSourceTextReader(
      detail: detail,
      firstCatalogPage: firstCatalogPage,
      loadChapterPage: ({String? cursor, int pageSize = 100}) {
        return _gateway.getChapters(
          pluginId: source.pluginId,
          id: source.remoteContentId,
          cursor: cursor,
          pageSize: pageSize,
        );
      },
      loadChapterContent: (String chapterId) => _gateway.getContent(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        chapterId: chapterId,
      ),
      bookId: item.id.value,
    );
    return session.createLaunchRequest(
      initialChapterId: firstCatalogPage.items.first.id,
      observer: observer,
      stateStore: ContentLibraryTextReaderStateStore(_library, itemId: item.id),
    );
  }
}
