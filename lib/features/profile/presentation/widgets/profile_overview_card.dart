import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';

/// The compact, non-persistent profile summary rendered at the top of the
/// profile page.
class ProfileOverviewCard extends StatelessWidget {
  /// Creates a profile card from the supplied presentation fixture.
  const ProfileOverviewCard({
    required this.data,
    required this.onEdit,
    required this.onSyncPressed,
    super.key,
  });

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
              colors: <Color>[
                tokens.featureSurface,
                tokens.surface.withValues(alpha: 0.95),
              ],
            ),
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
                        left: AppSpacing.compactPagePadding,
                        child: _ProfileAvatar(tokens: tokens),
                      ),
                      Positioned(
                        top: AppSpacing.profileNameTop,
                        left:
                            AppSpacing.compactPagePadding +
                            AppSpacing.profileAvatarSize +
                            AppSpacing.comfortable,
                        right: 92,
                        child: _ProfileName(
                          data: data,
                          theme: theme,
                          tokens: tokens,
                        ),
                      ),
                      Positioned(
                        top: AppSpacing.profileMottoTop,
                        left:
                            AppSpacing.compactPagePadding +
                            AppSpacing.profileAvatarSize +
                            AppSpacing.comfortable,
                        right: AppSpacing.comfortable,
                        child: Text(
                          data.motto,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            height: 1.2,
                            color: tokens.mutedText,
                          ),
                        ),
                      ),
                      Positioned(
                        top: AppSpacing.comfortable + AppSpacing.unit,
                        right: AppSpacing.comfortable,
                        child: _ProfileEditButton(onPressed: onEdit),
                      ),
                      Positioned(
                        top: AppSpacing.profileStatsTop,
                        left: AppSpacing.comfortable,
                        right: AppSpacing.comfortable,
                        child: _ProfileStats(
                          data: data,
                          theme: theme,
                          tokens: tokens,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.featureSurface.withValues(alpha: 0.72),
                      border: Border(top: BorderSide(color: tokens.divider)),
                    ),
                    child: _ProfileSyncRow(
                      data: data,
                      onPressed: onSyncPressed,
                      theme: theme,
                      tokens: tokens,
                    ),
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
  const _ProfileAvatar({required this.tokens});

  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '书海行者的头像',
      image: true,
      child: ExcludeSemantics(
        child: ClipOval(
          child: SizedBox(
            width: AppSpacing.profileAvatarSize,
            height: AppSpacing.profileAvatarSize,
            child: CustomPaint(painter: _ProfileAvatarPainter(tokens: tokens)),
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatarPainter extends CustomPainter {
  const _ProfileAvatarPainter({required this.tokens});

  final AppThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            tokens.mutedSurface,
            tokens.surface.withValues(alpha: 0.82),
          ],
        ).createShader(bounds),
    );

    final Paint moon = Paint()..color = tokens.surface.withValues(alpha: 0.65);
    canvas.drawCircle(
      Offset(size.width * .31, size.height * .25),
      size.width * .2,
      moon,
    );

    final Paint farMountain = Paint()
      ..color = tokens.mutedText.withValues(alpha: 0.35);
    final Path far = Path()
      ..moveTo(0, size.height * .74)
      ..lineTo(size.width * .22, size.height * .45)
      ..lineTo(size.width * .42, size.height * .67)
      ..lineTo(size.width * .67, size.height * .34)
      ..lineTo(size.width, size.height * .62)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(far, farMountain);

    final Paint foreground = Paint()
      ..color = tokens.mutedText.withValues(alpha: 0.6);
    final Path near = Path()
      ..moveTo(0, size.height * .85)
      ..lineTo(size.width * .25, size.height * .6)
      ..lineTo(size.width * .5, size.height * .78)
      ..lineTo(size.width * .78, size.height * .53)
      ..lineTo(size.width, size.height * .72)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(near, foreground);

    final Paint figure = Paint()..color = const Color(0xFF161615);
    final double center = size.width * .58;
    canvas.drawCircle(
      Offset(center, size.height * .35),
      size.width * .07,
      figure,
    );
    final Path hat = Path()
      ..moveTo(center - size.width * .17, size.height * .33)
      ..lineTo(center, size.height * .23)
      ..lineTo(center + size.width * .17, size.height * .33)
      ..close();
    canvas.drawPath(hat, figure);
    final Path robe = Path()
      ..moveTo(center - size.width * .09, size.height * .42)
      ..lineTo(center + size.width * .08, size.height * .42)
      ..lineTo(center + size.width * .17, size.height * .8)
      ..lineTo(center - size.width * .17, size.height * .8)
      ..close();
    canvas.drawPath(robe, figure);
    canvas.drawLine(
      Offset(center + size.width * .12, size.height * .48),
      Offset(center + size.width * .22, size.height * .76),
      Paint()
        ..color = tokens.accent.withValues(alpha: .8)
        ..strokeWidth = math.max(1, size.width * .025),
    );
  }

  @override
  bool shouldRepaint(covariant _ProfileAvatarPainter oldDelegate) {
    return oldDelegate.tokens != tokens;
  }
}

class _ProfileName extends StatelessWidget {
  const _ProfileName({
    required this.data,
    required this.theme,
    required this.tokens,
  });

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
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              height: 1.1,
              letterSpacing: -0.25,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.compact),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: AppRadii.pill,
            gradient: LinearGradient(
              colors: <Color>[
                tokens.accent.withValues(alpha: 0.78),
                tokens.warning,
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.unit + 1,
              vertical: AppSpacing.unit / 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.workspace_premium_rounded,
                  size: 10,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
                const SizedBox(width: 2),
                Text(
                  'VIP',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: 10,
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
          width: AppSpacing.profileEditWidth,
          height: AppSpacing.sectionControlHeight,
          decoration: BoxDecoration(
            color: tokens.accentSoft.withValues(alpha: 0.8),
            borderRadius: AppRadii.control,
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadii.control,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '编辑资料',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1,
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 14),
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
  const _ProfileStats({
    required this.data,
    required this.theme,
    required this.tokens,
  });

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
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.unit),
                    Text(
                      stat.value,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 21,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              if (index < data.stats.length - 1)
                SizedBox(
                  height: AppSpacing.section,
                  child: VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: tokens.divider,
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
  const _ProfileSyncRow({
    required this.data,
    required this.onPressed,
    required this.theme,
    required this.tokens,
  });

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
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.comfortable,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.cloud_done_outlined,
                  color: tokens.warning,
                  size: 24,
                ),
                const SizedBox(width: AppSpacing.compact),
                Expanded(
                  child: Text(
                    data.syncLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.warning,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.1,
                    ),
                  ),
                ),
                Text(
                  data.lastSyncLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: tokens.mutedText,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    height: 1.1,
                  ),
                ),
                const SizedBox(width: AppSpacing.unit),
                Icon(
                  Icons.chevron_right_rounded,
                  color: tokens.mutedText,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
