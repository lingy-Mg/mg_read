/// 首页顶部操作栏。
///
/// 职责：
/// - 展示首页主题切换与更多操作入口。
/// - 将本地导入与低频操作收拢到底部菜单，关闭菜单后转发操作。
///
/// 注意：
/// - 不读取或写入书架数据。
/// - 触控入口保持 48dp 命中区，视觉规格仍来自全局主题。
/// - 菜单遵循安全区与减少动态效果设置，短屏和大字号下允许滚动。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

/// 首页的顶层操作。
class LibraryHomeTopBar extends StatelessWidget {
  const LibraryHomeTopBar({
    required this.onRefresh,
    required this.onReadingHistory,
    required this.onManageSources,
    required this.onPrivacyLibrary,
    required this.layoutMode,
    required this.onLayoutModeToggle,
    this.onToggleTheme,
    this.onImportLocal,
    super.key,
  });

  final VoidCallback onRefresh;
  final VoidCallback? onImportLocal;
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
          const Spacer(),
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
          _LibraryTopBarAction(tooltip: '更多操作', onPressed: () => _showMoreMenu(context), icon: Icons.more_vert_rounded),
        ],
      ),
    );
  }

  Future<void> _showMoreMenu(BuildContext context) async {
    final mode = TvModeScope.maybeOf(context);
    final selected = await showModalBottomSheet<VoidCallback>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: AnimationStyle(
        duration: AppMotion.effectiveDuration(context, AppMotion.destinationTransition),
        reverseDuration: AppMotion.effectiveDuration(context, AppMotion.destinationReverseTransition),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        key: const Key('library-top-overflow-menu'),
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.regular, 0, AppSpacing.regular, AppSpacing.comfortable),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.comfortable, bottom: AppSpacing.compact),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text('更多操作', style: Theme.of(sheetContext).textTheme.titleLarge)),
                    IconButton(tooltip: '关闭菜单', onPressed: () => Navigator.pop(sheetContext), icon: const Icon(Icons.close_rounded)),
                  ],
                ),
              ),
              if (onImportLocal case final importLocal?)
                _LibraryHomeMenuAction(label: '导入本地书籍', icon: Icons.file_open_outlined, onSelected: importLocal, autofocus: true),
              _LibraryHomeMenuAction(label: '刷新书架', icon: Icons.refresh_rounded, onSelected: onRefresh, autofocus: onImportLocal == null),
              _LibraryHomeMenuAction(
                label: layoutMode == LibraryHomeLayoutMode.list ? '切换为卡片模式' : '切换为列表模式',
                icon: layoutMode == LibraryHomeLayoutMode.list ? Icons.grid_view_rounded : Icons.view_list_rounded,
                onSelected: onLayoutModeToggle,
              ),
              const Divider(indent: AppSpacing.comfortable, endIndent: AppSpacing.comfortable, height: AppSpacing.section),
              _LibraryHomeMenuAction(label: '阅读记录', icon: Icons.history_rounded, onSelected: onReadingHistory),
              _LibraryHomeMenuAction(label: '管理数据源', icon: Icons.dns_outlined, onSelected: onManageSources),
              _LibraryHomeMenuAction(label: '隐私书架', icon: Icons.lock_outline_rounded, onSelected: onPrivacyLibrary),
              if (mode != null) _LibraryHomeMenuAction(label: '切换到 TV 模式', icon: Icons.tv_rounded, onSelected: () => mode.onChanged(true)),
            ],
          ),
        ),
      ),
    );
    if (context.mounted) selected?.call();
  }
}

class _LibraryHomeMenuAction extends StatelessWidget {
  const _LibraryHomeMenuAction({required this.label, required this.icon, required this.onSelected, this.autofocus = false});

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => ListTile(
    autofocus: autofocus,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.unit),
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.control),
    leading: Icon(icon, color: AppThemeTokens.of(context).accent),
    title: Text(label),
    onTap: () => Navigator.pop<VoidCallback>(context, onSelected),
  );
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
