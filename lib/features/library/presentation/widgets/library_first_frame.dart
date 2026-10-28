/// 首页首次绘制就绪边界。
///
/// 在真实布局和可见封面解码完成后通知启动遮罩；不等待屏外条目。
/// 图片失败按降级封面就绪处理，慢网络最多等待三秒；离开页面时撤销监听。
/// 仅协调首次展示，不拥有书架数据、网络请求或图片缓存。
library;

import 'dart:async';

import 'package:flutter/material.dart';

class LibraryFirstFrame extends StatefulWidget {
  const LibraryFirstFrame({required this.onReady, required this.child, super.key});

  final VoidCallback onReady;
  final Widget child;

  @override
  State<LibraryFirstFrame> createState() => _LibraryFirstFrameState();
}

class _LibraryFirstFrameState extends State<LibraryFirstFrame> {
  final Set<_LibraryCoverFirstFrameState> _covers = {};
  Timer? _deadline;
  bool _scheduled = false;
  bool _complete = false;

  @override
  void initState() {
    super.initState();
    _deadline = Timer(const Duration(seconds: 3), _finish);
    _checkAfterPaint();
  }

  void _checkAfterPaint() {
    if (_scheduled || _complete || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _complete) return;
      if (_covers.any((cover) => cover._blocksFirstFrame)) return;
      _finish();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _finish() {
    if (!mounted || _complete) return;
    _complete = true;
    _deadline?.cancel();
    for (final cover in _covers.toList()) {
      cover._stopListening();
    }
    widget.onReady();
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FirstFrameScope(owner: this, child: widget.child);
}

class _FirstFrameScope extends InheritedWidget {
  const _FirstFrameScope({required this.owner, required super.child});

  final _LibraryFirstFrameState owner;

  @override
  bool updateShouldNotify(_FirstFrameScope oldWidget) => oldWidget.owner != owner;
}

/// Observes the same cached image stream as the cover, without a second fetch
/// or decode. Covers outside the initial viewport never hold the startup gate.
class LibraryCoverFirstFrame extends StatefulWidget {
  const LibraryCoverFirstFrame({required this.loading, required this.image, required this.child, super.key});

  final bool loading;
  final ImageProvider? image;
  final Widget child;

  @override
  State<LibraryCoverFirstFrame> createState() => _LibraryCoverFirstFrameState();
}

class _LibraryCoverFirstFrameState extends State<LibraryCoverFirstFrame> {
  _LibraryFirstFrameState? _owner;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _decoded = false;

  bool get _blocksFirstFrame {
    if (!mounted || (!widget.loading && (widget.image == null || _decoded))) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    // An intrinsic cover can have zero height until its first decoded frame.
    // Its visible origin must still hold the gate while that layout is pending.
    final origin = box.localToGlobal(Offset.zero);
    final bounds = Rect.fromLTWH(origin.dx, origin.dy, box.size.width > 0 ? box.size.width : 1, box.size.height > 0 ? box.size.height : 1);
    return bounds.overlaps(Offset.zero & MediaQuery.sizeOf(context));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.dependOnInheritedWidgetOfExactType<_FirstFrameScope>()?.owner;
    if (!identical(owner, _owner)) {
      _owner?._covers.remove(this);
      _owner?._checkAfterPaint();
      _owner = owner;
      owner?._covers.add(this);
    }
    _observeImage();
  }

  @override
  void didUpdateWidget(LibraryCoverFirstFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _observeImage();
    _owner?._checkAfterPaint();
  }

  void _observeImage() {
    _stopListening();
    _decoded = false;
    final image = widget.image;
    if (_owner == null || _owner!._complete || image == null) return;
    _stream = image.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, synchronousCall) {
        info.dispose();
        _decoded = true;
        _owner?._checkAfterPaint();
      },
      onError: (Object error, StackTrace? stack) {
        _decoded = true;
        _owner?._checkAfterPaint();
      },
    );
    _stream!.addListener(_listener!);
  }

  void _stopListening() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _listener = null;
    _stream = null;
  }

  @override
  void dispose() {
    _stopListening();
    _owner?._covers.remove(this);
    _owner?._checkAfterPaint();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
