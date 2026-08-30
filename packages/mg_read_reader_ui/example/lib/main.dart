/// 阅读器示例宿主。
///
/// 职责：
/// - 展示文本和漫画阅读器的宿主接入方式。
/// - 提供仅供演示与手工验证使用的内存数据源和状态仓库。
///
/// 注意：
/// - 示例 fake 不得进入生产公开 API。
/// - 数据加载和故障注入必须保持在演示宿主内，不影响阅读器包的网络/持久化边界。
///
library;

import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

part 'example_reader_fixtures.dart';

void main() => runApp(const ReaderExampleApp());

class ReaderExampleApp extends StatefulWidget {
  const ReaderExampleApp({super.key});

  @override
  State<ReaderExampleApp> createState() => _ReaderExampleAppState();
}

class _ReaderExampleAppState extends State<ReaderExampleApp> {
  bool _showGlobalPerformanceOverlay = false;
  bool _readerOpen = false;

  void _togglePerformanceOverlay() {
    setState(() {
      _showGlobalPerformanceOverlay = !_showGlobalPerformanceOverlay;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Novel Reader UI Example',
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _showGlobalPerformanceOverlay,
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: mediaQuery.textScaler.clamp(maxScaleFactor: 1.3),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB7593C),
          surface: const Color(0xFFFFFCF7),
        ),
        fontFamily: 'packages/novel_reader_ui/MiSans',
        scaffoldBackgroundColor: const Color(0xFFF4F1EA),
        useMaterial3: true,
      ),
      home: ReaderExampleHome(
        showGlobalPerformanceOverlay: _showGlobalPerformanceOverlay,
        onTogglePerformanceOverlay: _togglePerformanceOverlay,
        onReadingChanged: (bool value) {
          if (_readerOpen == value) return;
          setState(() => _readerOpen = value);
        },
      ),
    );
  }
}

class _FrameRateOverlay extends StatefulWidget {
  const _FrameRateOverlay({
    required this.showGlobalPerformanceOverlay,
    required this.onToggle,
  });

  final bool showGlobalPerformanceOverlay;
  final VoidCallback onToggle;

  @override
  State<_FrameRateOverlay> createState() => _FrameRateOverlayState();
}

class _FrameRateOverlayState extends State<_FrameRateOverlay> {
  static const Duration _refreshInterval = Duration(seconds: 1);

  int _framesSinceLastRefresh = 0;
  int _framesPerSecond = 0;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_recordFrameTimings);
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (!mounted) return;
      setState(() {
        _framesPerSecond = _framesSinceLastRefresh;
        _framesSinceLastRefresh = 0;
      });
    });
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    _framesSinceLastRefresh += timings.length;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeTimingsCallback(_recordFrameTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isGlobal = widget.showGlobalPerformanceOverlay;
    return Positioned(
      top: 8,
      right: 8,
      child: SafeArea(
        child: Tooltip(
          message: isGlobal ? '切换为小窗性能监视' : '切换为全局性能监视',
          child: Semantics(
            button: true,
            label: isGlobal ? '全局性能监视，点击切换为小窗' : '小窗性能监视，点击切换为全局',
            child: Material(
              color: const Color(0xA6262522),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: widget.onToggle,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Center(
                      child: Text(
                        '$_framesPerSecond FPS',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderExampleHome extends StatefulWidget {
  const ReaderExampleHome({
    required this.showGlobalPerformanceOverlay,
    required this.onTogglePerformanceOverlay,
    required this.onReadingChanged,
    super.key,
  });

  final bool showGlobalPerformanceOverlay;
  final VoidCallback onTogglePerformanceOverlay;
  final ValueChanged<bool> onReadingChanged;

  @override
  State<ReaderExampleHome> createState() => _ReaderExampleHomeState();
}

class _ReaderExampleHomeState extends State<ReaderExampleHome> {
  final DemoReaderDataSource _dataSource = DemoReaderDataSource();
  final MemoryReaderStateStore _stateStore = MemoryReaderStateStore();
  final DemoReaderCommentFeed _commentFeed = DemoReaderCommentFeed();
  final DemoReaderFontRepository _fontRepository = DemoReaderFontRepository();
  final DemoComicDataSource _comicDataSource = DemoComicDataSource();
  final MemoryComicReaderStateStore _comicStateStore =
      MemoryComicReaderStateStore();
  _DemoSurface _surface = _DemoSurface.home;

  @override
  Widget build(BuildContext context) {
    if (_surface == _DemoSurface.text) {
      return Scaffold(
        body: TextReaderView(
          bookId: 'mountain-lamp',
          dataSource: _dataSource,
          stateStore: _stateStore,
          extensions: ReaderExtensions(
            commentFeed: _commentFeed,
            chapterStateCapability: _dataSource,
            fontRepository: _fontRepository,
          ),
          observer: DemoReaderObserver(
            onExit: _leaveReader,
            onFailureMessage: _showFailure,
          ),
        ),
      );
    }
    if (_surface == _DemoSurface.comic) {
      return Scaffold(
        body: ComicReaderView(
          bookId: 'cloud-postcards',
          dataSource: _comicDataSource,
          stateStore: _comicStateStore,
          commentFeed: _commentFeed,
          observer: DemoComicReaderObserver(
            onExit: _leaveReader,
            onFailureMessage: _showFailure,
          ),
        ),
      );
    }

    return Stack(
      children: <Widget>[
        Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text(
                        '阅读器人工验收入口',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '文本与漫画均使用宿主模拟异步能力',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF777168),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Material(
                        color: const Color(0xFFFFFCF7),
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: Color(0x142E2A25)),
                        ),
                        child: Column(
                          children: <Widget>[
                            _demoSwitch(
                              title: '下一次远程章节下载失败',
                              subtitle: '文本目录选择未下载章节后失败一次，再次点击可成功',
                              value: _dataSource.failNextRemoteDownload,
                              onChanged: (bool value) => setState(
                                () => _dataSource.armNextRemoteFailure(value),
                              ),
                            ),
                            const Divider(height: 1, indent: 16, endIndent: 16),
                            _demoSwitch(
                              title: '下一次评论列表加载失败',
                              subtitle: '文本评论列表失败一次，可检查局部重试',
                              value: _commentFeed.failNextCommentsLoad,
                              onChanged: (bool value) => setState(
                                () =>
                                    _commentFeed.armNextCommentsFailure(value),
                              ),
                            ),
                            const Divider(height: 1, indent: 16, endIndent: 16),
                            _demoSwitch(
                              title: '下一张漫画图片加载失败',
                              subtitle: '进入漫画后局部失败一次，可在图片位置重试',
                              value: _comicDataSource.failNextImageLoad,
                              onChanged: (bool value) => setState(
                                () =>
                                    _comicDataSource.armNextImageFailure(value),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _entryCard(
                        icon: Icons.menu_book_rounded,
                        title: '文本小说 · 山灯未眠',
                        subtitle: '远程章节状态、只读评论、外部字体与完整阅读设置',
                        onTap: () => _enterReader(_DemoSurface.text),
                      ),
                      const SizedBox(height: 10),
                      _entryCard(
                        icon: Icons.photo_library_outlined,
                        title: '纵向漫画 · 云上明信片',
                        subtitle: '三章连续阅读、逐图慢加载、进度、设置与书签',
                        onTap: () => _enterReader(_DemoSurface.comic),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        _FrameRateOverlay(
          showGlobalPerformanceOverlay: widget.showGlobalPerformanceOverlay,
          onToggle: widget.onTogglePerformanceOverlay,
        ),
      ],
    );
  }

  void _enterReader(_DemoSurface surface) {
    setState(() => _surface = surface);
    widget.onReadingChanged(true);
  }

  void _leaveReader() {
    if (!mounted) return;
    setState(() => _surface = _DemoSurface.home);
    widget.onReadingChanged(false);
  }

  void _showFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _entryCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFFFFFCF7),
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0x14385249),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: const Color(0xFF385249)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF777168),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _demoSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: Color(0xFF777168)),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

enum _DemoSurface { home, text, comic }

/// A deterministic, in-memory demonstration of the optional read-only feed.
class DemoReaderCommentFeed implements ReaderCommentFeed {
  DemoReaderCommentFeed() : _comments = List.unmodifiable(_buildComments());

  /// Stable paragraph target intentionally backed by zero comments.
  static const ReaderCommentTarget zeroCommentTarget =
      ReaderCommentTarget.paragraph('mountain-lamp', 'chapter-1', 'c1-p2');

  final List<ReaderComment> _comments;
  bool _failNextCommentsLoad = false;

  /// Whether the next full comment-list request will fail once.
  bool get failNextCommentsLoad => _failNextCommentsLoad;

  /// Arms or clears the one-shot comment-list failure used for manual retry QA.
  void armNextCommentsFailure(bool value) {
    _failNextCommentsLoad = value;
  }

  @override
  Future<Map<ReaderCommentTarget, ReaderCommentSummary>> loadSummaries(
    List<ReaderCommentTarget> targets, {
    int previewLimit = 3,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final Map<ReaderCommentTarget, ReaderCommentSummary> summaries =
        <ReaderCommentTarget, ReaderCommentSummary>{};
    for (final ReaderCommentTarget target in targets) {
      final List<ReaderComment> comments = _commentsFor(
        target,
        ReaderCommentSort.hot,
      );
      final int limit = previewLimit.clamp(0, comments.length);
      summaries[target] = ReaderCommentSummary(
        target: target,
        total: comments.length,
        topComments: comments.take(limit).toList(growable: false),
      );
    }
    return Map.unmodifiable(summaries);
  }

  @override
  Future<ReaderCommentPage> loadComments(
    ReaderCommentTarget target, {
    ReaderCommentSort sort = ReaderCommentSort.hot,
    String? cursor,
    int pageSize = 20,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 240));
    if (_failNextCommentsLoad) {
      _failNextCommentsLoad = false;
      throw StateError('示例评论加载失败，请点击重试。');
    }
    final List<ReaderComment> comments = _commentsFor(target, sort);
    final int start = (int.tryParse(cursor ?? '0') ?? 0).clamp(
      0,
      comments.length,
    );
    final int safePageSize = pageSize.clamp(1, 100);
    final int end = (start + safePageSize).clamp(0, comments.length);
    return ReaderCommentPage(
      items: comments.sublist(start, end),
      total: comments.length,
      hasMore: end < comments.length,
      nextCursor: end < comments.length ? '$end' : null,
    );
  }

  List<ReaderComment> _commentsFor(
    ReaderCommentTarget target,
    ReaderCommentSort sort,
  ) {
    final List<ReaderComment> result = _comments
        .where((ReaderComment comment) => comment.target == target)
        .toList(growable: false);
    result.sort((ReaderComment a, ReaderComment b) {
      if (sort == ReaderCommentSort.newest) {
        return b.createdAt.compareTo(a.createdAt);
      }
      final int byLikes = b.likeCount.compareTo(a.likeCount);
      return byLikes != 0 ? byLikes : b.createdAt.compareTo(a.createdAt);
    });
    return result;
  }

  static List<ReaderComment> _buildComments() {
    const ReaderCommentTarget book = ReaderCommentTarget.book('mountain-lamp');
    const ReaderCommentTarget chapter = ReaderCommentTarget.chapter(
      'mountain-lamp',
      'chapter-1',
    );
    const ReaderCommentTarget paragraph = ReaderCommentTarget.paragraph(
      'mountain-lamp',
      'chapter-1',
      'c1-p1',
    );
    const ReaderCommentTarget comicImage = ReaderCommentTarget.comicImage(
      'cloud-postcards',
      'comic-chapter-1',
      'comic-1-1-0',
    );
    final List<ReaderComment> comments = <ReaderComment>[
      ReaderComment(
        id: 'book-comment-1',
        target: book,
        authorName: '河岸读者',
        content: '山城的雾与灯彼此照应，读完整篇仍能想起河面的颜色。',
        createdAt: DateTime.utc(2026, 7, 8, 9, 30),
        likeCount: 28,
      ),
      ReaderComment(
        id: 'book-comment-2',
        target: book,
        authorName: '晚风邮差',
        content: '故事很短，却把等待与归途写得安静而完整。',
        createdAt: DateTime.utc(2026, 7, 10, 18, 5),
        likeCount: 17,
      ),
      ReaderComment(
        id: 'book-comment-3',
        target: book,
        authorName: '旧站台',
        content: '最喜欢最后一章，新灯亮起时前面的线索都有了落点。',
        createdAt: DateTime.utc(2026, 7, 12, 6, 45),
        likeCount: 21,
      ),
      ReaderComment(
        id: 'chapter-comment-1',
        target: chapter,
        authorName: '青石巷',
        content: '开篇的节奏很稳，第一盏山灯出现得恰到好处。',
        createdAt: DateTime.utc(2026, 7, 9, 11, 20),
        likeCount: 12,
      ),
      ReaderComment(
        id: 'chapter-comment-2',
        target: chapter,
        authorName: '松针气息',
        content: '薄雾沿石阶上来的画面，让山城一下子有了空间感。',
        createdAt: DateTime.utc(2026, 7, 11, 14, 10),
        likeCount: 19,
      ),
      ReaderComment(
        id: 'chapter-comment-3',
        target: chapter,
        authorName: '未眠灯火',
        content: '这一章留下了足够悬念，也没有刻意隐藏信息。',
        createdAt: DateTime.utc(2026, 7, 13, 20, 15),
        likeCount: 8,
      ),
      ReaderComment(
        id: 'paragraph-comment-1',
        target: paragraph,
        authorName: '晨雾',
        content: '灰白天色里的一点暖光，是很克制的开场。',
        createdAt: DateTime.utc(2026, 7, 10, 7, 40),
        likeCount: 15,
      ),
      ReaderComment(
        id: 'paragraph-comment-2',
        target: paragraph,
        authorName: '对岸人家',
        content: '“多年未熄”四个字已经暗示了灯背后的故事。',
        createdAt: DateTime.utc(2026, 7, 12, 12, 25),
        likeCount: 23,
      ),
      ReaderComment(
        id: 'paragraph-comment-3',
        target: paragraph,
        authorName: '归途有光',
        content: '第一次读到这里时，就想知道是谁一直守着那盏灯。',
        createdAt: DateTime.utc(2026, 7, 14, 16, 50),
        likeCount: 9,
      ),
      ReaderComment(
        id: 'comic-image-comment-1',
        target: comicImage,
        authorName: '云桥旅人',
        content: '第一格远山和灯笼的冷暖对比很适合纵向开篇。',
        createdAt: DateTime.utc(2026, 8, 2, 19, 20),
        likeCount: 14,
      ),
      ReaderComment(
        id: 'comic-image-comment-2',
        target: comicImage,
        authorName: '松下听泉',
        content: '四格连续场景让进山、过桥、见村和继续赶路的节奏很清楚。',
        createdAt: DateTime.utc(2026, 8, 4, 8, 35),
        likeCount: 22,
      ),
    ];
    const List<String> names = <String>[
      '山城来信',
      '河灯微光',
      '竹林听风',
      '石阶行人',
      '清晨邮车',
      '旧钟回声',
    ];
    const List<String> observations = <String>[
      '能看到前后章节埋下的细节彼此呼应。',
      '最打动我的是人物没有说出口的那份等待。',
      '山路、河面和旧站台组成了很清晰的空间。',
      '文字不急着解释，让灯火自己带出答案。',
      '短句与长句交替，读起来像雾慢慢散开。',
      '结尾回望开篇时，归途的含义已经不同了。',
    ];
    for (var index = 0; index < 18; index++) {
      comments.add(
        ReaderComment(
          id: 'book-comment-${index + 4}',
          target: book,
          authorName: names[index % names.length],
          content:
              '第${index + 2}次重读时，${observations[index % observations.length]}',
          createdAt: DateTime.utc(2026, 6, index + 1, 8 + index % 10, 10),
          likeCount: (index * 7 + 5) % 32,
        ),
      );
    }
    return comments;
  }
}

class DemoReaderObserver extends ReaderObserver {
  const DemoReaderObserver({
    required this.onExit,
    required this.onFailureMessage,
  });

  final VoidCallback onExit;
  final ValueChanged<String> onFailureMessage;

  @override
  void onExitRequested(ReaderProgress? progress) => onExit();

  @override
  void onFailure(ReaderFailure failure) => onFailureMessage(failure.message);
}
