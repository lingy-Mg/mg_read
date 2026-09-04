/// 阅读器插件宿主页。
///
/// 职责：
/// - 只通过阅读器公开 API 按密封请求装配一次小说或漫画阅读会话。
/// - 不持有入场动效、路由、Runtime 或持久化实现。
///
/// 注意：
/// - 首帧与失败通知由外层 ReaderEntryTransition 或宿主 Observer 消费。
///
library;

import 'package:flutter/material.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Application page that hosts the reader plugin through its public API.
class ReaderHostPage extends StatelessWidget {
  /// Creates a page for one resolved reader launch [request].
  const ReaderHostPage({required this.request, super.key});

  /// The main-application inputs for this reading session.
  final ReaderLaunchRequest request;

  @override
  Widget build(BuildContext context) {
    final request = this.request;
    return Scaffold(
      body: switch (request) {
        NovelReaderLaunchRequest request => TextReaderView(
          bookId: request.bookId,
          dataSource: request.dataSource,
          stateStore: request.stateStore,
          seed: request.seed,
          chapterPreloadCount: request.chapterPreloadCount,
          observer: request.observer,
          controller: request.controller,
          extensions: request.extensions,
        ),
        ComicReaderLaunchRequest request => ComicReaderView(
          bookId: request.bookId,
          dataSource: request.dataSource,
          stateStore: request.stateStore,
          observer: request.observer,
          controller: request.controller,
          commentFeed: request.commentFeed,
        ),
      },
    );
  }
}
