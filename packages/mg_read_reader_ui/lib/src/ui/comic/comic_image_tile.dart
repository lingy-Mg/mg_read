import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/contracts.dart';
import '../../api/comic_models.dart';
import '../../api/models.dart';
import '../comments/reader_comment_strings.dart';
import '../reader_theme.dart';
import 'comic_image_cache.dart';
import 'comic_reader_strings.dart';

class ComicDecodedImageBudget {
  ComicDecodedImageBudget({this.maximumPixels = 12 * 1024 * 1024});

  final int maximumPixels;
  final Map<Object, int> _reservations = <Object, int>{};
  int _usedPixels = 0;

  int reserve(Object owner, int desiredPixels) {
    _usedPixels -= _reservations.remove(owner) ?? 0;
    final int available = (maximumPixels - _usedPixels).clamp(0, maximumPixels);
    final int granted = desiredPixels.clamp(1, available < 1 ? 1 : available);
    _reservations[owner] = granted;
    _usedPixels += granted;
    return granted;
  }

  void release(Object owner) {
    _usedPixels -= _reservations.remove(owner) ?? 0;
  }
}

/// Private progressive image cell used by the comic reader surface.
///
/// Its fixed outer extent never changes between loading, success, and error,
/// so slow or failed image requests cannot move semantic reading progress.
class ComicProgressiveImageTile extends StatefulWidget {
  const ComicProgressiveImageTile({
    super.key,
    required this.cache,
    required this.chapterId,
    required this.image,
    required this.width,
    required this.height,
    required this.spacing,
    required this.palette,
    required this.onFailure,
    required this.decodeBudget,
    this.commentFeed,
    this.bookId,
    this.onOpenComments,
  });

  final ComicImageByteCache cache;
  final String chapterId;
  final ComicImageInfo image;
  final double width;
  final double height;
  final double spacing;
  final ReaderPalette palette;
  final ValueChanged<Object> onFailure;
  final ComicDecodedImageBudget decodeBudget;
  final ReaderCommentFeed? commentFeed;
  final String? bookId;
  final ValueChanged<ReaderCommentTarget>? onOpenComments;

  @override
  State<ComicProgressiveImageTile> createState() =>
      _ComicProgressiveImageTileState();
}

class _ComicProgressiveImageTileState extends State<ComicProgressiveImageTile> {
  late Future<Uint8List> _future;
  Uint8List? _decodedBytes;
  ImageProvider<Object>? _decodedProvider;
  int? _decodeWidth;
  int? _decodeHeight;
  bool _reportedError = false;

  @override
  void initState() {
    super.initState();
    _future = widget.cache.load(widget.chapterId, widget.image);
  }

  @override
  void didUpdateWidget(covariant ComicProgressiveImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.chapterId != widget.chapterId ||
        oldWidget.image.id != widget.image.id ||
        oldWidget.image.contentVersion != widget.image.contentVersion ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _evictDecodedImage();
      _reportedError = false;
      _future = widget.cache.load(widget.chapterId, widget.image);
    }
  }

  @override
  void dispose() {
    widget.decodeBudget.release(this);
    _evictDecodedImage();
    super.dispose();
  }

  void _evictDecodedImage() {
    final ImageProvider<Object>? provider = _decodedProvider;
    _decodedBytes = null;
    _decodedProvider = null;
    _decodeWidth = null;
    _decodeHeight = null;
    if (provider != null) provider.evict().ignore();
  }

  void _retry() {
    setState(() {
      _evictDecodedImage();
      _reportedError = false;
      _future = widget.cache.load(
        widget.chapterId,
        widget.image,
        forceRefresh: true,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height + widget.spacing,
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.spacing),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            FutureBuilder<Uint8List>(
              future: _future,
              builder:
                  (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
                    if (snapshot.hasData) {
                      final Uint8List bytes = snapshot.data!;
                      final double devicePixelRatio =
                          MediaQuery.devicePixelRatioOf(context);
                      final double logicalRatio = (widget.width / widget.height)
                          .clamp(.02, 20);
                      final double idealWidth = widget.width * devicePixelRatio;
                      final int idealPixels =
                          (idealWidth * (idealWidth / logicalRatio)).round();
                      final int maxDecodedPixels = widget.decodeBudget.reserve(
                        this,
                        idealPixels.clamp(1, 4 * 1024 * 1024),
                      );
                      final double pixelSafeWidth = math.sqrt(
                        maxDecodedPixels * logicalRatio,
                      );
                      final int decodeWidth =
                          (idealWidth < pixelSafeWidth
                                  ? idealWidth
                                  : pixelSafeWidth)
                              .round()
                              .clamp(1, 8192);
                      final int decodeHeight = (decodeWidth / logicalRatio)
                          .round()
                          .clamp(1, 32768);
                      if (!identical(_decodedBytes, bytes) ||
                          _decodeWidth != decodeWidth ||
                          _decodeHeight != decodeHeight) {
                        _evictDecodedImage();
                        _decodedBytes = bytes;
                        _decodeWidth = decodeWidth;
                        _decodeHeight = decodeHeight;
                        _decodedProvider = ResizeImage.resizeIfNeeded(
                          decodeWidth,
                          decodeHeight,
                          MemoryImage(bytes),
                        );
                      }
                      return Semantics(
                        image: true,
                        label: ComicReaderStrings.imageSemantics(
                          widget.image.index + 1,
                        ),
                        child: Image(
                          image: _decodedProvider!,
                          width: double.infinity,
                          height: widget.height,
                          fit: BoxFit.contain,
                          alignment: Alignment.topCenter,
                          filterQuality: FilterQuality.medium,
                          errorBuilder:
                              (
                                BuildContext context,
                                Object error,
                                StackTrace? stack,
                              ) {
                                _reportErrorOnce(error);
                                return _error();
                              },
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      _reportErrorOnce(snapshot.error!);
                      return _error();
                    }
                    return ColoredBox(
                      color: const Color(0xFF17191B),
                      child: Center(
                        child: Semantics(
                          label: ComicReaderStrings.loadingImage,
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: widget.palette.accent,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
            ),
            if (widget.commentFeed != null &&
                widget.bookId != null &&
                widget.onOpenComments != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: _ComicImageCommentButton(
                  feed: widget.commentFeed!,
                  target: ReaderCommentTarget.comicImage(
                    widget.bookId!,
                    widget.chapterId,
                    widget.image.id,
                  ),
                  palette: widget.palette,
                  onFailure: widget.onFailure,
                  onOpen: widget.onOpenComments!,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _error() {
    return ColoredBox(
      color: const Color(0xFF17191B),
      child: Center(
        child: TextButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text(ComicReaderStrings.imageFailed),
        ),
      ),
    );
  }

  void _reportErrorOnce(Object error) {
    if (_reportedError) return;
    _reportedError = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFailure(error);
    });
  }
}

class _ComicImageCommentButton extends StatefulWidget {
  const _ComicImageCommentButton({
    required this.feed,
    required this.target,
    required this.palette,
    required this.onFailure,
    required this.onOpen,
  });

  final ReaderCommentFeed feed;
  final ReaderCommentTarget target;
  final ReaderPalette palette;
  final ValueChanged<Object> onFailure;
  final ValueChanged<ReaderCommentTarget> onOpen;

  @override
  State<_ComicImageCommentButton> createState() =>
      _ComicImageCommentButtonState();
}

class _ComicImageCommentButtonState extends State<_ComicImageCommentButton> {
  int _generation = 0;
  int _count = 0;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ComicImageCommentButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed) ||
        oldWidget.target != widget.target) {
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final Map<ReaderCommentTarget, ReaderCommentSummary> summaries =
          await widget.feed.loadSummaries(<ReaderCommentTarget>[
            widget.target,
          ], previewLimit: 0);
      if (!mounted || generation != _generation) return;
      if (summaries.length > 1 ||
          summaries.keys.any(
            (ReaderCommentTarget target) => target != widget.target,
          ) ||
          summaries.values.any(
            (ReaderCommentSummary summary) =>
                summary.target != widget.target ||
                summary.topComments.isNotEmpty,
          )) {
        throw StateError('Comic comment summary target is invalid.');
      }
      setState(() {
        _count = summaries[widget.target]?.total ?? 0;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      widget.onFailure(error);
    }
  }

  void _openComments() {
    widget.onOpen(widget.target);
  }

  @override
  Widget build(BuildContext context) {
    final String count = ReaderCommentStrings.compactCount(_count);
    final String label = _loading
        ? ComicReaderStrings.imageCommentLoading
        : _failed
        ? ComicReaderStrings.imageCommentFailed
        : ComicReaderStrings.imageCommentCount(_count);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: const Color(0xB8181A1C),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _loading
                ? null
                : _failed
                ? _load
                : _openComments,
            child: SizedBox.square(
              dimension: 48,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 27,
                    color: _failed
                        ? widget.palette.accent
                        : widget.palette.text,
                  ),
                  Positioned(
                    left: 9,
                    right: 9,
                    top: 10,
                    height: 10,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _loading
                            ? '…'
                            : _failed
                            ? '!'
                            : count,
                        maxLines: 1,
                        style: TextStyle(
                          color: _failed
                              ? widget.palette.accent
                              : widget.palette.text,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
