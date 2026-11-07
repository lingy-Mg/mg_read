/// TV collection pagination keeps two viewports of content ahead without taking
/// focus, allowing appended covers to start loading before they become visible.
/// The host serializes automatic requests within a frame; application state owns
/// IO, cancellation and result merging. A failed or non-advancing cursor requires
/// explicit retry, and source/category changes reset the local attempt guard.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class DiscoveryTvPaginationHost extends StatefulWidget {
  const DiscoveryTvPaginationHost({
    required this.enabled,
    required this.identity,
    required this.replacingContent,
    required this.loadingCollectionId,
    required this.onLoadMore,
    required this.child,
    super.key,
  });

  final bool enabled;
  final Object identity;
  final bool replacingContent;
  final String? loadingCollectionId;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final Widget child;

  @override
  State<DiscoveryTvPaginationHost> createState() => _PaginationHostState();
}

class _PaginationHostState extends State<DiscoveryTvPaginationHost> {
  bool _pending = false;
  int _requestEpoch = 0;
  bool get busy => _pending || widget.replacingContent || widget.loadingCollectionId != null;

  bool request(PluginDiscoveryContentCollectionComponent collection) {
    if (!widget.enabled || busy) return false;
    _pending = true;
    final epoch = ++_requestEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pending && epoch == _requestEpoch) setState(() => _pending = false);
    });
    widget.onLoadMore(collection);
    return true;
  }

  @override
  void didUpdateWidget(DiscoveryTvPaginationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pending = false;
  }

  @override
  Widget build(BuildContext context) => _PaginationScope(host: this, child: widget.child);
}

class _PaginationScope extends InheritedWidget {
  const _PaginationScope({required this.host, required super.child});
  final _PaginationHostState host;
  static _PaginationHostState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PaginationScope>()!.host;
  @override
  bool updateShouldNotify(_PaginationScope oldWidget) => true;
}

class DiscoveryTvPaginationFooter extends StatefulWidget {
  const DiscoveryTvPaginationFooter({required this.collection, super.key});
  final PluginDiscoveryContentCollectionComponent collection;

  @override
  State<DiscoveryTvPaginationFooter> createState() => _PaginationFooterState();
}

class _PaginationFooterState extends State<DiscoveryTvPaginationFooter> {
  final _anchor = GlobalKey();
  final _retryFocus = FocusNode();
  late _PaginationHostState _host;
  ScrollPosition? _scroll;
  Object? _identity, _attempt, _blocked;
  bool _scheduled = false, _awaitingResult = false;

  Object get _key =>
      (_host.widget.identity, widget.collection.id, widget.collection.continuation?.target, widget.collection.continuation?.cursor);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _host = _PaginationScope.of(context);
    if (_identity != _host.widget.identity || _host.widget.replacingContent) {
      _identity = _host.widget.identity;
      _attempt = _blocked = null;
      _awaitingResult = false;
    }
    final scroll = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (_scroll != scroll) {
      _scroll?.removeListener(_schedule);
      _scroll = scroll?..addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(DiscoveryTvPaginationFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _check() {
    _scheduled = false;
    if (!mounted ||
        !_host.widget.enabled ||
        _host.busy ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if (_awaitingResult) {
      _awaitingResult = false;
      if (_attempt == _key) {
        setState(() => _blocked = _key);
      }
    }
    if (_blocked == _key || _attempt == _key || widget.collection.continuation == null) return;
    final anchor = _anchor.currentContext?.findRenderObject();
    if (anchor is! RenderBox || !anchor.attached || !anchor.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(anchor);
    if (viewport == null) return;
    if (viewport is! RenderBox) return;
    final viewportBox = viewport as RenderBox;
    if (!viewportBox.hasSize) return;
    final top = anchor.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
    if (top + anchor.size.height < 0 || top > viewportBox.size.height * 3) return;
    _request();
  }

  void _request() {
    if (!_host.request(widget.collection)) return;
    setState(() {
      _attempt = _key;
      _awaitingResult = true;
      _blocked = null;
    });
  }

  @override
  void dispose() {
    _scroll?.removeListener(_schedule);
    _retryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loading = _host.widget.loadingCollectionId == widget.collection.id || (_awaitingResult && _host.busy);
    return SizedBox(
      key: _anchor,
      height: 56,
      child: _blocked == _key && !loading
          ? TvFocusable(
              key: ValueKey('runtime-discovery-retry-${widget.collection.id}'),
              focusNode: _retryFocus,
              onPressed: () {
                _retryFocus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
                _request();
              },
              child: const Center(child: Text('加载失败，按 OK 重试')),
            )
          : Center(
              child: loading
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('正在加载下一页…'),
                      ],
                    )
                  : const Text('继续浏览将自动加载'),
            ),
    );
  }
}
