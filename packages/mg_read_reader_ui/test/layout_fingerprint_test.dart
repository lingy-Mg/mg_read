import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/pagination/layout_cache.dart';
import 'package:novel_reader_ui/src/pagination/text_paginator.dart';

void main() {
  test('every layout-affecting identity change misses the fingerprint', () {
    final ReaderLayoutFingerprint base = _key();
    final List<ReaderLayoutFingerprint> changed = <ReaderLayoutFingerprint>[
      _key(viewport: const Size(520, 720)),
      _key(safeArea: const EdgeInsets.only(top: 24)),
      _key(devicePixelRatio: 3),
      _key(textScale: 1.3),
      _key(fontVersion: 'font-v2'),
      _key(layoutSettings: 'line-height-2.1'),
      _key(paragraphCommentPlaceholder: 48),
      _key(chapterCommentPlaceholder: 168),
      _key(textDirection: TextDirection.rtl),
    ];

    for (final ReaderLayoutFingerprint candidate in changed) {
      expect(candidate, isNot(equals(base)));
    }
    expect(
      _key(contentVersion: null, sessionId: 2),
      isNot(equals(_key(contentVersion: null, sessionId: 1))),
    );
    expect(
      _key(contentVersion: 'stable-v1', sessionId: 2),
      equals(_key(contentVersion: 'stable-v1', sessionId: 1)),
    );
  });

  test('bounded LRU reuses versioned layouts across reader sessions', () {
    final ReaderLayoutLru cache = ReaderLayoutLru(capacity: 1);
    final ReaderLayoutFingerprint versioned = _key(contentVersion: 'v1');
    final ReaderPage page = ReaderPage(
      blocks: <ReaderPageBlock>[
        const ReaderPageBlock(
          paragraphId: 'p1',
          text: '正文',
          startOffset: 0,
          isParagraphStart: true,
          isParagraphEnd: true,
        ),
      ],
    );
    cache.put(versioned, <ReaderPage>[page]);
    expect(cache.take(_key(contentVersion: 'v1', sessionId: 99)), isNotNull);

    final ReaderLayoutFingerprint unknownSession = _key(
      contentVersion: null,
      sessionId: 1,
    );
    cache.put(unknownSession, <ReaderPage>[page]);
    expect(cache.take(_key(contentVersion: null, sessionId: 2)), isNull);
  });

  test(
    'pagination batch hook proves work is split without a final full call',
    () {
      var calls = 0;
      final TextPaginator paginator = TextPaginator(
        onBatchPaginated: () => calls++,
      );
      final TextChapterContent chapter = TextChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        paragraphs: List<TextParagraph>.generate(
          18,
          (int index) => TextParagraph(id: 'p$index', text: '段落 $index。'),
        ),
      );
      final TextStyle style = const TextStyle(fontSize: 16, height: 1.5);
      for (var start = 0; start < chapter.paragraphs.length; start += 6) {
        final int end = (start + 6).clamp(0, chapter.paragraphs.length);
        paginator.paginate(
          chapter: TextChapterContent(
            chapterId: chapter.chapterId,
            title: chapter.title,
            paragraphs: chapter.paragraphs.sublist(start, end),
          ),
          width: 300,
          height: 500,
          titleStyle: style,
          bodyStyle: style,
          paragraphSpacing: 8,
          includeChapterTitle: start == 0,
        );
      }
      expect(calls, 3);
    },
  );

  test('anchor-first pagination does not visit preceding paragraphs', () {
    final List<String> visited = <String>[];
    final TextPaginator paginator = TextPaginator(
      onParagraphVisited: visited.add,
    );
    final List<TextParagraph> fullParagraphs = List<TextParagraph>.generate(
      10000,
      (int index) => TextParagraph(id: 'p$index', text: '前置或正文 $index'),
    );
    final TextChapterContent view = TextChapterContent(
      chapterId: 'chapter-1',
      title: '第一章',
      paragraphs: <TextParagraph>[
        TextParagraph(
          id: fullParagraphs[9000].id,
          text: List<String>.filled(100, '字').join(),
        ),
        fullParagraphs[9001],
      ],
    );
    final List<ReaderPage> pages = paginator.paginate(
      chapter: view,
      width: 300,
      height: 40,
      titleStyle: const TextStyle(fontSize: 22),
      bodyStyle: const TextStyle(fontSize: 16, height: 1.5),
      paragraphSpacing: 8,
      includeChapterTitle: false,
      maximumPages: 1,
      paragraphBaseOffset: 17,
    );
    expect(visited, <String>['p9000']);
    expect(pages.single.blocks.single.startOffset, 17);
    expect(pages.single.blocks.single.paragraphId, 'p9000');
  });
}

ReaderLayoutFingerprint _key({
  String chapterId = 'chapter-1',
  String? contentVersion = 'stable-v1',
  int sessionId = 1,
  Size viewport = const Size(360, 720),
  EdgeInsets safeArea = EdgeInsets.zero,
  double devicePixelRatio = 2,
  double textScale = 1,
  String fontVersion = 'font-v1',
  String layoutSettings = 'default',
  TextDirection textDirection = TextDirection.ltr,
  double paragraphCommentPlaceholder = 0,
  double chapterCommentPlaceholder = 0,
}) {
  return ReaderLayoutFingerprint(
    chapterId: chapterId,
    contentVersion: contentVersion,
    sessionId: sessionId,
    viewport: viewport,
    safeArea: safeArea,
    devicePixelRatio: devicePixelRatio,
    textScale: textScale,
    fontVersion: fontVersion,
    layoutSettings: layoutSettings,
    textDirection: textDirection,
    fontSize: 19,
    fontWeight: 400,
    letterSpacing: .2,
    lineHeight: 1.8,
    paragraphSpacing: 14,
    firstLineIndent: 2,
    horizontalPadding: 24,
    topPadding: 24,
    bottomPadding: 32,
    paragraphCommentPlaceholder: paragraphCommentPlaceholder,
    chapterCommentPlaceholder: chapterCommentPlaceholder,
  );
}
