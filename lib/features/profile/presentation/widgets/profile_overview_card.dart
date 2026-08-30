import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';

/// The compact local profile summary rendered at the top of the profile page.
class ProfileOverviewCard extends StatelessWidget {
  /// Creates a profile card from the supplied presentation fixture.
  const ProfileOverviewCard({required this.data, required this.onEdit, required this.onSyncPressed, super.key});

  final ProfileViewData data;
  final VoidCallback onEdit;
  final VoidCallback onSyncPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return Semantics(
      container: true,
      label: '${data.displayName}，${data.motto}',
      child: SizedBox(
        key: const Key('profile-overview-card'),
        height: AppSpacing.profileCardHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: AppRadii.card,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[tokens.featureSurface, tokens.surface.withValues(alpha: 0.95)],
            ),
            border: Border.all(color: tokens.divider.withValues(alpha: 0.72)),
          ),
          child: ClipRRect(
            borderRadius: AppRadii.card,
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: AppSpacing.profileSummaryHeight,
                  child: Stack(
                    children: <Widget>[
                      Positioned(
                        top: AppSpacing.comfortable - 1,
                        left: AppSpacing.profileCardHorizontalPadding,
                        child: const _ProfileAvatar(),
                      ),
                      Positioned(
                        top: AppSpacing.profileNameTop,
                        left: AppSpacing.profileCardHorizontalPadding + AppSpacing.profileAvatarSize + AppSpacing.comfortable,
                        right: AppSpacing.profileEditReservedWidth,
                        child: _ProfileName(data: data, theme: theme, tokens: tokens),
                      ),
                      Positioned(
                        top: AppSpacing.profileMottoTop,
                        left: AppSpacing.profileCardHorizontalPadding + AppSpacing.profileAvatarSize + AppSpacing.comfortable,
                        right: AppSpacing.profileCardHorizontalPadding,
                        child: Text(
                          data.motto,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w400, height: 1.2, color: tokens.mutedText),
                        ),
                      ),
                      Positioned(
                        top: AppSpacing.comfortable + AppSpacing.unit,
                        right: AppSpacing.profileCardHorizontalPadding,
                        child: _ProfileEditButton(onPressed: onEdit),
                      ),
                      Positioned(
                        top: AppSpacing.profileStatsTop,
                        left: AppSpacing.comfortable,
                        right: AppSpacing.comfortable,
                        child: _ProfileStats(data: data, theme: theme, tokens: tokens),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.featureSurface.withValues(alpha: 0.52),
                      border: Border(top: BorderSide(color: tokens.divider.withValues(alpha: 0.72))),
                    ),
                    child: _ProfileSyncRow(data: data, onPressed: onSyncPressed, theme: theme, tokens: tokens),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '本地资料头像',
      image: true,
      child: ExcludeSemantics(
        child: ClipOval(
          child: Image.asset(
            'assets/profile/profile-traveler-avatar.webp',
            width: AppSpacing.profileAvatarSize,
            height: AppSpacing.profileAvatarSize,
            fit: BoxFit.cover,
            cacheWidth: 120,
            cacheHeight: 120,
            filterQuality: FilterQuality.medium,
            semanticLabel: '本地资料头像',
            errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) {
              return const ColoredBox(color: Color(0xFFEDE7DE));
            },
          ),
        ),
      ),
    );
  }
}

class _ProfileName extends StatelessWidget {
  const _ProfileName({required this.data, required this.theme, required this.tokens});

  final ProfileViewData data;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            data.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.05, letterSpacing: -0.2),
          ),
        ),
        const SizedBox(width: AppSpacing.compact),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: AppRadii.pill,
            gradient: LinearGradient(colors: <Color>[tokens.accent.withValues(alpha: 0.78), tokens.warning]),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit + 1, vertical: AppSpacing.unit / 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.workspace_premium_rounded, size: 10, color: Theme.of(context).colorScheme.onPrimary),
                const SizedBox(width: 2),
                Text(
                  'VIP',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileEditButton extends StatelessWidget {
  const _ProfileEditButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '编辑资料',
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: AppSpacing.profileEditHeight,
          padding: const EdgeInsets.only(
            left: AppSpacing.regular,
            right: AppSpacing.compact,
            top: AppSpacing.compact - 2,
            bottom: AppSpacing.compact - 2,
          ),
          decoration: BoxDecoration(color: tokens.accentSoft.withValues(alpha: 0.8), borderRadius: AppRadii.pill),
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadii.control,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '编辑资料',
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.warning, fontWeight: FontWeight.w500, height: 1),
                  ),
                  Icon(Icons.chevron_right_rounded, color: tokens.mutedText, size: AppSpacing.profileChevronSize),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileStats extends StatelessWidget {
  const _ProfileStats({required this.data, required this.theme, required this.tokens});

  final ProfileViewData data;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List<Widget>.generate(data.stats.length, (int index) {
        final ProfileStatViewData stat = data.stats[index];
        return Expanded(
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      stat.label,
                      style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.1),
                    ),
                    const SizedBox(height: AppSpacing.unit),
                    Text(stat.value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.1)),
                  ],
                ),
              ),
              if (index < data.stats.length - 1)
                SizedBox(
                  height: AppSpacing.profileStatsDividerHeight,
                  child: VerticalDivider(
                    width: 1,
                    thickness: AppSpacing.profileStatsDividerThickness,
                    color: tokens.divider.withValues(alpha: 0.62),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

class _ProfileSyncRow extends StatelessWidget {
  const _ProfileSyncRow({required this.data, required this.onPressed, required this.theme, required this.tokens});

  final ProfileViewData data;
  final VoidCallback onPressed;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${data.syncLabel}，${data.lastSyncLabel}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.profileCardHorizontalPadding),
            child: Row(
              children: <Widget>[
                Icon(Icons.cloud_done_outlined, color: tokens.warning, size: AppSpacing.profileSyncIconSize),
                const SizedBox(width: AppSpacing.compact),
                Expanded(
                  child: Text(
                    data.syncLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.warning, fontWeight: FontWeight.w500, height: 1.1),
                  ),
                ),
                Text(
                  data.lastSyncLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.1),
                ),
                const SizedBox(width: AppSpacing.unit),
                Icon(Icons.chevron_right_rounded, color: tokens.mutedText, size: AppSpacing.profileChevronSize),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
