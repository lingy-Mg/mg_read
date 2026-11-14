/// 下拉刷新适配；无动画时只监听真实拖动与松手，不创建刷新动画控制器。
/// 刷新 Future 属于调用方，组件仅持有等待展示；销毁后不提交展示状态。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'motion_policy.dart';
import 'motion_surfaces.dart';

class MotionRefreshIndicator extends StatefulWidget {
  const MotionRefreshIndicator({
    required this.onRefresh,
    required this.child,
    super.key,
  });
  final Future<void> Function() onRefresh;
  final Widget child;
  @override
  State<MotionRefreshIndicator> createState() => _MotionRefreshIndicatorState();
}

class _MotionRefreshIndicatorState extends State<MotionRefreshIndicator> {
  double _distance = 0;
  bool _dragging = false;
  bool _refreshing = false;
  Future<void>? _pending;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _dragging = notification.dragDetails != null;
      _distance = 0;
    } else if (notification is OverscrollNotification &&
        _dragging &&
        notification.dragDetails != null) {
      if (notification.metrics.extentBefore == 0) {
        _distance = (_distance - notification.overscroll).clamp(0, 200);
      }
    } else if (notification is ScrollUpdateNotification &&
        _dragging &&
        notification.dragDetails != null) {
      // Bouncing physics reports negative pixels rather than overscroll.
      if (notification.metrics.pixels < notification.metrics.minScrollExtent) {
        _distance =
            (notification.metrics.minScrollExtent - notification.metrics.pixels)
                .clamp(0, 200);
      }
    } else if (notification is ScrollEndNotification) {
      final trigger = _dragging && _distance >= 64;
      _dragging = false;
      _distance = 0;
      if (trigger) unawaited(_refresh());
    }
    return false;
  }

  Future<void> _refresh() {
    if (_pending != null) return _pending!;
    setState(() => _refreshing = true);
    return _pending = Future<void>.sync(widget.onRefresh).whenComplete(() {
      _pending = null;
      if (mounted) setState(() => _refreshing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!motionDisabled(context)) {
      return RefreshIndicator(onRefresh: _refresh, child: widget.child);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        children: [
          widget.child,
          if (_refreshing)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Semantics(
                  liveRegion: true,
                  child: MotionMaterial(
                    color: Theme.of(context).colorScheme.surface,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('正在刷新…', textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
