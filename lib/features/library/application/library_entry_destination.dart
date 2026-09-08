/// 书架条目继续阅读/播放的宿主分发。
///
/// 职责：
/// - 将四种公开内容类型映射到阅读器或对应播放器。
/// - 为书架列表和首页继续区提供同一分发边界。
///
/// 注意：
/// - 这里只决定宿主，不读取进度、Runtime 或路由状态。
library;

import 'package:mg_read/core/content_library/content_library.dart';

enum LibraryEntryDestination { reader, audioPlayer, videoPlayer }

LibraryEntryDestination libraryEntryDestination(ContentKind kind) => switch (kind) {
  ContentKind.novel || ContentKind.manga => LibraryEntryDestination.reader,
  ContentKind.audio => LibraryEntryDestination.audioPlayer,
  ContentKind.video => LibraryEntryDestination.videoPlayer,
};
