part of 'discovery_page.dart';

/// Category board tiles and shared board framing used by discovery sections.
class DiscoveryCategoryBoard extends StatelessWidget {
  const DiscoveryCategoryBoard({required this.title, required this.categories, required this.onPressed, this.onCategoryPressed, super.key});

  final String title;
  final List<DiscoveryCategoryViewData> categories;
  final VoidCallback onPressed;
  final ValueChanged<DiscoveryCategoryViewData>? onCategoryPressed;

  @override
  Widget build(BuildContext context) {
    final List<DiscoveryCategoryViewData> visible = categories.take(8).toList(growable: false);
    return DiscoveryBoardSurface(
      key: const Key('discovery-category-board'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columnCount = discoveryAdaptiveColumnCount(constraints.maxWidth, visible.length);
          final double gap = AppSpacing.discoveryCategoryTileGap;
          final double tileWidth = (constraints.maxWidth - gap * (columnCount - 1)) / columnCount;
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
                          key: ValueKey<String>('discovery-category-${category.target ?? category.title}'),
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
      ((maxWidth + AppSpacing.discoveryCategoryTileGap) / (AppSpacing.discoveryCategoryTileMinWidth + AppSpacing.discoveryCategoryTileGap))
          .floor();
  return math.max(2, math.min(itemCount, estimated));
}

class DiscoveryCategoryTile extends StatelessWidget {
  const DiscoveryCategoryTile({required this.data, required this.onPressed, super.key});

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
            decoration: BoxDecoration(color: tokens.surface.withValues(alpha: 0.82), borderRadius: AppRadii.discoveryTile),
            child: Row(
              children: <Widget>[
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: theme.brightness == Brightness.dark ? 0.24 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_categoryIcon(data.icon), size: 14, color: iconColor),
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
      DiscoveryCategoryIcon.urban || DiscoveryCategoryIcon.game || DiscoveryCategoryIcon.sciFi => tokens.coverOceanEnd,
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
        border: Border.all(color: tokens.divider.withValues(alpha: 0.72), width: 0.6),
      ),
      child: Padding(padding: const EdgeInsets.fromLTRB(8, 9, 8, 8), child: child),
    );
  }
}

class DiscoveryBoardHeader extends StatelessWidget {
  const DiscoveryBoardHeader({required this.title, required this.onPressed, super.key});

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
                Icon(Icons.chevron_right_rounded, size: 14, color: tokens.mutedText),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
