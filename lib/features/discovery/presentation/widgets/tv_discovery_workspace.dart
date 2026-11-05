/// TV 发现子页面布局与阅读弹窗；只持有滚动、焦点，不访问内容或持久化服务。
/// 两栏分别滚动，短屏不挤压操作；长正文通过方向键逐屏阅读，边界交还焦点遍历。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class TvDiscoveryWorkspace extends StatelessWidget {
  const TvDiscoveryWorkspace({required this.sidebar, required this.child, this.sidebarFraction = .32, super.key});
  final Widget sidebar;
  final Widget child;
  final double sidebarFraction;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: ((constraints.maxWidth - 68) * sidebarFraction).clamp(200.0, 400.0), child: sidebar),
          const SizedBox(width: 20),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(color: AppThemeTokens.of(context).surface, borderRadius: AppRadii.detailCard),
              child: child,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Full text remains available without sending directional keys into selection.
Future<void> showTvDiscoveryText(BuildContext context, {required String title, required String text}) => showDialog<void>(
  context: context,
  builder: (context) => TvDiscoveryDialog(
    title: title,
    actions: [TvFocusable(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    child: Text(text),
  ),
);

class TvDiscoveryDialog extends StatelessWidget {
  const TvDiscoveryDialog({required this.title, required this.child, required this.actions, super.key});
  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 880, maxHeight: 600),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Flexible(child: _TvReadingViewport(child: child)),
            const SizedBox(height: 12),
            Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 8, children: actions),
          ],
        ),
      ),
    ),
  );
}

class _TvReadingViewport extends StatefulWidget {
  const _TvReadingViewport({required this.child});
  final Widget child;
  @override
  State<_TvReadingViewport> createState() => _TvReadingViewportState();
}

class _TvReadingViewportState extends State<_TvReadingViewport> {
  final _scroll = ScrollController();
  bool _focused = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (node, event) {
      if (!node.hasPrimaryFocus || !_scroll.hasClients || event is KeyUpEvent) return KeyEventResult.ignored;
      final direction = event.logicalKey == LogicalKeyboardKey.arrowDown
          ? 1
          : event.logicalKey == LogicalKeyboardKey.arrowUp
          ? -1
          : 0;
      if (direction == 0) return KeyEventResult.ignored;
      final next = (_scroll.offset + direction * _scroll.position.viewportDimension * .7).clamp(0.0, _scroll.position.maxScrollExtent);
      if ((next - _scroll.offset).abs() < 1) return KeyEventResult.ignored;
      _scroll.jumpTo(next);
      return KeyEventResult.handled;
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: _focused ? AppThemeTokens.of(context).focusRing : Colors.transparent, width: 2),
        borderRadius: AppRadii.control,
      ),
      child: SingleChildScrollView(
        key: const Key('tv-discovery-reading-scroll'),
        controller: _scroll,
        padding: const EdgeInsets.all(12),
        child: widget.child,
      ),
    ),
  );
}
