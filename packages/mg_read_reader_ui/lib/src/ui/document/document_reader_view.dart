/// Reflowable, continuous document reader. The host owns archive parsing and IO;
/// this view owns only semantic navigation, rendering, and reader preferences.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../api/contracts.dart';
import '../../api/document_contracts.dart';
import '../../api/document_models.dart';
import '../../api/models.dart';
import '../../platform/screen_awake_coordinator.dart';

part 'document_reader_rendering.dart';
part 'document_reader_controls.dart';

/// One entry in the host-extracted EPUB navigation hierarchy.
@immutable
class ReaderDocumentNavigationEntry {
  const ReaderDocumentNavigationEntry({
    required this.title,
    required this.chapterId,
    this.anchor,
    this.depth = 0,
  });
  final String title;
  final String chapterId;
  final String? anchor;
  final int depth;
}

/// EPUB reader view for host-parsed, reflowable document chapters.
class DocumentReaderView extends StatefulWidget {
  const DocumentReaderView({
    super.key,
    required this.dataSource,
    required this.stateStore,
    required this.bookId,
    this.onBackRequested,
    this.navigationEntries = const [],
    this.onFirstContentPresented,
    this.observer,
  });

  final ReaderDocumentDataSource dataSource;
  final TextReaderStateStore stateStore;
  final String bookId;
  final VoidCallback? onBackRequested;
  final List<ReaderDocumentNavigationEntry> navigationEntries;
  final ValueChanged<ReaderFirstContentPresentation>? onFirstContentPresented;
  final ReaderObserver? observer;

  @override
  State<DocumentReaderView> createState() => _DocumentReaderViewState();
}

class _DocumentReaderViewState extends State<DocumentReaderView>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _blockKeys = {};
  final Map<String, Future<Uint8List?>> _resources = {};
  final Map<String, Map<int, TapGestureRecognizer>> _linkRecognizers = {};
  final Map<String, int> _resourceRetryCounts = {};
  final Set<String> _reportedResourceErrors = {};
  final Object _awakeHolder = Object();
  ReaderBookInfo? _book;
  List<ReaderChapterInfo> _catalog = [];
  ReaderDocumentChapter? _chapter;
  ReaderProgress? _progress;
  List<ReaderBookmark> _bookmarks = [];
  TextReaderPreferences _preferences = TextReaderPreferences.defaults;
  bool _loading = true;
  Object? _failure;
  bool _firstPresented = false;
  bool _disposed = false;
  bool _sessionStarted = false;
  bool _restoringAnchor = false;
  bool _useBookStyles = false;
  int _generation = 0;
  int _anchorRestoreGeneration = 0;
  int _chapterIndex = 0;
  int? _failedTargetIndex;
  Size? _lastBodySize;
  Timer? _progressTimer;
  final List<ReaderProgress> _linkReturnStack = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    unawaited(_start());
  }

  @override
  void didUpdateWidget(covariant DocumentReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.stateStore != widget.stateStore) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    final int generation = ++_generation;
    _releaseChapterRenderState();
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final results = await Future.wait<Object?>([
        widget.dataSource.loadBookInfo(widget.bookId),
        widget.stateStore.loadProgress(widget.bookId),
        widget.stateStore.loadPreferences(),
        widget.stateStore.loadBookmarks(widget.bookId),
        widget.dataSource.loadChapterCatalog(widget.bookId),
      ]);
      final ReaderBookInfo book = results[0] as ReaderBookInfo;
      final ReaderProgress? saved = results[1] as ReaderProgress?;
      final ChapterCatalogPage page = results[4] as ChapterCatalogPage;
      final entries = [...page.items];
      String? cursor = page.nextCursor;
      var hasMore = page.hasMore;
      while (hasMore &&
          cursor != null &&
          entries.length < page.total &&
          generation == _generation) {
        final next = await widget.dataSource.loadChapterCatalog(
          widget.bookId,
          cursor: cursor,
        );
        entries.addAll(next.items);
        hasMore = next.hasMore;
        cursor = next.nextCursor;
      }
      if (entries.isEmpty) {
        throw StateError('This document has no readable chapters.');
      }
      final index = saved == null
          ? 0
          : entries
                .indexWhere((c) => c.id == saved.chapterId)
                .clamp(0, entries.length - 1);
      final chapterInfo = await widget.dataSource.loadChapterAtIndex(
        widget.bookId,
        index,
      );
      final chapter = await widget.dataSource.loadChapter(
        widget.bookId,
        chapterInfo.id,
      );
      if (generation != _generation || _disposed) return;
      setState(() {
        _book = book;
        _catalog = List.unmodifiable(entries);
        _chapterIndex = index;
        _chapter = chapter;
        _reportedResourceErrors.clear();
        _progress =
            saved ??
            ReaderProgress(
              chapterId: chapter.chapterId,
              paragraphId: chapter.blocks.firstOrNull?.id ?? '',
              chapterIndex: index,
              bookFraction: _catalog.length <= 1
                  ? 0
                  : index / (_catalog.length - 1),
            );
        _preferences =
            (results[2] as TextReaderPreferences? ??
                    TextReaderPreferences.defaults)
                .normalized();
        _bookmarks = List.of(results[3] as List<ReaderBookmark>);
        _loading = false;
        _failure = null;
        _failedTargetIndex = null;
      });
      unawaited(_syncAwake());
      if (!_sessionStarted) {
        _sessionStarted = true;
        _notifyObserver(() => widget.observer?.onSessionStarted(widget.bookId));
      }
      _notifyObserver(() => widget.observer?.onChapterChanged(chapterInfo));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_presentInitialContent(saved, chapter, generation));
      });
    } catch (error) {
      if (generation != _generation || _disposed) return;
      setState(() {
        _loading = false;
        _failure = error;
      });
      _reportFailure(error, 'document_start');
    }
  }

  Future<void> _loadChapter(int index, {String? anchor}) async {
    if (index < 0 || index >= _catalog.length) return;
    final int generation = ++_generation;
    final oldChapter = _chapter;
    setState(() {
      _failure = null;
      if (oldChapter == null) _loading = true;
    });
    try {
      final info = await widget.dataSource.loadChapterAtIndex(
        widget.bookId,
        index,
      );
      final chapter = await widget.dataSource.loadChapter(
        widget.bookId,
        info.id,
      );
      if (generation != _generation || _disposed) return;
      _releaseChapterRenderState();
      setState(() {
        _chapter = chapter;
        _chapterIndex = index;
        _loading = false;
        _failure = null;
        _failedTargetIndex = null;
        _reportedResourceErrors.clear();
      });
      _notifyObserver(() => widget.observer?.onChapterChanged(info));
      _commitProgress(
        ReaderProgress(
          chapterId: chapter.chapterId,
          paragraphId: chapter.blocks.firstOrNull?.id ?? '',
          chapterIndex: index,
          bookFraction: _catalog.length <= 1
              ? 0
              : index / (_catalog.length - 1),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _generation) return;
      if (anchor != null && anchor.isNotEmpty) {
        final restored = await _jumpTo(anchor, 0);
        if (!restored) _scroll.jumpTo(0);
      } else {
        _scroll.jumpTo(0);
      }
    } catch (error) {
      if (generation != _generation || _disposed) return;
      setState(() {
        _loading = oldChapter == null;
        _failure = error;
        _failedTargetIndex = index;
      });
      _reportFailure(error, 'document_chapter');
    }
  }

  void _notifyFirstContent() {
    if (_firstPresented || _chapter == null || _chapter!.blocks.isEmpty) return;
    _firstPresented = true;
    final presentation = ReaderFirstContentPresentation(
      anchor: _progress,
      paginationPreparation: ReaderPaginationPreparation.firstPage,
      layoutDuration: Duration.zero,
    );
    if (widget.observer case final ReaderObserver observer) {
      _notifyObserver(() => observer.onFirstContentPresented(presentation));
    } else {
      widget.onFirstContentPresented?.call(presentation);
    }
  }

  Future<void> _presentInitialContent(
    ReaderProgress? saved,
    ReaderDocumentChapter chapter,
    int generation,
  ) async {
    if (!mounted || generation != _generation) return;
    if (saved != null && saved.chapterId == chapter.chapterId) {
      final restored = await _jumpTo(
        saved.paragraphId,
        saved.characterOffset,
        persist: false,
      );
      if (!restored && mounted && generation == _generation) {
        _reportFailure(
          StateError('Saved document anchor is unavailable.'),
          'document_resume',
        );
        _scroll.jumpTo(0);
      }
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation) return;
    _notifyFirstContent();
  }

  String _blockText(ReaderDocumentBlock block) => block.plainText.isNotEmpty
      ? block.plainText
      : block.children.map(_blockText).join(' ');

  void _onScroll() {
    if (_restoringAnchor) return;
    final progress = _captureVisibleProgress();
    if (progress != null) _commitProgress(progress);
  }

  ReaderProgress? _captureVisibleProgress() {
    final chapter = _chapter;
    if (!_scroll.hasClients || chapter == null) return null;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final viewportOrigin = viewport.localToGlobal(Offset.zero);
    final targetY =
        viewportOrigin.dy + (viewport.size.height * .08).clamp(24, 72);
    for (final block in _flattenBlocks(chapter.blocks)) {
      final context = _blockKeys[block.id]?.currentContext;
      final object = context?.findRenderObject();
      if (object is! RenderBox || !object.hasSize) continue;
      final origin = object.localToGlobal(Offset.zero);
      if (origin.dy + object.size.height <= targetY) continue;
      final editable = _findEditable(object);
      if (editable == null) continue;
      final localPoint = editable.globalToLocal(
        Offset(viewportOrigin.dx + 12, targetY),
      );
      final offset = editable
          .getPositionForPoint(localPoint)
          .offset
          .clamp(0, _blockText(block).length);
      return ReaderProgress(
        chapterId: chapter.chapterId,
        paragraphId: block.id,
        characterOffset: offset,
        chapterIndex: _chapterIndex,
        chapterFraction: _scroll.position.maxScrollExtent == 0
            ? 0
            : (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0, 1),
        bookFraction: _catalog.length <= 1
            ? 0
            : _chapterIndex / (_catalog.length - 1),
      );
    }
    return null;
  }

  Iterable<ReaderDocumentBlock> _flattenBlocks(
    Iterable<ReaderDocumentBlock> blocks,
  ) sync* {
    for (final block in blocks) {
      yield block;
      yield* _flattenBlocks(block.children);
    }
  }

  RenderEditable? _findEditable(RenderObject object) {
    if (object is RenderEditable) return object;
    RenderEditable? found;
    object.visitChildren((child) {
      found ??= _findEditable(child);
    });
    return found;
  }

  void _notifyObserver(FutureOr<void>? Function() callback) {
    try {
      final result = callback();
      if (result is Future<void>) unawaited(result.catchError((Object _) {}));
    } on Object {
      // Observer diagnostics cannot take down document reading.
    }
  }

  void _reportFailure(
    Object error,
    String location, [
    ReaderFailureKind kind = ReaderFailureKind.data,
  ]) {
    _notifyObserver(
      () => widget.observer?.onFailure(
        ReaderFailure(
          kind,
          'Unable to read the document.',
          code: 'document_read_failed',
          location: location,
          cause: error,
        ),
      ),
    );
  }

  void _commitProgress(ReaderProgress progress) {
    _progress = progress;
    _progressTimer?.cancel();
    _progressTimer = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) {
        unawaited(
          widget.stateStore.saveProgress(widget.bookId, progress).catchError((
            Object error,
          ) {
            _reportFailure(
              error,
              'document_progress',
              ReaderFailureKind.persistence,
            );
          }),
        );
      }
    });
  }

  Future<bool> _jumpTo(
    String id,
    int offset, {
    bool persist = true,
    bool animate = true,
  }) async {
    final key = _blockKeys[id];
    final ctx = key?.currentContext;
    final chapter = _chapter;
    if (ctx == null || chapter == null) return false;
    final block = _flattenBlocks(chapter.blocks)
        .where(
          (block) =>
              block.id == id ||
              block.anchor == id ||
              block.anchors.contains(id),
        )
        .firstOrNull;
    if (block == null) return false;
    _restoringAnchor = true;
    _progressTimer?.cancel();
    try {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.08,
        duration: animate ? const Duration(milliseconds: 120) : Duration.zero,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !ctx.mounted) return false;
      final RenderObject? renderObject = ctx.findRenderObject();
      final editable = renderObject == null
          ? null
          : _findEditable(renderObject);
      if (editable != null && _scroll.hasClients) {
        final textLength = _blockText(block).length;
        final caret = editable.getLocalRectForCaret(
          TextPosition(offset: offset.clamp(0, textLength)),
        );
        final caretTop = editable.localToGlobal(caret.topLeft).dy;
        final viewportObject = _viewportKey.currentContext?.findRenderObject();
        if (viewportObject is RenderBox && viewportObject.hasSize) {
          final viewportTop = viewportObject.localToGlobal(Offset.zero).dy;
          final targetTop =
              viewportTop + (viewportObject.size.height * .08).clamp(24, 72);
          _scroll.jumpTo(
            (_scroll.offset + caretTop - targetTop).clamp(
              _scroll.position.minScrollExtent,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      }
      await WidgetsBinding.instance.endOfFrame;
      final progress = ReaderProgress(
        chapterId: chapter.chapterId,
        paragraphId: block.id,
        characterOffset: offset.clamp(0, _blockText(block).length),
        chapterIndex: _chapterIndex,
        chapterFraction:
            _scroll.hasClients && _scroll.position.maxScrollExtent > 0
            ? (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0, 1)
            : 0,
        bookFraction: _catalog.length <= 1
            ? 0
            : _chapterIndex / (_catalog.length - 1),
      );
      _progress = progress;
      if (persist) _commitProgress(progress);
      return true;
    } finally {
      _restoringAnchor = false;
    }
  }

  Future<void> _navigateTarget(ReaderDocumentLinkTarget target) async {
    if (_progress != null) _linkReturnStack.add(_progress!);
    if (target.chapterId == _chapter?.chapterId) {
      if (target.anchor != null) await _jumpTo(target.anchor!, 0);
      return;
    }
    final index = _catalog.indexWhere((item) => item.id == target.chapterId);
    if (index >= 0) await _loadChapter(index, anchor: target.anchor);
  }

  Future<void> _openHref(String href) async {
    try {
      final target = await widget.dataSource.resolveLink(
        _chapter!.chapterId,
        href,
      );
      if (target != null && mounted) await _navigateTarget(target);
    } catch (error) {
      _reportFailure(error, 'document_link');
    }
  }

  Future<void> _changePreferences(TextReaderPreferences next) async {
    _previewPreferences(next);
    try {
      await widget.stateStore.savePreferences(_preferences);
    } catch (error) {
      _reportFailure(
        error,
        'document_preferences',
        ReaderFailureKind.persistence,
      );
    }
  }

  void _previewPreferences(TextReaderPreferences next) {
    final anchor = _captureVisibleProgress() ?? _progress;
    final restoreGeneration = ++_anchorRestoreGeneration;
    setState(() => _preferences = next.normalized());
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || restoreGeneration != _anchorRestoreGeneration) return;
      unawaited(
        _jumpTo(
          anchor.paragraphId,
          anchor.characterOffset,
          persist: false,
          animate: false,
        ),
      );
    });
  }

  void _setUseBookStyles(bool enabled) {
    setState(() => _useBookStyles = enabled);
  }

  void _releaseChapterRenderState() {
    for (final recognizers in _linkRecognizers.values) {
      for (final recognizer in recognizers.values) {
        recognizer.dispose();
      }
    }
    _linkRecognizers.clear();
    _blockKeys.clear();
    _resources.clear();
    _resourceRetryCounts.clear();
    _reportedResourceErrors.clear();
  }

  void _retryResource(String resourceId) {
    if (!mounted) return;
    setState(() {
      _resources.remove(resourceId);
      _reportedResourceErrors.remove(resourceId);
      _resourceRetryCounts.update(
        resourceId,
        (attempt) => attempt + 1,
        ifAbsent: () => 1,
      );
    });
  }

  Color get _background => switch (_preferences.theme) {
    ReaderThemePreset.night ||
    ReaderThemePreset.deepNight ||
    ReaderThemePreset.charcoal ||
    ReaderThemePreset.oled ||
    ReaderThemePreset.midnight ||
    ReaderThemePreset.forestNight => const Color(0xff171717),
    ReaderThemePreset.parchment => const Color(0xfff2e8d5),
    ReaderThemePreset.eyeCare => const Color(0xffe8efdf),
    _ => const Color(0xfffffdf8),
  };
  Color get _foreground => switch (_preferences.theme) {
    ReaderThemePreset.night ||
    ReaderThemePreset.deepNight ||
    ReaderThemePreset.charcoal ||
    ReaderThemePreset.oled ||
    ReaderThemePreset.midnight ||
    ReaderThemePreset.forestNight => const Color(0xffe6e2d9),
    _ => const Color(0xff282720),
  };

  @override
  Widget build(BuildContext context) {
    if (_loading && _chapter == null) {
      return Scaffold(
        backgroundColor: _background,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_failure != null && _chapter == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('无法打开文档'),
              const SizedBox(height: 12),
              TextButton(onPressed: _start, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: _foreground,
        title: Text(
          _book?.title ?? '文档阅读',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: Icon(
            _linkReturnStack.isNotEmpty ? Icons.arrow_back : Icons.close,
          ),
          onPressed: _linkReturnStack.isNotEmpty
              ? _returnFromLink
              : _requestExit,
        ),
        actions: [
          IconButton(
            tooltip: '目录',
            onPressed: _showToc,
            icon: const Icon(Icons.format_list_bulleted),
          ),
          IconButton(
            tooltip: '书签',
            onPressed: _showBookmarks,
            icon: const Icon(Icons.bookmark),
          ),
          IconButton(
            tooltip: '添加书签',
            onPressed: _addBookmark,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
          IconButton(
            tooltip: '字号与主题',
            onPressed: _showReadingControls,
            icon: const Icon(Icons.text_fields),
          ),
        ],
      ),
      body: _failure != null
          ? Column(
              children: [
                MaterialBanner(
                  content: Text('章节加载失败：$_failure'),
                  actions: [
                    TextButton(
                      onPressed: () =>
                          _loadChapter(_failedTargetIndex ?? _chapterIndex),
                      child: const Text('重试'),
                    ),
                  ],
                ),
                Expanded(child: _documentBody()),
              ],
            )
          : _documentBody(),
      bottomNavigationBar: _catalog.isEmpty
          ? null
          : BottomAppBar(
              color: _background,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: _chapterIndex > 0
                        ? () => _loadChapter(_chapterIndex - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      '${_chapterIndex + 1} / ${_catalog.length}  ${_chapter?.title ?? ''}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    onPressed: _chapterIndex + 1 < _catalog.length
                        ? () => _loadChapter(_chapterIndex + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _documentBody() => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final oldSize = _lastBodySize;
      _lastBodySize = size;
      if (oldSize != null && oldSize != size && _progress != null) {
        _scheduleSemanticRestore(_progress!);
      }
      final chapter = _chapter;
      final chapterTitle = chapter?.title.trim() ?? '';
      final firstHeading = chapter == null
          ? null
          : _flattenBlocks(chapter.blocks)
                .where((block) => block.type == 'heading')
                .map((block) => _blockText(block).trim())
                .firstOrNull;
      final showChapterTitle =
          chapterTitle.isNotEmpty && firstHeading != chapterTitle;
      return SingleChildScrollView(
        key: _viewportKey,
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(
          _preferences.horizontalPadding,
          _preferences.topPadding,
          _preferences.horizontalPadding,
          _preferences.bottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showChapterTitle)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Text(
                  chapterTitle,
                  style: TextStyle(
                    fontSize: _preferences.fontSize + 5,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: _foreground,
                  ),
                ),
              ),
            for (final block
                in _chapter?.blocks ?? const <ReaderDocumentBlock>[])
              _renderBlock(block),
            if (_chapterIndex + 1 < _catalog.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: OutlinedButton.icon(
                  key: const Key('document-next-segment'),
                  onPressed: () => _loadChapter(_chapterIndex + 1),
                  icon: const Icon(Icons.arrow_downward),
                  label: Text('下一章：${_catalog[_chapterIndex + 1].title}'),
                ),
              ),
          ],
        ),
      );
    },
  );

  void _scheduleSemanticRestore(ReaderProgress progress) {
    _restoringAnchor = true;
    _progressTimer?.cancel();
    final generation = ++_anchorRestoreGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _anchorRestoreGeneration) return;
      final restored = await _jumpTo(
        progress.paragraphId,
        progress.characterOffset,
        persist: false,
        animate: false,
      );
      if (!restored) {
        _restoringAnchor = false;
      }
    });
  }

  Future<void> _returnFromLink() async {
    if (_linkReturnStack.isEmpty) return;
    final p = _linkReturnStack.removeLast();
    final index = _catalog.indexWhere((c) => c.id == p.chapterId);
    if (index < 0) return;
    if (index != _chapterIndex) {
      await _loadChapter(index, anchor: p.paragraphId);
    }
    if (mounted) {
      await _jumpTo(p.paragraphId, p.characterOffset);
    }
  }

  void _requestExit() {
    if (widget.observer case final ReaderObserver observer) {
      _notifyObserver(() => observer.onExitRequested(_progress));
    } else {
      final callback = widget.onBackRequested;
      if (callback != null) {
        callback();
      } else {
        unawaited(Navigator.of(context).maybePop());
      }
    }
  }

  Future<void> _showToc() async {
    final entries = widget.navigationEntries.isNotEmpty
        ? widget.navigationEntries
        : _catalog
              .map(
                (chapter) => ReaderDocumentNavigationEntry(
                  title: chapter.title,
                  chapterId: chapter.id,
                ),
              )
              .toList();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final item = entries[index];
            return ListTile(
              contentPadding: EdgeInsets.only(
                left: 16 + item.depth.clamp(0, 6) * 16.0,
                right: 16,
              ),
              title: Text(item.title),
              onTap: () {
                Navigator.pop(context);
                final ci = _catalog.indexWhere(
                  (chapter) => chapter.id == item.chapterId,
                );
                if (ci >= 0) unawaited(_loadChapter(ci, anchor: item.anchor));
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _addBookmark() async {
    final p = _progress;
    if (p == null || p.paragraphId.isEmpty || _chapter == null) return;
    final block = _chapter!.blocks
        .where((b) => b.id == p.paragraphId)
        .firstOrNull;
    final bookmark = ReaderBookmark(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      bookId: widget.bookId,
      chapterId: p.chapterId,
      paragraphId: p.paragraphId,
      characterOffset: p.characterOffset,
      chapterTitle: _chapter!.title,
      excerpt: (block == null ? '' : _blockText(block))
          .replaceAll('\n', ' ')
          .substring(
            0,
            (block == null ? 0 : _blockText(block).length).clamp(0, 100),
          ),
      createdAt: DateTime.now(),
    );
    await widget.stateStore.addBookmark(bookmark);
    if (mounted) setState(() => _bookmarks = [..._bookmarks, bookmark]);
  }

  Future<void> _showBookmarks() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: _bookmarks.isEmpty
            ? const SizedBox(height: 100, child: Center(child: Text('还没有书签')))
            : ListView.builder(
                itemCount: _bookmarks.length,
                itemBuilder: (context, index) {
                  final bookmark = _bookmarks[index];
                  return ListTile(
                    title: Text(bookmark.chapterTitle),
                    subtitle: Text(
                      bookmark.excerpt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      final ci = _catalog.indexWhere(
                        (c) => c.id == bookmark.chapterId,
                      );
                      if (ci >= 0) {
                        if (ci == _chapterIndex) {
                          unawaited(
                            _jumpTo(
                              bookmark.paragraphId,
                              bookmark.characterOffset,
                            ),
                          );
                        } else {
                          unawaited(
                            _loadChapter(ci, anchor: bookmark.paragraphId),
                          );
                        }
                      }
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await widget.stateStore.removeBookmark(
                          widget.bookId,
                          bookmark.id,
                        );
                        if (mounted) {
                          setState(
                            () => _bookmarks.removeWhere(
                              (b) => b.id == bookmark.id,
                            ),
                          );
                        }
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _syncAwake() async {
    if (_preferences.keepScreenOn) {
      await ScreenAwakeCoordinator.instance.acquire(_awakeHolder);
    } else {
      await ScreenAwakeCoordinator.instance.release(_awakeHolder);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ReaderLifecycleState normalized = switch (state) {
      AppLifecycleState.resumed => ReaderLifecycleState.foreground,
      AppLifecycleState.inactive => ReaderLifecycleState.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused => ReaderLifecycleState.background,
      AppLifecycleState.detached => ReaderLifecycleState.detached,
    };
    _notifyObserver(
      () => widget.observer?.onLifecycleChanged(normalized, _progress),
    );
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncAwake());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(ScreenAwakeCoordinator.instance.release(_awakeHolder));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _releaseChapterRenderState();
    if (_sessionStarted) {
      _notifyObserver(
        () => widget.observer?.onSessionEnded(widget.bookId, _progress),
      );
    }
    _progressTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(ScreenAwakeCoordinator.instance.release(_awakeHolder));
    if (_progress != null) {
      unawaited(
        widget.stateStore.saveProgress(widget.bookId, _progress!).catchError((
          Object error,
        ) {
          _reportFailure(
            error,
            'document_progress',
            ReaderFailureKind.persistence,
          );
        }),
      );
    }
    super.dispose();
  }
}
