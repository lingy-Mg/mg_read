import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_backdrop.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

/// Mobile-first discovery presentation owned by the host UI layer.
///
/// This fixed composition is retained only for presentation and golden tests.
/// Production plugin sections use `RuntimeDiscoveryPage`, which renders every
/// returned section without mapping them into these preview-only slots.
class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({
    required this.onDestinationRequested,
    this.data,
    this.onSourcePressed,
    this.onTabSelected,
    this.onCategorySelected,
    this.onRefreshRequested,
    this.onToggleTheme,
    super.key,
  });

  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final DiscoveryPageViewData? data;
  final VoidCallback? onSourcePressed;
  final ValueChanged<String>? onTabSelected;
  final ValueChanged<String>? onCategorySelected;
  final VoidCallback? onRefreshRequested;
  final VoidCallback? onToggleTheme;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  final ScrollController _scrollController = ScrollController();

  DiscoveryPageViewData get _data => widget.data ?? DiscoveryFixtures.preview;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppPageBackdrop(
        style: AppPageBackdropStyle.discover,
        child: SafeArea(
          bottom: false,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool useWidePagePadding =
                    constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint;
                final double pagePadding = useWidePagePadding
                    ? AppSpacing.widePagePadding
                    : AppSpacing.discoveryPagePadding;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppSpacing.contentMaxWidth,
                    ),
                    child: Scrollbar(
                      controller: _scrollController,
                      child: ListView(
                        key: const Key('discovery-page-content'),
                        controller: _scrollController,
                        primary: false,
                        padding: EdgeInsets.fromLTRB(
                          pagePadding,
                          AppSpacing.pageHeaderTopPadding,
                          pagePadding,
                          AppSpacing.page,
                        ),
                        children: <Widget>[
                          DiscoveryTopBar(
                            sourceName: _data.sourceName,
                            onSourcePressed:
                                widget.onSourcePressed ??
                                _showUnavailableMessage,
                            onSearchPressed: () => _handleDestinationSelected(
                              AppNavigationDestination.search,
                            ),
                            onToggleTheme: () => _handleToggleTheme(context),
                          ),
                          const SizedBox(height: 10),
                          DiscoveryTabs(
                            tabs: _data.tabs,
                            selectedTabId: _data.selectedTabId,
                            onSelected: _handleTabSelected,
                          ),
                          const SizedBox(height: 10),
                          DiscoveryHeroCard(
                            data: _data.hero,
                            onPressed: _showUnavailableMessage,
                          ),
                          const SizedBox(height: AppSpacing.regular),
                          DiscoverySectionHeader(
                            title: _data.popularTitle,
                            actionLabel: '换一换',
                            actionIcon: Icons.refresh_rounded,
                            onAction:
                                widget.onRefreshRequested ??
                                _showUnavailableMessage,
                          ),
                          const SizedBox(height: 7),
                          DiscoveryPopularBooks(
                            books: _data.popularBooks,
                            onBookPressed: (_) => _showUnavailableMessage(),
                          ),
                          const SizedBox(height: AppSpacing.regular),
                          SizedBox(
                            height: AppSpacing.discoveryBoardHeight,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Expanded(
                                  child: DiscoveryRankingBoard(
                                    title: _data.rankingTitle,
                                    books: _data.rankedBooks,
                                    onPressed: (_) => _showUnavailableMessage(),
                                    onMorePressed: _showUnavailableMessage,
                                  ),
                                ),
                                const SizedBox(
                                  width: AppSpacing.discoveryBoardGap,
                                ),
                                Expanded(
                                  child: DiscoveryCategoryBoard(
                                    title: _data.categoryTitle,
                                    categories: _data.categories,
                                    onPressed: _showUnavailableMessage,
                                    onCategoryPressed: _handleCategorySelected,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.compact),
                          DiscoverySectionHeader(
                            title: _data.editorsChoiceTitle,
                            actionLabel: '更多',
                            actionIcon: Icons.chevron_right_rounded,
                            onAction: _showUnavailableMessage,
                          ),
                          const SizedBox(height: AppSpacing.unit),
                          DiscoveryEditorsChoiceCard(
                            data: _data.editorsChoice,
                            onPressed: _showUnavailableMessage,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.discover,
          onSelected: _handleDestinationSelected,
        ),
      ),
    );
  }

  void _handleToggleTheme(BuildContext context) {
    final VoidCallback? callback = widget.onToggleTheme;
    if (callback != null) {
      callback();
      return;
    }
    AppThemeModeScope.of(context).onToggleTheme(Theme.of(context).brightness);
  }

  void _handleDestinationSelected(AppNavigationDestination destination) {
    if (destination == AppNavigationDestination.discover) {
      return;
    }
    widget.onDestinationRequested(destination);
  }

  void _handleTabSelected(DiscoveryTabViewData tab) {
    final callback = widget.onTabSelected;
    if (callback == null) {
      _showUnavailableMessage();
      return;
    }
    callback(tab.target);
  }

  void _handleCategorySelected(DiscoveryCategoryViewData category) {
    final callback = widget.onCategorySelected;
    final target = category.target;
    if (callback == null || target == null) {
      _showUnavailableMessage();
      return;
    }
    callback(target);
  }

  void _showUnavailableMessage() {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('此操作尚未接入真实数据，可由后续功能替换。')));
  }
}

class DiscoveryTopBar extends StatelessWidget {
  const DiscoveryTopBar({
    required this.sourceName,
    required this.onSourcePressed,
    required this.onSearchPressed,
    required this.onToggleTheme,
    this.title = '发现',
    this.onRefreshPressed,
    super.key,
  });

  final String sourceName;
  final VoidCallback onSourcePressed;
  final VoidCallback onSearchPressed;
  final VoidCallback onToggleTheme;
  final String title;
  final VoidCallback? onRefreshPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: AppSpacing.discoveryHeaderHeight,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            left: AppSpacing.discoveryHeaderInset,
            top: 0,
            bottom: 0,
            child: Center(child: AppPageTitle(title: title)),
          ),
          Align(
            alignment: Alignment.center,
            child: DiscoverySourceSelector(
              sourceName: sourceName,
              onPressed: onSourcePressed,
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (AppTheme.darkModeEnabled) ...<Widget>[
                  DiscoveryTopAction(
                    key: const Key('theme-mode-toggle'),
                    tooltip: theme.brightness == Brightness.dark
                        ? '切换至浅色模式'
                        : '切换至深色模式',
                    icon: theme.brightness == Brightness.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    onPressed: onToggleTheme,
                  ),
                  const SizedBox(width: AppSpacing.unit),
                ],
                if (onRefreshPressed != null) ...<Widget>[
                  DiscoveryTopAction(
                    key: const Key('discovery-refresh-action'),
                    tooltip: '刷新发现内容',
                    icon: Icons.refresh_rounded,
                    onPressed: onRefreshPressed!,
                  ),
                  const SizedBox(width: AppSpacing.unit),
                ],
                DiscoveryTopAction(
                  key: const Key('discovery-search-action'),
                  tooltip: '搜索书籍',
                  icon: Icons.search_rounded,
                  onPressed: onSearchPressed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DiscoverySourceSelector extends StatelessWidget {
  const DiscoverySourceSelector({
    required this.sourceName,
    required this.onPressed,
    this.selectorKey,
    this.label = '选择数据源',
    super.key,
  });

  final String sourceName;
  final VoidCallback onPressed;
  final Key? selectorKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: selectorKey ?? const Key('discovery-source-selector'),
            onTap: onPressed,
            borderRadius: AppRadii.pill,
            child: Container(
              width: 104,
              height: 28,
              padding: const EdgeInsets.only(left: 9, right: 7),
              decoration: BoxDecoration(
                color: tokens.mutedSurface,
                borderRadius: AppRadii.pill,
                border: Border.all(color: tokens.divider, width: 0.8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      sourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurface,
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

class DiscoveryTopAction extends StatelessWidget {
  const DiscoveryTopAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

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
            radius: AppSpacing.topBarActionSize / 2,
            child: SizedBox.square(
              dimension: AppSpacing.topBarActionSize,
              child: Icon(icon, size: 21, color: theme.colorScheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

class DiscoveryTabs extends StatelessWidget {
  const DiscoveryTabs({
    required this.tabs,
    required this.selectedTabId,
    required this.onSelected,
    super.key,
  });

  final List<DiscoveryTabViewData> tabs;
  final String? selectedTabId;
  final ValueChanged<DiscoveryTabViewData> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('discovery-tabs'),
      height: AppSpacing.discoveryTabsHeight,
      child: Row(
        children: <Widget>[
          for (final tab in tabs.take(6))
            Expanded(
              child: DiscoveryTab(
                label: tab.label,
                selected: tab.id == selectedTabId,
                onPressed: () => onSelected(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class DiscoveryTab extends StatelessWidget {
  const DiscoveryTab({
    required this.label,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color foreground = selected ? tokens.accent : tokens.mutedText;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          key: ValueKey<String>('discovery-tab-$label'),
          onTap: onPressed,
          radius: AppSpacing.minimumTouchTarget / 2,
          child: Column(
            children: <Widget>[
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  height: 1.25,
                  letterSpacing: 0,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 18,
                height: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? tokens.accent : Colors.transparent,
                    borderRadius: AppRadii.pill,
                  ),
                ),
              ),
              const SizedBox(height: 2),
            ],
          ),
        ),
      ),
    );
  }
}

class DiscoveryHeroCard extends StatelessWidget {
  const DiscoveryHeroCard({
    required this.data,
    required this.onPressed,
    super.key,
  });

  final DiscoveryHeroViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '打开书籍：${data.title}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('discovery-hero-card'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryHero,
          child: Ink(
            height: AppSpacing.discoveryHeroHeight,
            decoration: BoxDecoration(
              borderRadius: AppRadii.discoveryHero,
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: <Color>[
                  tokens.accentSoft,
                  tokens.featureSurface.withValues(alpha: 0.82),
                ],
              ),
            ),
            child: ClipRRect(
              borderRadius: AppRadii.discoveryHero,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    right: 47,
                    top: -46,
                    child: Container(
                      width: 184,
                      height: 184,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: tokens.accent.withValues(alpha: 0.09),
                          width: 14,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 18,
                    top: 18,
                    width: 188,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                data.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                            if (data.category != null) ...<Widget>[
                              const SizedBox(width: 8),
                              DiscoveryTag(label: data.category!),
                            ],
                          ],
                        ),
                        if (data.description != null) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            data.description!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.78,
                              ),
                              fontWeight: FontWeight.w400,
                              height: 1.48,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                        if (data.metadata != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            data.metadata!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: tokens.mutedText,
                              fontWeight: FontWeight.w400,
                              height: 1.2,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: AppSpacing.discoveryReadButtonWidth,
                          height: AppSpacing.discoveryReadButtonHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: tokens.accent,
                              borderRadius: AppRadii.discoveryButton,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: tokens.accent.withValues(alpha: 0.2),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                '立即阅读',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                  height: 1.1,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 34,
                    top: 10,
                    child: DiscoveryBookCover(
                      title: data.title,
                      variant: data.coverVariant,
                      width: AppSpacing.discoveryHeroCoverWidth,
                      height: AppSpacing.discoveryHeroCoverHeight,
                    ),
                  ),
                  const Positioned(
                    left: 137,
                    bottom: 9,
                    child: DiscoveryCarouselDots(),
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

class DiscoveryTag extends StatelessWidget {
  const DiscoveryTag({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(alpha: 0.68),
        borderRadius: AppRadii.pill,
        border: Border.all(color: tokens.accent.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: tokens.warning,
            fontWeight: FontWeight.w400,
            height: 1,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class DiscoveryCarouselDots extends StatelessWidget {
  const DiscoveryCarouselDots({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      label: '精选推荐轮播，第 1 张，共 5 张',
      child: ExcludeSemantics(
        child: Row(
          children: <Widget>[
            for (int index = 0; index < 5; index += 1) ...<Widget>[
              Container(
                width: index == 0 ? 5 : 4,
                height: index == 0 ? 5 : 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index == 0
                      ? theme.colorScheme.onSurface
                      : tokens.mutedText.withValues(alpha: 0.24),
                ),
              ),
              if (index != 4) const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class DiscoverySectionHeader extends StatelessWidget {
  const DiscoverySectionHeader({
    required this.title,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    super.key,
  });

  final String title;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 24,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: actionLabel,
            child: InkResponse(
              onTap: onAction,
              radius: AppSpacing.minimumTouchTarget / 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    actionLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.mutedText,
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(actionIcon, size: 15, color: tokens.mutedText),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DiscoveryPopularBooks extends StatelessWidget {
  const DiscoveryPopularBooks({
    required this.books,
    required this.onBookPressed,
    super.key,
  });

  final List<DiscoveryBookViewData> books;
  final ValueChanged<DiscoveryBookViewData> onBookPressed;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: const Key('discovery-popular-books'),
      constraints: const BoxConstraints(minHeight: 120),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: books
            .take(5)
            .map(
              (DiscoveryBookViewData book) => DiscoveryPopularBook(
                data: book,
                onPressed: () => onBookPressed(book),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class DiscoveryPopularBook extends StatelessWidget {
  const DiscoveryPopularBook({
    required this.data,
    required this.onPressed,
    super.key,
  });

  final DiscoveryBookViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: data.author == null
          ? '打开书籍：${data.title}'
          : '打开书籍：${data.title}，${data.author}',
      child: InkResponse(
        onTap: onPressed,
        radius: AppSpacing.minimumTouchTarget / 2,
        child: SizedBox(
          width: AppSpacing.discoveryPopularItemWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DiscoveryBookCover(
                title: data.title,
                variant: data.coverVariant,
                width: AppSpacing.discoveryPopularCoverWidth,
                height: AppSpacing.discoveryPopularCoverHeight,
              ),
              const SizedBox(height: 4),
              Text(
                data.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w400,
                  height: 1.2,
                  letterSpacing: 0,
                ),
              ),
              if (data.author != null) ...<Widget>[
                const SizedBox(height: 1),
                Text(
                  data.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DiscoveryRankingBoard extends StatelessWidget {
  const DiscoveryRankingBoard({
    required this.title,
    required this.books,
    required this.onPressed,
    required this.onMorePressed,
    super.key,
  });

  final String title;
  final List<DiscoveryRankedBookViewData> books;
  final ValueChanged<DiscoveryRankedBookViewData> onPressed;
  final VoidCallback onMorePressed;

  @override
  Widget build(BuildContext context) {
    return DiscoveryBoardSurface(
      key: const Key('discovery-ranking-board'),
      child: Column(
        children: <Widget>[
          DiscoveryBoardHeader(title: title, onPressed: onMorePressed),
          const SizedBox(height: 4),
          for (final DiscoveryRankedBookViewData book in books.take(5))
            Expanded(
              child: DiscoveryRankingRow(
                data: book,
                onPressed: () => onPressed(book),
              ),
            ),
        ],
      ),
    );
  }
}

class DiscoveryRankingRow extends StatelessWidget {
  const DiscoveryRankingRow({
    required this.data,
    required this.onPressed,
    super.key,
  });

  final DiscoveryRankedBookViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color rankColor = switch (data.rank) {
      1 => tokens.notification,
      2 || 3 => tokens.accent,
      _ => tokens.mutedText,
    };
    return Semantics(
      button: true,
      label: <String>[
        if (data.rank != null) '第 ${data.rank} 名',
        data.title,
        if (data.author != null) data.author!,
        if (data.heat != null) data.heat!,
      ].join('，'),
      child: InkResponse(
        onTap: onPressed,
        radius: AppSpacing.minimumTouchTarget / 2,
        child: Row(
          children: <Widget>[
            DiscoveryBookCover(
              title: data.title,
              variant: data.coverVariant,
              width: AppSpacing.discoveryRankCoverWidth,
              height: AppSpacing.discoveryRankCoverHeight,
            ),
            const SizedBox(width: 6),
            if (data.rank != null) ...<Widget>[
              SizedBox(
                width: 12,
                child: Text(
                  '${data.rank}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: rankColor,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 3),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                      letterSpacing: 0,
                    ),
                  ),
                  if (data.author != null) ...<Widget>[
                    const SizedBox(height: 1),
                    Text(
                      data.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (data.heat != null) ...<Widget>[
              const SizedBox(width: 2),
              Icon(
                Icons.local_fire_department_rounded,
                size: 10,
                color: tokens.notification,
              ),
              const SizedBox(width: 1),
              Text(
                data.heat!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.mutedText,
                  fontWeight: FontWeight.w400,
                  height: 1.1,
                  letterSpacing: 0,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DiscoveryCategoryBoard extends StatelessWidget {
  const DiscoveryCategoryBoard({
    required this.title,
    required this.categories,
    required this.onPressed,
    this.onCategoryPressed,
    super.key,
  });

  final String title;
  final List<DiscoveryCategoryViewData> categories;
  final VoidCallback onPressed;
  final ValueChanged<DiscoveryCategoryViewData>? onCategoryPressed;

  @override
  Widget build(BuildContext context) {
    final List<DiscoveryCategoryViewData> visible = categories
        .take(8)
        .toList(growable: false);
    return DiscoveryBoardSurface(
      key: const Key('discovery-category-board'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columnCount = discoveryAdaptiveColumnCount(
            constraints.maxWidth,
            visible.length,
          );
          final double gap = AppSpacing.discoveryCategoryTileGap;
          final double tileWidth =
              (constraints.maxWidth - gap * (columnCount - 1)) / columnCount;
          return Column(
            children: <Widget>[
              DiscoveryBoardHeader(title: title, onPressed: onPressed),
              const SizedBox(height: 6),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: visible
                    .map(
                      (category) => SizedBox(
                        width: tileWidth,
                        child: DiscoveryCategoryTile(
                          key: ValueKey<String>(
                            'discovery-category-${category.target ?? category.title}',
                          ),
                          data: category,
                          onPressed: () => _handleCategory(category),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          );
        },
      ),
    );
  }

  void _handleCategory(DiscoveryCategoryViewData category) {
    final callback = onCategoryPressed;
    if (callback == null) {
      onPressed();
      return;
    }
    callback(category);
  }
}

/// Returns the number of equal category controls that fit the available width.
///
/// Two columns remain the compact reference layout. Wider boards gain columns
/// only when each control can retain the same minimum readable width.
int discoveryAdaptiveColumnCount(double maxWidth, int itemCount) {
  if (itemCount <= 0) return 1;
  final int estimated =
      ((maxWidth + AppSpacing.discoveryCategoryTileGap) /
              (AppSpacing.discoveryCategoryTileMinWidth +
                  AppSpacing.discoveryCategoryTileGap))
          .floor();
  return math.max(2, math.min(itemCount, estimated));
}

class DiscoveryCategoryTile extends StatelessWidget {
  const DiscoveryCategoryTile({
    required this.data,
    required this.onPressed,
    super.key,
  });

  final DiscoveryCategoryViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color iconColor = _categoryColor(data.icon, tokens);
    return Semantics(
      button: true,
      label: data.count == null ? data.title : '${data.title}，${data.count}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.discoveryTile,
          child: Ink(
            height: AppSpacing.discoveryCategoryTileHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: tokens.surface.withValues(alpha: 0.82),
              borderRadius: AppRadii.discoveryTile,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(
                      alpha: theme.brightness == Brightness.dark ? 0.24 : 0.12,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _categoryIcon(data.icon),
                    size: 14,
                    color: iconColor,
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                          height: 1.1,
                          letterSpacing: 0,
                        ),
                      ),
                      if (data.count != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          data.count!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.mutedText,
                            fontWeight: FontWeight.w400,
                            height: 1,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _categoryIcon(DiscoveryCategoryIcon icon) {
    return switch (icon) {
      DiscoveryCategoryIcon.fantasy => Icons.auto_awesome_rounded,
      DiscoveryCategoryIcon.adventure => Icons.gavel_rounded,
      DiscoveryCategoryIcon.martialArts => Icons.sports_martial_arts_rounded,
      DiscoveryCategoryIcon.xianxia => Icons.colorize_rounded,
      DiscoveryCategoryIcon.urban => Icons.apartment_rounded,
      DiscoveryCategoryIcon.history => Icons.fort_rounded,
      DiscoveryCategoryIcon.game => Icons.stadium_rounded,
      DiscoveryCategoryIcon.sciFi => Icons.rocket_launch_rounded,
    };
  }

  Color _categoryColor(DiscoveryCategoryIcon icon, AppThemeTokens tokens) {
    return switch (icon) {
      DiscoveryCategoryIcon.urban ||
      DiscoveryCategoryIcon.game ||
      DiscoveryCategoryIcon.sciFi => tokens.coverOceanEnd,
      DiscoveryCategoryIcon.history => tokens.coverEmberEnd,
      _ => tokens.warning,
    };
  }
}

class DiscoveryBoardSurface extends StatelessWidget {
  const DiscoveryBoardSurface({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.discoveryPanel,
        border: Border.all(
          color: tokens.divider.withValues(alpha: 0.72),
          width: 0.6,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 9, 8, 8),
        child: child,
      ),
    );
  }
}

class DiscoveryBoardHeader extends StatelessWidget {
  const DiscoveryBoardHeader({
    required this.title,
    required this.onPressed,
    super.key,
  });

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 22,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          InkResponse(
            onTap: onPressed,
            radius: AppSpacing.minimumTouchTarget / 2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '更多',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.1,
                    letterSpacing: 0,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: tokens.mutedText,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DiscoveryEditorsChoiceCard extends StatelessWidget {
  const DiscoveryEditorsChoiceCard({
    required this.data,
    required this.onPressed,
    super.key,
  });

  final DiscoveryEditorsChoiceViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '打开书籍：${data.title}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('discovery-editors-choice'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryPanel,
          child: Ink(
            height: AppSpacing.discoveryEditorCardHeight,
            decoration: BoxDecoration(
              color: tokens.mutedSurface,
              borderRadius: AppRadii.discoveryPanel,
            ),
            child: ClipRRect(
              borderRadius: AppRadii.discoveryPanel,
              child: Row(
                children: <Widget>[
                  DiscoveryBookCover(
                    title: data.title,
                    variant: data.coverVariant,
                    width: AppSpacing.discoveryEditorCoverWidth,
                    height: AppSpacing.discoveryEditorCoverHeight,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 9, 7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  data.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                    height: 1.15,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                              if (data.category != null) ...<Widget>[
                                const SizedBox(width: 7),
                                DiscoveryTag(label: data.category!),
                              ],
                            ],
                          ),
                          if (data.description != null) ...<Widget>[
                            const SizedBox(height: 4),
                            Text(
                              data.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.76,
                                ),
                                fontWeight: FontWeight.w400,
                                height: 1.28,
                                letterSpacing: 0,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (data.metadata != null)
                            Text(
                              data.metadata!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: tokens.mutedText,
                                fontWeight: FontWeight.w400,
                                height: 1.1,
                                letterSpacing: 0,
                              ),
                            ),
                        ],
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
