part of 'discovery_page.dart';

/// Popular book cards and ranking board composition.
class DiscoveryPopularBook extends StatelessWidget {
  const DiscoveryPopularBook({required this.data, required this.onPressed, super.key});

  final DiscoveryBookViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: data.author == null ? '打开书籍：${data.title}' : '打开书籍：${data.title}，${data.author}',
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
                contentKind: data.contentKind,
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
  const DiscoveryRankingBoard({required this.title, required this.books, required this.onPressed, required this.onMorePressed, super.key});

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
              child: DiscoveryRankingRow(data: book, onPressed: () => onPressed(book)),
            ),
        ],
      ),
    );
  }
}

class DiscoveryRankingRow extends StatelessWidget {
  const DiscoveryRankingRow({required this.data, required this.onPressed, super.key});

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
              contentKind: data.contentKind,
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
                  style: theme.textTheme.bodySmall?.copyWith(color: rankColor, fontWeight: FontWeight.w600, height: 1.1, letterSpacing: 0),
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
              Icon(Icons.local_fire_department_rounded, size: 10, color: tokens.notification),
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
