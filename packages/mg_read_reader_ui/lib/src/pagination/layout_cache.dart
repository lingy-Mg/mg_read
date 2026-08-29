import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'text_paginator.dart';

/// Strict identity for a measured text layout.
///
/// Every field that can change line breaks is part of the key. A missing
/// content version is scoped to the current reader session, so an unknown
/// version can never accidentally reuse a layout from another session.
@immutable
class ReaderLayoutFingerprint {
  const ReaderLayoutFingerprint({
    required this.chapterId,
    required this.contentVersion,
    required this.sessionId,
    required this.viewport,
    required this.safeArea,
    required this.devicePixelRatio,
    required this.textScale,
    required this.fontVersion,
    required this.layoutSettings,
    required this.textDirection,
    required this.fontSize,
    required this.fontWeight,
    required this.letterSpacing,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.firstLineIndent,
    required this.horizontalPadding,
    required this.topPadding,
    required this.bottomPadding,
    required this.paragraphCommentPlaceholder,
    required this.chapterCommentPlaceholder,
  });

  final String chapterId;
  final String? contentVersion;
  final int sessionId;
  final Size viewport;
  final EdgeInsets safeArea;
  final double devicePixelRatio;
  final double textScale;
  final String fontVersion;
  final String layoutSettings;
  final TextDirection textDirection;
  final double fontSize;
  final int fontWeight;
  final double letterSpacing;
  final double lineHeight;
  final double paragraphSpacing;
  final int firstLineIndent;
  final double horizontalPadding;
  final double topPadding;
  final double bottomPadding;
  final double paragraphCommentPlaceholder;
  final double chapterCommentPlaceholder;

  @override
  bool operator ==(Object other) =>
      other is ReaderLayoutFingerprint &&
      chapterId == other.chapterId &&
      contentVersion == other.contentVersion &&
      (contentVersion != null || sessionId == other.sessionId) &&
      viewport == other.viewport &&
      safeArea == other.safeArea &&
      devicePixelRatio == other.devicePixelRatio &&
      textScale == other.textScale &&
      fontVersion == other.fontVersion &&
      layoutSettings == other.layoutSettings &&
      textDirection == other.textDirection &&
      fontSize == other.fontSize &&
      fontWeight == other.fontWeight &&
      letterSpacing == other.letterSpacing &&
      lineHeight == other.lineHeight &&
      paragraphSpacing == other.paragraphSpacing &&
      firstLineIndent == other.firstLineIndent &&
      horizontalPadding == other.horizontalPadding &&
      topPadding == other.topPadding &&
      bottomPadding == other.bottomPadding &&
      paragraphCommentPlaceholder == other.paragraphCommentPlaceholder &&
      chapterCommentPlaceholder == other.chapterCommentPlaceholder;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    chapterId,
    contentVersion,
    contentVersion == null ? sessionId : 0,
    viewport,
    safeArea,
    devicePixelRatio,
    textScale,
    fontVersion,
    layoutSettings,
    textDirection,
    fontSize,
    fontWeight,
    letterSpacing,
    lineHeight,
    paragraphSpacing,
    firstLineIndent,
    horizontalPadding,
    topPadding,
    bottomPadding,
    paragraphCommentPlaceholder,
    chapterCommentPlaceholder,
  ]);
}

/// Small session-local LRU for completed pagination results.
class ReaderLayoutLru {
  ReaderLayoutLru({this.capacity = 6, this.maxCharacters = 500000})
    : assert(capacity > 0),
      assert(maxCharacters > 0);

  final int capacity;
  final int maxCharacters;
  final LinkedHashMap<ReaderLayoutFingerprint, List<ReaderPage>> _entries =
      LinkedHashMap<ReaderLayoutFingerprint, List<ReaderPage>>();
  int _characters = 0;

  List<ReaderPage>? take(ReaderLayoutFingerprint key) {
    final List<ReaderPage>? value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  /// Reads a completed layout without changing its LRU position.
  ///
  /// This is used while composing an adjacent chapter boundary. A build must
  /// not mutate cache recency merely because Flutter requested an offscreen
  /// page.
  List<ReaderPage>? peek(ReaderLayoutFingerprint key) => _entries[key];

  /// Returns whether a completed layout is present without removing it.
  bool contains(ReaderLayoutFingerprint key) => _entries.containsKey(key);

  /// Returns whether [pages] fits the bounded character budget.
  bool canStore(List<ReaderPage> pages) =>
      _characterCount(pages) <= maxCharacters;

  void put(ReaderLayoutFingerprint key, List<ReaderPage> pages) {
    final List<ReaderPage> value = List<ReaderPage>.unmodifiable(pages);
    final int characters = _characterCount(value);
    final List<ReaderPage>? previous = _entries.remove(key);
    if (previous != null) _characters -= _characterCount(previous);
    if (characters > maxCharacters) return;
    _entries[key] = value;
    _characters += characters;
    while (_entries.length > capacity || _characters > maxCharacters) {
      final ReaderLayoutFingerprint oldest = _entries.keys.first;
      _characters -= _characterCount(_entries.remove(oldest)!);
    }
  }

  void clear() {
    _entries.clear();
    _characters = 0;
  }

  int _characterCount(List<ReaderPage> pages) => pages.fold<int>(
    0,
    (int total, ReaderPage page) =>
        total +
        page.blocks.fold<int>(
          0,
          (int pageTotal, ReaderPageBlock block) =>
              pageTotal + block.text.length,
        ),
  );
}
