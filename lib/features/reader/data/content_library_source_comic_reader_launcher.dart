/// 书架漫画的本地优先启动器。
///
/// 职责：
/// - 与小说启动器共享入架预取、首内容准备和书架内存预热边界。
/// - 在导航前解析目标章节首图，并把持久/网络路径写入统一启动请求。
///
/// 注意：
/// - 音频和视频不进入本启动器。
/// - 图片网络会话仍由漫画数据源随阅读路由成对释放。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';
import 'package:mg_read/features/reader/data/content_library_source_comic_reader.dart';

/// Opens shelf manga through the same local-first preparation contract as novels.
final class ContentLibrarySourceComicReader implements LibraryReaderLauncher, LocalShelfReaderPrewarmer {
  const ContentLibrarySourceComicReader(this._library, this._gateway, {this.prefetcher, this.settings, this.httpClientFactory});

  final ContentLibrary _library;
  final SourceContentGateway _gateway;
  final ContentLibrarySourcePrefetcher? prefetcher;
  final AppSettingsManager? settings;
  final ComicHttpClientFactory? httpClientFactory;

  @override
  Future<ComicReaderLaunchRequest> launch(String libraryItemId) async {
    final itemId = LibraryItemId(libraryItemId);
    var item = await _library.getLibraryItem(itemId);
    if (item == null) {
      throw ReaderLaunchFailure(reason: ReaderLaunchFailureReason.shelfItemMissing, error: AppError.fromCode(AppErrorCode.notFound));
    }
    if (item.kind != ContentKind.manga) {
      throw ReaderLaunchFailure(
        reason: ReaderLaunchFailureReason.unsupportedContentKind,
        error: AppError.fromCode(AppErrorCode.unsupported),
      );
    }
    if (prefetcher?.hasInFlight(item.id.value) == true) {
      try {
        await prefetcher!.prepareForReading(item);
      } on Object {
        // The launch data source retries the same local-first boundary.
      }
      item = await _library.getLibraryItem(item.id) ?? item;
    }
    final dataSource = _dataSource(item);
    try {
      final preparation = await dataSource.prepareFirstContent();
      return await _request(item, dataSource, preparation);
    } on Object {
      await dataSource.dispose();
      rethrow;
    }
  }

  @override
  Future<ComicReaderLaunchRequest?> warmLocal(String libraryItemId) async {
    final item = await _library.getLibraryItem(LibraryItemId(libraryItemId));
    if (item == null || item.kind != ContentKind.manga) return null;
    final dataSource = _dataSource(item);
    final estimatedBytes = await dataSource.warmLocalFirstContent();
    if (estimatedBytes == null) {
      await dataSource.dispose();
      return null;
    }
    return _request(item, dataSource, (
      estimatedBytes: estimatedBytes,
      kind: ReaderLaunchPreparationKind.memory,
      networkElapsed: Duration.zero,
    ));
  }

  ContentLibraryComicReaderDataSource _dataSource(LibraryItem item) =>
      ContentLibraryComicReaderDataSource(library: _library, gateway: _gateway, item: item, httpClientFactory: httpClientFactory);

  Future<List<int>?> _cachedCover(LibraryItem item) async {
    try {
      final url = item.coverUrl;
      if (url == null) return null;
      final source = item.source;
      final bytes = await _library.readCover(
        CoverKey(pluginId: source.pluginId, pluginVersion: source.pluginVersion, remoteContentId: source.remoteContentId, coverUrl: url),
      );
      return bytes == null || bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    }
  }

  Future<ComicReaderLaunchRequest> _request(
    LibraryItem item,
    ContentLibraryComicReaderDataSource dataSource,
    ({int estimatedBytes, ReaderLaunchPreparationKind kind, Duration networkElapsed}) preparation,
  ) async {
    return ComicReaderLaunchRequest(
      bookId: item.id.value,
      dataSource: dataSource,
      stateStore: ContentLibraryComicReaderStateStore(_library, itemId: item.id, settings: settings),
      entryCoverBytes: await _cachedCover(item),
      estimatedWarmBytes: preparation.estimatedBytes,
      preparationKind: preparation.kind,
      networkPreparationElapsed: preparation.networkElapsed,
    );
  }
}
