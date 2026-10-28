part of 'discovery_page.dart';

/// Editor-selected feature card used by the preview discovery composition.

class DiscoveryEditorsChoiceCard extends StatelessWidget {
  const DiscoveryEditorsChoiceCard({required this.data, required this.onPressed, super.key});

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
            decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.discoveryPanel),
            child: ClipRRect(
              borderRadius: AppRadii.discoveryPanel,
              child: Row(
                children: <Widget>[
                  DiscoveryBookCover(
                    title: data.title,
                    contentKind: data.contentKind,
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
                              if (data.category != null) ...<Widget>[const SizedBox(width: 7), DiscoveryTag(label: data.category!)],
                            ],
                          ),
                          if (data.description != null) ...<Widget>[
                            const SizedBox(height: 4),
                            Flexible(
                              child: Text(
                                data.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
                                  fontWeight: FontWeight.w400,
                                  height: 1.28,
                                  letterSpacing: 0,
                                ),
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
