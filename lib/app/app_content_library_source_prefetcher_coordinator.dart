/// 应用生命周期内的数据源书籍预取器所有者。
///
/// 职责：
/// - 让书架保存与阅读启动复用同一个按书籍 single-flight 的预取器。
/// - 启动重试替换 Content Library 或 gateway 后创建新的资源域。
///
/// 注意：
/// - 状态只属于当前应用组合实例，不使用全局静态可变状态。
/// - 不串行不同书籍；逐书去重与失败清理由预取器自身负责。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

final class AppContentLibrarySourcePrefetcherCoordinator {
  AppContentLibrarySourcePrefetcherCoordinator(this._diagnostics);

  final DiagnosticsManager _diagnostics;
  ContentLibrary? _library;
  SourceContentGateway? _gateway;
  ContentLibrarySourcePrefetcher? _prefetcher;

  ContentLibrarySourcePrefetcher resolve(ContentLibrary library, SourceContentGateway gateway) {
    final current = _prefetcher;
    if (current != null && identical(_library, library) && identical(_gateway, gateway)) {
      return current;
    }
    _library = library;
    _gateway = gateway;
    return _prefetcher = ContentLibrarySourcePrefetcher(library, gateway, diagnostics: _diagnostics);
  }
}
