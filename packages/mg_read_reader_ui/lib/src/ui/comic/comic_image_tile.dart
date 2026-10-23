/// 漫画图片单元与会话内解码像素预算。
///
/// 同时挂载的图片按需求比例共享预算，不能因先到先占把后续图片解码成纯色色块。
/// 分配变化在帧结束后通知单元自行重解码；编码字节与布局尺寸仍由缓存及父列表持有。
/// 单元销毁或更换预算时释放预留，延迟通知只访问仍登记的单元。
library;

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
  ComicDecodedImageBudget({this.maximumPixels = 12 * 1024 * 1024})
    : assert(maximumPixels > 0);

  final int maximumPixels;
  final Map<Object, _ComicDecodeReservation> _reservations =
      <Object, _ComicDecodeReservation>{};
  bool _notificationScheduled = false;

  int allocationFor(Object owner) => _reservations[owner]?.grantedPixels ?? 0;

  int reserve(Object owner, int desiredPixels, {VoidCallback? onChanged}) {
    final int desired = math.max(1, desiredPixels);
    final _ComicDecodeReservation? previous = _reservations[owner];
    if (previous != null && previous.desiredPixels == desired) {
      previous.onChanged = onChanged;
      return previous.grantedPixels;
    }
    _reservations[owner] = _ComicDecodeReservation(desired, onChanged);
    _rebalance();
    return allocationFor(owner);
  }

  void release(Object owner) {
    if (_reservations.remove(owner) != null) _rebalance();
  }

  void _rebalance() {
    final int desiredTotal = _reservations.values.fold<int>(
      0,
      (total, reservation) => total + reservation.desiredPixels,
    );
    bool notify = false;
    for (final _ComicDecodeReservation reservation in _reservations.values) {
      final int granted = desiredTotal <= maximumPixels
          ? reservation.desiredPixels
          : reservation.desiredPixels * maximumPixels ~/ desiredTotal;
      if (granted != reservation.grantedPixels) {
        reservation.grantedPixels = granted;
        notify = notify || reservation.onChanged != null;
      }
    }
    if (!notify || _notificationScheduled) return;
    _notificationScheduled = true;
    // reserve/release can run while Flutter builds or removes a list cell.
    // Publish the final allocation after that frame instead of calling
    // setState on a sibling that is still in the middle of its build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      for (final Object owner in _reservations.keys.toList()) {
        _reservations[owner]?.onChanged?.call();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }
}

class _ComicDecodeReservation {
  _ComicDecodeReservation(this.desiredPixels, this.onChanged);
  final int desiredPixels;
  int grantedPixels = 0;
  VoidCallback? onChanged;
}

/// Private progressive image cell used by the comic reader surface.
///
/// The parent owns its extent using session-retained encoded dimensions.
/// Recreating a cell or retrying after byte eviction must reuse that geometry;
/// first-time dimension corrections are anchored by the parent's scroll layout.
class ComicProgressiveImageTile extends StatefulWidget {
  const ComicProgressiveImageTile({
    super.key,
    required this.cache,
    required this.chapterId,
    required this.image,
    required this.width,
    required this.placeholderHeight,
    required this.palette,
    required this.onFailure,
    required this.decodeBudget,
    this.onPresented,
    this.onAutomaticRetryAvailable,
    this.commentFeed,
    this.bookId,
    this.onOpenComments,
  });

  final ComicImageByteCache cache;
  final String chapterId;
  final ComicImageInfo image;
  final double width;
  final double placeholderHeight;
  final ReaderPalette palette;
  final ValueChanged<Object> onFailure;
  final ComicDecodedImageBudget decodeBudget;
  final ValueChanged<bool>? onPresented;
  final ValueChanged<Future<void> Function()>? onAutomaticRetryAvailable;
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
  double? _decodedAspectRatio;
  int? _decodeWidth;
  int? _decodeHeight;
  int? _reservedPixels;
  bool _reportedError = false;
  bool _presented = false;
  late bool _cacheHit;

  @override
  void initState() {
    super.initState();
    _cacheHit = widget.cache.contains(widget.chapterId, widget.image);
    _future = widget.cache.load(widget.chapterId, widget.image);
  }

  @override
  void didUpdateWidget(covariant ComicProgressiveImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.decodeBudget, widget.decodeBudget)) {
      oldWidget.decodeBudget.release(this);
      _reservedPixels = null;
    }
    if (oldWidget.cache != widget.cache ||
        oldWidget.chapterId != widget.chapterId ||
        oldWidget.image.id != widget.image.id ||
        oldWidget.image.contentVersion != widget.image.contentVersion ||
        oldWidget.width != widget.width) {
      _evictDecodedImage();
      _reportedError = false;
      _presented = false;
      _cacheHit = widget.cache.contains(widget.chapterId, widget.image);
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
    _decodedAspectRatio = null;
    _decodeWidth = null;
    _decodeHeight = null;
    if (provider != null) provider.evict().ignore();
  }

  void _handleDecodeBudgetChanged() {
    if (!mounted ||
        _reservedPixels == null ||
        widget.decodeBudget.allocationFor(this) == _reservedPixels) {
      return;
    }
    setState(() {});
  }

  void _retry() {
    if (!mounted) return;
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

  Future<void> _retryForAutomatic() {
    if (!mounted) return Future<void>.value();
    _retry();
    return _future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        if (snapshot.hasData) {
          if (!_presented) {
            _presented = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onPresented?.call(_cacheHit);
            });
          }
          final Uint8List bytes = snapshot.data!;
          final double devicePixelRatio = MediaQuery.devicePixelRatioOf(
            context,
          );
          final double logicalRatio = _declaredAspectRatio;
          final double idealWidth = widget.width * devicePixelRatio;
          final int idealPixels = (idealWidth * (idealWidth / logicalRatio))
              .round();
          final int maxDecodedPixels = widget.decodeBudget.reserve(
            this,
            idealPixels.clamp(1, 4 * 1024 * 1024),
            onChanged: _handleDecodeBudgetChanged,
          );
          _reservedPixels = maxDecodedPixels;
          if (maxDecodedPixels == 0) {
            return _placeholder(
              const CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final double pixelSafeWidth = math.sqrt(
            maxDecodedPixels * logicalRatio,
          );
          final int decodeWidth =
              (idealWidth < pixelSafeWidth ? idealWidth : pixelSafeWidth)
                  .floor()
                  .clamp(1, 8192);
          // Limit decode width only. Supplying a height derived from source
          // metadata can distort an image whose declared dimensions are stale.
          const int? decodeHeight = null;
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
            _decodedAspectRatio = widget.cache.aspectRatio(
              widget.chapterId,
              widget.image,
            );
          }
          return AspectRatio(
            aspectRatio: _decodedAspectRatio ?? _declaredAspectRatio,
            child: Semantics(
              image: true,
              label: ComicReaderStrings.imageSemantics(widget.image.index + 1),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Image(
                    key: ValueKey<String>(
                      'comic-reader-image-${widget.chapterId}-${widget.image.id}',
                    ),
                    image: _decodedProvider!,
                    // The outer tile already uses the encoded image ratio.
                    // Fill it once that ratio is known so integer decode-size
                    // rounding cannot expose a fractional black row between
                    // vertically adjacent pages at non-integer desktop DPI.
                    fit: _decodedAspectRatio == null
                        ? BoxFit.contain
                        : BoxFit.fill,
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
        if (snapshot.hasError) {
          _reportErrorOnce(snapshot.error!);
          return _error();
        }
        return _placeholder(
          Semantics(
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
        );
      },
    );
  }

  double get _declaredAspectRatio {
    final double? known = widget.cache.aspectRatio(
      widget.chapterId,
      widget.image,
    );
    if (known != null) return known;
    final int? width = widget.image.width;
    final int? height = widget.image.height;
    if (width == null || height == null) return .75;
    return (width / height).clamp(.02, 20).toDouble();
  }

  Widget _placeholder(Widget child) => SizedBox(
    height: widget.placeholderHeight,
    child: ColoredBox(
      color: const Color(0xFF17191B),
      child: Center(child: child),
    ),
  );

  Widget _error() {
    return _placeholder(
      TextButton.icon(
        key: ValueKey<String>(
          'comic-reader-image-retry-${widget.chapterId}-${widget.image.id}',
        ),
        onPressed: _retry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text(ComicReaderStrings.imageFailed),
      ),
    );
  }

  void _reportErrorOnce(Object error) {
    if (_reportedError) return;
    _reportedError = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onAutomaticRetryAvailable?.call(_retryForAutomatic);
        widget.onFailure(error);
      }
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
