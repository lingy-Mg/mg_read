part of 'main.dart';

class DemoReaderDataSource
    implements TextReaderDataSource, ReaderChapterStateCapability {
  DemoReaderDataSource() : _chapters = _buildChapters() {
    for (var index = 0; index < _chapters.length; index++) {
      final TextChapterContent chapter = _chapters[index];
      _states[chapter.chapterId] = ReaderChapterState(
        chapterId: chapter.chapterId,
        availability: index == 0
            ? ReaderChapterAvailability.downloaded
            : ReaderChapterAvailability.notDownloaded,
        wordCount: _wordCount(chapter),
      );
    }
  }

  final List<TextChapterContent> _chapters;
  final Map<String, ReaderChapterState> _states =
      <String, ReaderChapterState>{};
  bool _failNextRemoteDownload = false;

  /// Whether the next uncached chapter download will fail once.
  bool get failNextRemoteDownload => _failNextRemoteDownload;

  /// Arms or clears the one-shot host download failure used for manual QA.
  void armNextRemoteFailure(bool value) {
    _failNextRemoteDownload = value;
  }

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    return const ReaderBookInfo(
      id: 'mountain-lamp',
      title: '山灯未眠',
      author: '示例作者',
      description: '关于一座山城、一盏旧灯和一段归途的原创短篇。',
      sourceName: '宿主模拟远程数据源',
      sourceKind: ReaderBookSourceKind.remote,
    );
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 220));
    final int start = int.tryParse(cursor ?? '0') ?? 0;
    final int end = (start + pageSize).clamp(0, _chapters.length);
    return ChapterCatalogPage(
      items: <ReaderChapterInfo>[
        for (var index = start; index < end; index++)
          ReaderChapterInfo(
            id: _chapters[index].chapterId,
            title: _chapters[index].title,
            index: index,
            availability: _states[_chapters[index].chapterId]!.availability,
            wordCount: _states[_chapters[index].chapterId]!.wordCount,
            hasBeenRead: _states[_chapters[index].chapterId]!.hasBeenRead,
          ),
      ],
      total: _chapters.length,
      hasMore: end < _chapters.length,
      nextCursor: end < _chapters.length ? '$end' : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final TextChapterContent chapter = _chapters[index];
    return ReaderChapterInfo(
      id: chapter.chapterId,
      title: chapter.title,
      index: index,
      availability: _states[chapter.chapterId]!.availability,
      wordCount: _states[chapter.chapterId]!.wordCount,
      hasBeenRead: _states[chapter.chapterId]!.hasBeenRead,
    );
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final ReaderChapterState state = _states[chapterId]!;
    if (state.availability != ReaderChapterAvailability.downloaded) {
      _states[chapterId] = ReaderChapterState(
        chapterId: chapterId,
        availability: ReaderChapterAvailability.downloading,
        wordCount: state.wordCount,
        hasBeenRead: state.hasBeenRead,
      );
      await Future<void>.delayed(const Duration(milliseconds: 850));
      if (_failNextRemoteDownload) {
        _failNextRemoteDownload = false;
        _states[chapterId] = ReaderChapterState(
          chapterId: chapterId,
          availability: ReaderChapterAvailability.failed,
          wordCount: state.wordCount,
          hasBeenRead: state.hasBeenRead,
        );
        throw StateError('宿主模拟下载失败；再次进入该章节即可重试。');
      }
      _states[chapterId] = ReaderChapterState(
        chapterId: chapterId,
        availability: ReaderChapterAvailability.downloaded,
        wordCount: state.wordCount,
        hasBeenRead: state.hasBeenRead,
      );
    }
    return _chapters.firstWhere((chapter) => chapter.chapterId == chapterId);
  }

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 140));
    return Map<String, ReaderChapterState>.unmodifiable(
      <String, ReaderChapterState>{
        for (final String chapterId in chapterIds)
          if (_states[chapterId] case final ReaderChapterState state)
            chapterId: state,
      },
    );
  }

  @override
  Future<void> markRead(String bookId, String chapterId) async {
    await Future<void>.delayed(const Duration(milliseconds: 90));
    final ReaderChapterState state = _states[chapterId]!;
    _states[chapterId] = ReaderChapterState(
      chapterId: chapterId,
      availability: state.availability,
      wordCount: state.wordCount,
      hasBeenRead: true,
    );
  }

  static int _wordCount(TextChapterContent chapter) => chapter.paragraphs.fold(
    0,
    (int total, TextParagraph paragraph) => total + paragraph.text.length,
  );

  static List<TextChapterContent> _buildChapters() {
    const List<String> titles = <String>[
      '第一章 雾从河面升起',
      '第二章 山路上的邮车',
      '第三章 修灯的人',
      '第四章 夜市尽头',
      '第五章 风越过旧站台',
      '第六章 灯火归处',
    ];
    const List<String> seeds = <String>[
      '清晨的河面还没有醒，薄雾沿着石阶缓慢爬上来。林砚推开窗，看见对岸那盏多年未熄的山灯，仍在灰白的天色里留着一点温暖。',
      '邮车的发动机在坡道上发出低沉的声响，车窗外的竹林一段段向后退去。司机说，山顶的旧站已经停用了很多年，却总有人往那里寄没有收件人的信。',
      '修灯铺很窄，木架上摆满铜制灯罩和旧玻璃。老人把灯芯放在掌心，说每一盏灯记住的不是黑夜，而是曾经等待它的人。',
      '夜市收摊后只剩雨水反射招牌的微光。林砚顺着青石路走到尽头，第一次听见那封信里反复提到的钟声。',
      '风穿过废弃站台，把墙上的旧时刻表吹得轻轻作响。那些被岁月遮住的名字，在手电光下逐渐显露出来。',
      '天亮之前，山城所有的灯像约好一样依次熄灭，只有河对岸的新灯亮了起来。林砚终于明白，归途并不是回到旧地，而是有人为你留下方向。',
    ];
    return List<TextChapterContent>.generate(titles.length, (int chapterIndex) {
      return TextChapterContent(
        chapterId: 'chapter-${chapterIndex + 1}',
        title: titles[chapterIndex],
        contentVersion: '1',
        chapterUrl:
            'https://example.com/mountain-lamp/chapter-${chapterIndex + 1}',
        paragraphs: List<TextParagraph>.generate(14, (int paragraphIndex) {
          final String variation = paragraphIndex.isEven
              ? '风从屋檐下掠过，带来潮湿泥土和松针的气息。'
              : '他停下脚步，把沿途细小的线索重新排在心里。';
          return TextParagraph(
            id: 'c${chapterIndex + 1}-p${paragraphIndex + 1}',
            text: '${seeds[chapterIndex]}$variation这一次，他决定继续向前。',
          );
        }),
      );
    });
  }
}

class MemoryReaderStateStore implements TextReaderStateStore {
  ReaderProgress? _progress;
  TextReaderPreferences? _preferences;
  final List<ReaderBookmark> _bookmarks = <ReaderBookmark>[];

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {
    _bookmarks.add(bookmark);
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async {
    return List<ReaderBookmark>.unmodifiable(
      _bookmarks.where((bookmark) => bookmark.bookId == bookId),
    );
  }

  @override
  Future<TextReaderPreferences?> loadPreferences() async => _preferences;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => _progress;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {
    _bookmarks.removeWhere(
      (bookmark) => bookmark.bookId == bookId && bookmark.id == bookmarkId,
    );
  }

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {
    _progress = progress;
  }
}

/// A host-owned font repository backed by the package's bundled MiSans asset.
class DemoReaderFontRepository implements ReaderFontRepository {
  static const String _fontAsset =
      'packages/novel_reader_ui/assets/fonts/MiSansVF.ttf';
  static const String _previewAsset =
      'packages/novel_reader_ui/assets/backgrounds/ivory_cotton_paper.webp';
  static final ReaderFontDescriptor descriptor = ReaderFontDescriptor(
    id: 'demo-misans-variable',
    displayName: '示例云端 MiSans',
    familyName: 'MiSans Variable',
    fontUrl: 'https://example.com/fonts/misans-variable.ttf',
    previewImageUrl: 'https://example.com/fonts/misans-preview.webp',
    version: '1.0.0-demo',
    license: '示例演示资产；随插件仓库提供',
    fileSizeBytes: 20093424,
    weights: <int>[400],
  );

  Uint8List? _fontBytes;
  Uint8List? _previewBytes;

  @override
  Future<List<ReaderFontDescriptor>> loadCatalog() async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return <ReaderFontDescriptor>[descriptor];
  }

  @override
  Future<void> install(ReaderFontDescriptor descriptor) async {
    await Future<void>.delayed(const Duration(milliseconds: 520));
    final ByteData font = await rootBundle.load(_fontAsset);
    final ByteData preview = await rootBundle.load(_previewAsset);
    _fontBytes = font.buffer.asUint8List(
      font.offsetInBytes,
      font.lengthInBytes,
    );
    _previewBytes = preview.buffer.asUint8List(
      preview.offsetInBytes,
      preview.lengthInBytes,
    );
  }

  @override
  Future<Uint8List?> loadCachedFontBytes(
    String fontId, {
    String? version,
    int? weight,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 70));
    if (fontId != descriptor.id ||
        version != descriptor.version ||
        weight != 400) {
      return null;
    }
    final Uint8List? bytes = _fontBytes;
    return bytes;
  }

  @override
  Future<Uint8List?> loadCachedPreviewBytes(
    String fontId, {
    String? version,
  }) async {
    if (fontId != descriptor.id || version != descriptor.version) return null;
    final Uint8List? bytes = _previewBytes;
    return bytes;
  }

  @override
  Future<void> remove(String fontId) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (fontId == descriptor.id) {
      _fontBytes = null;
      _previewBytes = null;
    }
  }
}

class DemoComicDataSource implements ComicReaderDataSource {
  static const List<String> _assetPaths = <String>[
    'assets/comic/mountain_lantern_page.png',
    'packages/novel_reader_ui/assets/backgrounds/mist_mountains.webp',
    'packages/novel_reader_ui/assets/backgrounds/ivory_cotton_paper.webp',
    'packages/novel_reader_ui/assets/backgrounds/warm_fiber_paper.webp',
  ];
  static const List<int> _assetWidths = <int>[1024, 1152, 768, 768];
  static const List<int> _assetHeights = <int>[1536, 768, 768, 768];
  static const List<String> _assetContentTypes = <String>[
    'image/png',
    'image/webp',
    'image/webp',
    'image/webp',
  ];
  static const List<String> _chapterTitles = <String>[
    '第一章 雾岭来信',
    '第二章 云间驿站',
    '第三章 晨光回程',
  ];

  bool _failNextImageLoad = false;

  bool get failNextImageLoad => _failNextImageLoad;

  void armNextImageFailure(bool value) {
    _failNextImageLoad = value;
  }

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async {
    await Future<void>.delayed(const Duration(milliseconds: 240));
    return const ComicBookInfo(
      id: 'cloud-postcards',
      title: '云上明信片',
      author: '示例绘本小组',
      description: '使用 ImageGen 原创竖向漫画页与仓库原创背景组成的渐进加载演示。',
      sourceName: '宿主内存图片仓库',
      sourceKind: ReaderBookSourceKind.local,
    );
  }

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final int start = int.tryParse(cursor ?? '0') ?? 0;
    final int end = (start + pageSize).clamp(0, _chapterTitles.length);
    return ComicChapterCatalogPage(
      items: <ComicChapterInfo>[
        for (var index = start; index < end; index++) _chapterInfo(index),
      ],
      total: _chapterTitles.length,
      hasMore: end < _chapterTitles.length,
      nextCursor: end < _chapterTitles.length ? '$end' : null,
    );
  }

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 90));
    return _chapterInfo(index);
  }

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    final int chapterIndex = int.parse(chapterId.split('-').last) - 1;
    return ComicChapterContent(
      chapterId: chapterId,
      title: _chapterTitles[chapterIndex],
      contentVersion: 'demo-2',
      images: List<ComicImageInfo>.generate(5, (int imageIndex) {
        final int assetIndex = (chapterIndex + imageIndex) % _assetPaths.length;
        return ComicImageInfo(
          id: 'comic-${chapterIndex + 1}-${imageIndex + 1}-$assetIndex',
          index: imageIndex,
          width: _assetWidths[assetIndex],
          height: _assetHeights[assetIndex],
          contentType: _assetContentTypes[assetIndex],
          contentVersion: 'asset-$assetIndex-v2',
        );
      }),
    );
  }

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    final int imageIndex = int.parse(imageId.split('-')[2]);
    await Future<void>.delayed(Duration(milliseconds: 380 + imageIndex * 170));
    if (_failNextImageLoad) {
      _failNextImageLoad = false;
      throw StateError('宿主模拟漫画图片加载失败，请点击图片区域重试。');
    }
    final int assetIndex = int.parse(imageId.split('-').last);
    final ByteData data = await rootBundle.load(_assetPaths[assetIndex]);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static ComicChapterInfo _chapterInfo(int index) => ComicChapterInfo(
    id: 'comic-chapter-${index + 1}',
    title: _chapterTitles[index],
    index: index,
    availability: ReaderChapterAvailability.downloaded,
    imageCount: 5,
  );
}

class MemoryComicReaderStateStore implements ComicReaderStateStore {
  ComicReaderProgress? _progress;
  ComicReaderPreferences? _preferences;
  final List<ComicReaderBookmark> _bookmarks = <ComicReaderBookmark>[];

  @override
  Future<void> addBookmark(ComicReaderBookmark bookmark) async {
    _bookmarks.add(bookmark);
  }

  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async =>
      List<ComicReaderBookmark>.unmodifiable(
        _bookmarks.where((ComicReaderBookmark value) => value.bookId == bookId),
      );

  @override
  Future<ComicReaderPreferences?> loadPreferences() async => _preferences;

  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async => _progress;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {
    _bookmarks.removeWhere(
      (ComicReaderBookmark value) =>
          value.bookId == bookId && value.id == bookmarkId,
    );
  }

  @override
  Future<void> savePreferences(ComicReaderPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> saveProgress(String bookId, ComicReaderProgress progress) async {
    _progress = progress;
  }
}

class DemoComicReaderObserver extends ComicReaderObserver {
  const DemoComicReaderObserver({
    required this.onExit,
    required this.onFailureMessage,
  });

  final VoidCallback onExit;
  final ValueChanged<String> onFailureMessage;

  @override
  void onExitRequested(ComicReaderProgress? progress) => onExit();

  @override
  void onFailure(ReaderFailure failure) => onFailureMessage(failure.message);
}
