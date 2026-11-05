/// 数据源 TV 子页面布局。仅持有分区选择、滚动和焦点，不执行业务 IO。
/// 左侧导航/操作与右侧内容分别滚动；短屏保留可达性，长正文支持方向键逐屏阅读。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class TvSourceWorkspace extends StatelessWidget {
  const TvSourceWorkspace({required this.sidebar, required this.child, super.key});
  final Widget sidebar;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: (constraints.maxWidth * .28).clamp(180.0, 320.0), child: sidebar),
            const SizedBox(width: 20),
            Expanded(child: child),
          ],
        ),
      );
    },
  );
}

class TvSourceSection {
  const TvSourceSection({required this.id, required this.title, required this.icon, required this.children});
  final String id;
  final String title;
  final IconData icon;
  final List<Widget> children;
}

class TvSourceSections extends StatefulWidget {
  const TvSourceSections({required this.sections, super.key});
  final List<TvSourceSection> sections;
  @override
  State<TvSourceSections> createState() => _TvSourceSectionsState();
}

class _TvSourceSectionsState extends State<TvSourceSections> {
  String? _selected;
  @override
  Widget build(BuildContext context) {
    final current = widget.sections.where((item) => item.id == _selected).firstOrNull ?? widget.sections.first;
    return TvSourceWorkspace(
      sidebar: ListView(
        padding: const EdgeInsets.all(4),
        children: [
          for (final section in widget.sections)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TvFocusable(
                key: Key('tv-source-section-${section.id}'),
                selected: current.id == section.id,
                onPressed: () => setState(() => _selected = section.id),
                child: Row(
                  children: [
                    Icon(section.icon),
                    const SizedBox(width: 12),
                    Expanded(child: Text(section.title)),
                  ],
                ),
              ),
            ),
        ],
      ),
      child: ListView(
        key: ValueKey('tv-source-section-content-${current.id}'),
        padding: const EdgeInsets.all(4),
        children: [for (final child in current.children) Padding(padding: const EdgeInsets.only(bottom: 16), child: child)],
      ),
    );
  }
}

class TvSourcePanel extends StatelessWidget {
  const TvSourcePanel({required this.title, required this.child, this.icon, super.key});
  final String title;
  final IconData? icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(color: AppThemeTokens.of(context).surface, borderRadius: AppRadii.detailCard),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[Icon(icon, color: AppThemeTokens.of(context).dataSourceAccent), const SizedBox(width: 12)],
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          ],
        ),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );
}

/// A focusable reading viewport. Child controls keep their own directional keys;
/// when the viewport itself is focused, up/down page through the full document.
class TvSourceScrollBody extends StatefulWidget {
  const TvSourceScrollBody({required this.child, super.key});
  final Widget child;
  @override
  State<TvSourceScrollBody> createState() => _TvSourceScrollBodyState();
}

class _TvSourceScrollBodyState extends State<TvSourceScrollBody> {
  final _scroll = ScrollController();
  bool _focused = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus || event is KeyUpEvent || !_scroll.hasClients) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    final position = _scroll.position;
    final target = (position.pixels + (down ? 1 : -1) * position.viewportDimension * .7).clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return KeyEventResult.ignored;
    _scroll.jumpTo(target);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: _onKey,
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: _focused ? AppThemeTokens.of(context).accent : Colors.transparent, width: 2),
        borderRadius: AppRadii.detailControl,
      ),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(controller: _scroll, padding: const EdgeInsets.all(8), child: widget.child),
      ),
    ),
  );
}
