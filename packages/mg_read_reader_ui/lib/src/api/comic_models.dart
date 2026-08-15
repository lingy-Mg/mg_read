import 'package:flutter/foundation.dart';

import 'models.dart';

@immutable
/// Lightweight metadata displayed by a comic reading surface.
class ComicBookInfo {
  /// Creates comic book metadata supplied by the host.
  const ComicBookInfo({
    required this.id,
    required this.title,
    this.author,
    this.description,
    this.sourceName,
    this.sourceKind = ReaderBookSourceKind.unknown,
  });

  /// Stable book identifier.
  final String id;

  /// Display title.
  final String title;

  /// Optional author display name.
  final String? author;

  /// Optional plain-text description.
  final String? description;

  /// Optional host-managed source display name.
  final String? sourceName;

  /// Host classification of the book source.
  final ReaderBookSourceKind sourceKind;

  @override
  bool operator ==(Object other) =>
      other is ComicBookInfo &&
      id == other.id &&
      title == other.title &&
      author == other.author &&
      description == other.description &&
      sourceName == other.sourceName &&
      sourceKind == other.sourceKind;

  @override
  int get hashCode =>
      Object.hash(id, title, author, description, sourceName, sourceKind);
}

@immutable
/// Metadata for one chapter in an ordered comic catalog.
class ComicChapterInfo {
  /// Creates one stable comic chapter entry.
  const ComicChapterInfo({
    required this.id,
    required this.title,
    required this.index,
    this.availability = ReaderChapterAvailability.unknown,
    this.imageCount,
    this.hasBeenRead = false,
  });

  /// Stable chapter identifier.
  final String id;

  /// Display chapter title.
  final String title;

  /// Zero-based order in the full comic.
  final int index;

  /// Host-reported content availability.
  final ReaderChapterAvailability availability;

  /// Optional total number of images.
  final int? imageCount;

  /// Whether the host considers this chapter read.
  final bool hasBeenRead;

  @override
  bool operator ==(Object other) =>
      other is ComicChapterInfo &&
      id == other.id &&
      title == other.title &&
      index == other.index &&
      availability == other.availability &&
      imageCount == other.imageCount &&
      hasBeenRead == other.hasBeenRead;

  @override
  int get hashCode =>
      Object.hash(id, title, index, availability, imageCount, hasBeenRead);
}

@immutable
/// One cursor-based page of comic chapter metadata.
class ComicChapterCatalogPage {
  /// Creates a catalog page; the comic runtime validates cross-page ordering.
  ComicChapterCatalogPage({
    required List<ComicChapterInfo> items,
    required this.total,
    required this.hasMore,
    this.nextCursor,
  }) : items = List<ComicChapterInfo>.unmodifiable(items);

  /// Immutable entries in full-book order.
  final List<ComicChapterInfo> items;

  /// Opaque host cursor for the next page.
  final String? nextCursor;

  /// Total number of chapters.
  final int total;

  /// Whether another catalog page is available.
  final bool hasMore;

  @override
  bool operator ==(Object other) =>
      other is ComicChapterCatalogPage &&
      listEquals(items, other.items) &&
      nextCursor == other.nextCursor &&
      total == other.total &&
      hasMore == other.hasMore;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(items), nextCursor, total, hasMore);
}

@immutable
/// Metadata for one ordered comic image whose bytes load independently.
class ComicImageInfo {
  /// Creates one stable comic image entry.
  const ComicImageInfo({
    required this.id,
    required this.index,
    this.width,
    this.height,
    this.contentType,
    this.byteLength,
    this.contentVersion,
  });

  /// Stable image identifier within its chapter.
  final String id;

  /// Zero-based order within the chapter.
  final int index;

  /// Optional intrinsic pixel width.
  final int? width;

  /// Optional intrinsic pixel height.
  final int? height;

  /// Optional MIME type such as `image/webp`.
  final String? contentType;

  /// Optional expected encoded size in bytes.
  final int? byteLength;

  /// Optional host cache identity for these exact bytes.
  final String? contentVersion;

  @override
  bool operator ==(Object other) =>
      other is ComicImageInfo &&
      id == other.id &&
      index == other.index &&
      width == other.width &&
      height == other.height &&
      contentType == other.contentType &&
      byteLength == other.byteLength &&
      contentVersion == other.contentVersion;

  @override
  int get hashCode => Object.hash(
    id,
    index,
    width,
    height,
    contentType,
    byteLength,
    contentVersion,
  );
}

@immutable
/// One comic chapter containing ordered image metadata but not image bytes.
class ComicChapterContent {
  /// Creates immutable chapter metadata for progressive image loading.
  ComicChapterContent({
    required this.chapterId,
    required this.title,
    required List<ComicImageInfo> images,
    this.contentVersion,
  }) : images = List<ComicImageInfo>.unmodifiable(images);

  /// Stable chapter identifier.
  final String chapterId;

  /// Display chapter title.
  final String title;

  /// Ordered images loaded progressively by identifier.
  final List<ComicImageInfo> images;

  /// Optional host version for the chapter's ordered image list.
  final String? contentVersion;

  @override
  bool operator ==(Object other) =>
      other is ComicChapterContent &&
      chapterId == other.chapterId &&
      title == other.title &&
      listEquals(images, other.images) &&
      contentVersion == other.contentVersion;

  @override
  int get hashCode =>
      Object.hash(chapterId, title, Object.hashAll(images), contentVersion);
}

@immutable
/// Layout-independent comic progress anchored to an image identity.
class ComicReaderProgress {
  /// Creates semantic comic progress.
  const ComicReaderProgress({
    required this.chapterId,
    required this.imageId,
    this.imageFraction = 0,
    this.chapterIndex = 0,
    this.chapterFraction = 0,
    this.bookFraction = 0,
  });

  /// Stable current chapter identifier.
  final String chapterId;

  /// Stable current image identifier.
  final String imageId;

  /// Vertical fraction through [imageId], from 0 to 1.
  final double imageFraction;

  /// Zero-based chapter order.
  final int chapterIndex;

  /// Displayable progress through the current chapter.
  final double chapterFraction;

  /// Displayable progress through the complete comic.
  final double bookFraction;

  /// Returns a copy with the supplied fields replaced.
  ComicReaderProgress copyWith({
    String? chapterId,
    String? imageId,
    double? imageFraction,
    int? chapterIndex,
    double? chapterFraction,
    double? bookFraction,
  }) => ComicReaderProgress(
    chapterId: chapterId ?? this.chapterId,
    imageId: imageId ?? this.imageId,
    imageFraction: imageFraction ?? this.imageFraction,
    chapterIndex: chapterIndex ?? this.chapterIndex,
    chapterFraction: chapterFraction ?? this.chapterFraction,
    bookFraction: bookFraction ?? this.bookFraction,
  );

  @override
  bool operator ==(Object other) =>
      other is ComicReaderProgress &&
      chapterId == other.chapterId &&
      imageId == other.imageId &&
      imageFraction == other.imageFraction &&
      chapterIndex == other.chapterIndex &&
      chapterFraction == other.chapterFraction &&
      bookFraction == other.bookFraction;

  @override
  int get hashCode => Object.hash(
    chapterId,
    imageId,
    imageFraction,
    chapterIndex,
    chapterFraction,
    bookFraction,
  );
}

@immutable
/// Host-persisted comic bookmark anchored to one image.
class ComicReaderBookmark {
  /// Creates a semantic comic bookmark.
  const ComicReaderBookmark({
    required this.id,
    required this.bookId,
    required this.chapterId,
    required this.imageId,
    required this.imageFraction,
    required this.chapterTitle,
    required this.createdAt,
  });

  /// Stable bookmark identifier.
  final String id;

  /// Stable book identifier.
  final String bookId;

  /// Stable chapter identifier.
  final String chapterId;

  /// Stable image identifier.
  final String imageId;

  /// Vertical fraction through the image.
  final double imageFraction;

  /// Chapter title captured for display.
  final String chapterTitle;

  /// Time at which the bookmark was created.
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      other is ComicReaderBookmark &&
      id == other.id &&
      bookId == other.bookId &&
      chapterId == other.chapterId &&
      imageId == other.imageId &&
      imageFraction == other.imageFraction &&
      chapterTitle == other.chapterTitle &&
      createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    bookId,
    chapterId,
    imageId,
    imageFraction,
    chapterTitle,
    createdAt,
  );
}

@immutable
/// Persisted presentation settings for the vertical comic reader.
class ComicReaderPreferences {
  /// Creates comic reader preferences with safe defaults.
  const ComicReaderPreferences({
    this.brightness = 1,
    this.keepScreenOn = true,
    this.immersiveMode = false,
    this.imageSpacing = 0,
  });

  /// Default settings used when the host has no saved value.
  static const defaults = ComicReaderPreferences();

  /// Reader overlay brightness from 0.25 to 1.0.
  final double brightness;

  /// Requests display-awake during an active foreground session.
  final bool keepScreenOn;

  /// Requests immersive mode on supported platforms.
  final bool immersiveMode;

  /// Logical pixels between adjacent images, normalized from 0 to 24.
  final double imageSpacing;

  /// Returns preferences constrained to safe layout ranges.
  ComicReaderPreferences normalized() => ComicReaderPreferences(
    brightness: brightness.isFinite
        ? brightness.clamp(.25, 1).toDouble()
        : ComicReaderPreferences.defaults.brightness,
    keepScreenOn: keepScreenOn,
    immersiveMode: immersiveMode,
    imageSpacing: imageSpacing.isFinite
        ? imageSpacing.clamp(0, 24).toDouble()
        : ComicReaderPreferences.defaults.imageSpacing,
  );

  /// Returns a copy with the supplied fields replaced.
  ComicReaderPreferences copyWith({
    double? brightness,
    bool? keepScreenOn,
    bool? immersiveMode,
    double? imageSpacing,
  }) => ComicReaderPreferences(
    brightness: brightness ?? this.brightness,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    immersiveMode: immersiveMode ?? this.immersiveMode,
    imageSpacing: imageSpacing ?? this.imageSpacing,
  );

  @override
  bool operator ==(Object other) =>
      other is ComicReaderPreferences &&
      brightness == other.brightness &&
      keepScreenOn == other.keepScreenOn &&
      immersiveMode == other.immersiveMode &&
      imageSpacing == other.imageSpacing;

  @override
  int get hashCode =>
      Object.hash(brightness, keepScreenOn, immersiveMode, imageSpacing);
}

@immutable
/// Read-only state published by [ComicReaderController].
class ComicReaderSnapshot {
  /// Creates an immutable comic controller snapshot.
  const ComicReaderSnapshot({
    required this.isReady,
    required this.isLoading,
    required this.controlsVisible,
    this.book,
    this.chapter,
    this.progress,
    this.failure,
  });

  /// Creates the loading snapshot before a comic reader publishes state.
  const ComicReaderSnapshot.initial()
    : isReady = false,
      isLoading = true,
      controlsVisible = false,
      book = null,
      chapter = null,
      progress = null,
      failure = null;

  /// Whether usable chapter content is available.
  final bool isReady;

  /// Whether initialization or chapter metadata is loading.
  ///
  /// Individual image-byte loads expose local placeholders and errors without
  /// changing this session-level flag.
  final bool isLoading;

  /// Whether comic reader chrome is visible.
  final bool controlsVisible;

  /// Currently loaded comic metadata.
  final ComicBookInfo? book;

  /// Currently opened chapter metadata.
  final ComicChapterInfo? chapter;

  /// Latest semantic image position.
  final ComicReaderProgress? progress;

  /// Latest recoverable failure.
  final ReaderFailure? failure;

  @override
  bool operator ==(Object other) =>
      other is ComicReaderSnapshot &&
      isReady == other.isReady &&
      isLoading == other.isLoading &&
      controlsVisible == other.controlsVisible &&
      book == other.book &&
      chapter == other.chapter &&
      progress == other.progress &&
      failure == other.failure;

  @override
  int get hashCode => Object.hash(
    isReady,
    isLoading,
    controlsVisible,
    book,
    chapter,
    progress,
    failure,
  );
}
