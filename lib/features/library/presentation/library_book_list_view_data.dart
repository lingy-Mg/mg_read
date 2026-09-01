/// 书架列表的展示数据。
///
/// 职责：
/// - 向多个书架列表组件提供不可变的行数据与封面请求。
/// - 保持展示模型与 Runtime、存储和网络实现解耦。
///
/// 注意：
/// - 封面请求由组件异步解析，构造展示数据不得等待图片。
/// - 业务动作只由页面通过显式回调处理。
///
library;

import 'package:flutter/foundation.dart';

import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// 更新、书架和阅读记录列表共用的不可变展示数据。
@immutable
final class LibraryBookListItemViewData {
  /// Creates one display-ready book-list row.
  LibraryBookListItemViewData({
    required this.id,
    required this.title,
    required this.coverVariant,
    required this.status,
    this.coverUrl,
    this.coverBytes,
    this.coverRequest,
    this.coverAssetPath,
    this.subtitle,
    this.activityLabel,
    this.hasAttentionIndicator = false,
    this.isCoverBlurred = false,
    Iterable<LibraryMetadataTagViewData> tags = const <LibraryMetadataTagViewData>[],
  }) : assert(id != ''),
       assert(title != ''),
       tags = List<LibraryMetadataTagViewData>.unmodifiable(tags);

  /// Stable host-owned identifier. It is never source content or a URL.
  final String id;

  /// Primary title shown at the top of the row.
  final String title;

  /// Optional source cover retained by the app-owned shelf projection.
  final Uri? coverUrl;

  /// Cover bytes loaded from the app-owned persistent cover object.
  final List<int>? coverBytes;

  /// Background source-cover request; it never delays list data rendering.
  final BookCoverRequest? coverRequest;

  /// Context-specific secondary text, such as the latest or last-read chapter.
  final String? subtitle;

  /// Compact activity text aligned before the row's overflow affordance.
  ///
  /// Update, shelf, and history adapters can respectively map an update time,
  /// a shelf timestamp, or a last-read time here without changing the layout.
  final String? activityLabel;

  final LibraryCoverVariant coverVariant;
  final LibraryBookStatus status;

  /// Optional local cover fixture used by static screens.
  final String? coverAssetPath;

  /// Whether an enabled presentation should render the small attention dot.
  final bool hasAttentionIndicator;

  /// Whether the source cover should be visually hidden for local privacy.
  final bool isCoverBlurred;

  final List<LibraryMetadataTagViewData> tags;
}

/// A small source or availability tag attached to a book row.
@immutable
final class LibraryMetadataTagViewData {
  /// Creates one immutable source or availability tag.
  const LibraryMetadataTagViewData({required this.label, required this.tone}) : assert(label != '');

  final String label;
  final LibraryMetadataTone tone;
}

/// Neutral visual variants for locally drawn cover placeholders.
enum LibraryCoverVariant { dusk, dawn, ocean, indigo, ember }

/// The display category used by library list controls.
enum LibraryBookStatus { ongoing, completed, local }

/// Color treatment for a metadata tag, resolved by the active theme.
enum LibraryMetadataTone { neutral, accent, success }
