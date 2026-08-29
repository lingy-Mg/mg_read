/// 首页顶部操作栏。
///
/// 职责：
/// - 展示首页标题、搜索与更多操作入口。
/// - 通过书架私有锚点菜单转发顶层操作。
///
/// 注意：
/// - 不读取或写入书架数据。
/// - 触控入口保持 48dp 命中区，视觉规格仍来自全局主题。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_anchored_menu.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

/// 首页的标题与顶层操作。
class LibraryHomeTopBar extends StatelessWidget {
  const LibraryHomeTopBar({
    required this.onSearch,
    required this.onReadingHistory,
    required this.onManageSources,
    required this.onPrivacyLibrary,
    required this.layoutMode,
    required this.onLayoutModeToggle,
    this.onToggleTheme,
    super.key,
  });

  final VoidCallback onSearch;
  final VoidCallback? onToggleTheme;
  final VoidCallback onReadingHistory;
  final VoidCallback onManageSources;
  final VoidCallback onPrivacyLibrary;
  final LibraryHomeLayoutMode layoutMode;
  final VoidCallback onLayoutModeToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VoidCallback? toggleTheme = onToggleTheme;
    return SizedBox(
      height: AppSpacing.minimumTouchTarget,
      child: Row(
        children: <Widget>[
          const Expanded(child: AppPageTitle(title: '首页')),
          const SizedBox(width: AppSpacing.compact),
          _LibraryTopBarAction(tooltip: '搜索书籍', onPressed: onSearch, icon: Icons.search_rounded),
          if (AppTheme.darkModeEnabled && toggleTheme != null)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.compact),
              child: _LibraryTopBarAction(
                key: const Key('theme-mode-toggle'),
                tooltip: theme.brightness == Brightness.dark ? '切换至浅色模式' : '切换至深色模式',
                onPressed: toggleTheme,
                icon: theme.brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              ),
            ),
          const SizedBox(width: AppSpacing.compact),
          LibraryAnchoredMenu(
            tooltip: '更多操作',
            menuKey: const Key('library-top-overflow-menu'),
            actions: <LibraryAnchoredMenuAction>[
              LibraryAnchoredMenuAction(
                label: layoutMode == LibraryHomeLayoutMode.list ? '切换为卡片模式' : '切换为列表模式',
                onSelected: onLayoutModeToggle,
              ),
              LibraryAnchoredMenuAction(label: '阅读记录', onSelected: onReadingHistory),
              LibraryAnchoredMenuAction(label: '管理数据源', onSelected: onManageSources),
              LibraryAnchoredMenuAction(label: '隐私书架', onSelected: onPrivacyLibrary),
            ],
            triggerBuilder: (BuildContext context, VoidCallback onPressed) =>
                _LibraryTopBarAction(tooltip: '更多操作', onPressed: onPressed, icon: Icons.more_vert_rounded),
          ),
        ],
      ),
    );
  }
}

class _LibraryTopBarAction extends StatelessWidget {
  const _LibraryTopBarAction({required this.tooltip, required this.onPressed, required this.icon, super.key});

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            onTap: onPressed,
            excludeFromSemantics: true,
            radius: AppSpacing.minimumTouchTarget / 2,
            child: SizedBox(
              width: AppSpacing.minimumTouchTarget,
              height: AppSpacing.minimumTouchTarget,
              child: Center(
                child: Icon(icon, size: AppSpacing.topBarActionIconSize, color: theme.colorScheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
