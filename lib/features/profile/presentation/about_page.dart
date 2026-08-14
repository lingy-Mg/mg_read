import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Reference-matched, presentation-only information about the application.
///
/// Update checks, legal documents, licenses, and contact capabilities remain
/// unavailable until a versioned application/Runtime facade exposes them.
class AboutPage extends StatelessWidget {
  const AboutPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final double systemTopInset = MediaQuery.paddingOf(context).top;
    final double supplementaryTopInset =
        systemTopInset < AppDetailMetrics.minimumTopInset
        ? AppDetailMetrics.minimumTopInset - systemTopInset
        : 0;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.only(top: supplementaryTopInset),
        child: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppDetailMetrics.viewportWidth,
              ),
              child: SizedBox.expand(
                child: ListView(
                  key: const Key('about-page-content'),
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    ProfileDetailTopBar(title: '关于我们', onBack: onBackRequested),
                    const SizedBox(height: AppDetailMetrics.aboutIconTopGap),
                    const Align(child: _AboutAppIcon()),
                    const SizedBox(height: 15),
                    Text(
                      '统一阅读',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        letterSpacing: -0.35,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '版本 1.2.0',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: tokens.mutedText,
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '书山有路勤为径，阅读点亮生活。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: AppDetailMetrics.aboutCardTopGap),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppDetailMetrics.horizontalPadding,
                      ),
                      child: _AboutSettingsCard(
                        onItemPressed: () => _showUnavailable(context),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '© 2018–2024 统一阅读',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '保留所有权利',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: ProfileDetailBottomBar(
        onSelected: onDestinationRequested,
      ),
    );
  }

  void _showUnavailable(BuildContext context) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('相关内容尚未接入，当前不会打开网络或外部页面。')));
  }
}

class _AboutAppIcon extends StatelessWidget {
  const _AboutAppIcon();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      image: true,
      label: '统一阅读开书图标',
      child: ExcludeSemantics(
        child: Container(
          key: const Key('about-app-icon'),
          width: AppDetailMetrics.aboutIconExtent,
          height: AppDetailMetrics.aboutIconExtent,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            borderRadius: AppRadii.detailAppIcon,
            border: Border.all(
              color: tokens.warning.withValues(alpha: 0.16),
              width: 0.8,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color.alphaBlend(
                  tokens.featureSurface.withValues(alpha: 0.78),
                  tokens.surface,
                ),
                Color.lerp(tokens.featureSurface, tokens.warning, 0.015)!,
              ],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: tokens.shadow.withValues(alpha: 0.14),
                blurRadius: 15,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: CustomPaint(painter: _OpenBookLogoPainter(tokens)),
        ),
      ),
    );
  }
}

class _OpenBookLogoPainter extends CustomPainter {
  const _OpenBookLogoPainter(this.tokens);

  final AppThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final Color gold = tokens.warning;
    final Color warmGold = tokens.accent;
    final double centerX = size.width / 2;

    final Paint shadowPaint = Paint()
      ..color = tokens.shadow.withValues(alpha: 0.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final Path shadow = Path()
      ..moveTo(5, size.height * 0.31)
      ..quadraticBezierTo(
        size.width * 0.28,
        size.height * 0.25,
        centerX,
        size.height * 0.45,
      )
      ..quadraticBezierTo(
        size.width * 0.72,
        size.height * 0.25,
        size.width - 5,
        size.height * 0.31,
      )
      ..lineTo(size.width - 5, size.height * 0.82)
      ..quadraticBezierTo(
        size.width * 0.72,
        size.height * 0.78,
        centerX,
        size.height * 0.92,
      )
      ..quadraticBezierTo(
        size.width * 0.28,
        size.height * 0.78,
        5,
        size.height * 0.82,
      )
      ..close();
    canvas.drawPath(shadow.shift(const Offset(0, 3)), shadowPaint);

    final Paint backingPaint = Paint()..color = gold;
    canvas.drawPath(shadow, backingPaint);

    final Paint pagePaint = Paint()..color = tokens.surface;
    final Paint pageOutline = Paint()
      ..color = warmGold.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;

    final Path leftPage = Path()
      ..moveTo(8, size.height * 0.12)
      ..quadraticBezierTo(
        size.width * 0.27,
        size.height * 0.08,
        centerX - 1,
        size.height * 0.4,
      )
      ..lineTo(centerX - 1, size.height * 0.83)
      ..quadraticBezierTo(
        size.width * 0.28,
        size.height * 0.67,
        8,
        size.height * 0.72,
      )
      ..close();
    final Path rightPage = Path()
      ..moveTo(centerX + 1, size.height * 0.4)
      ..quadraticBezierTo(
        size.width * 0.73,
        size.height * 0.08,
        size.width - 8,
        size.height * 0.12,
      )
      ..lineTo(size.width - 8, size.height * 0.72)
      ..quadraticBezierTo(
        size.width * 0.72,
        size.height * 0.67,
        centerX + 1,
        size.height * 0.83,
      )
      ..close();
    canvas
      ..drawPath(leftPage, pagePaint)
      ..drawPath(rightPage, pagePaint)
      ..drawPath(leftPage, pageOutline)
      ..drawPath(rightPage, pageOutline);

    final Path bookmark = Path()
      ..moveTo(size.width * 0.66, size.height * 0.12)
      ..lineTo(size.width * 0.78, size.height * 0.12)
      ..lineTo(size.width * 0.78, size.height * 0.49)
      ..lineTo(size.width * 0.72, size.height * 0.42)
      ..lineTo(size.width * 0.66, size.height * 0.49)
      ..close();
    canvas.drawPath(bookmark, Paint()..color = warmGold);

    canvas.drawLine(
      Offset(centerX, size.height * 0.42),
      Offset(centerX, size.height * 0.83),
      Paint()
        ..color = gold.withValues(alpha: 0.55)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _OpenBookLogoPainter oldDelegate) {
    return oldDelegate.tokens != tokens;
  }
}

class _AboutSettingsCard extends StatelessWidget {
  const _AboutSettingsCard({required this.onItemPressed});

  final VoidCallback onItemPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final List<_AboutItem> items = <_AboutItem>[
      const _AboutItem(
        id: 'update',
        title: '检查更新',
        icon: Icons.cloud_upload_outlined,
        trailing: '当前版本 1.2.0',
      ),
      const _AboutItem(
        id: 'agreement',
        title: '用户协议',
        icon: Icons.description_outlined,
      ),
      const _AboutItem(
        id: 'privacy',
        title: '隐私政策',
        icon: Icons.shield_outlined,
      ),
      const _AboutItem(id: 'licenses', title: '开源许可', icon: Icons.code_rounded),
      const _AboutItem(
        id: 'contact',
        title: '联系我们',
        icon: Icons.headset_mic_outlined,
      ),
    ];

    return SizedBox(
      key: const Key('about-settings-card'),
      height: AppDetailMetrics.aboutCardHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.detailCard,
          border: Border.all(
            color: tokens.mutedText.withValues(alpha: 0.2),
            width: 0.8,
          ),
        ),
        child: ClipRRect(
          borderRadius: AppRadii.detailCard,
          child: Column(
            children: List<Widget>.generate(items.length, (int index) {
              return _AboutSettingsRow(
                item: items[index],
                showDivider: index < items.length - 1,
                onPressed: onItemPressed,
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _AboutSettingsRow extends StatelessWidget {
  const _AboutSettingsRow({
    required this.item,
    required this.showDivider,
    required this.onPressed,
  });

  final _AboutItem item;
  final bool showDivider;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: AppDetailMetrics.aboutRowHeight,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey<String>('about-action-${item.id}'),
                onTap: onPressed,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 24,
                        child: Icon(item.icon, color: tokens.warning, size: 23),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      if (item.trailing != null) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          item.trailing!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: tokens.mutedText,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            height: 1.2,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                      const SizedBox(width: 11),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: tokens.mutedText,
                        size: 15,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showDivider)
            Positioned(
              left: 14,
              right: 14,
              bottom: 0,
              child: SizedBox(
                height: 0.8,
                child: ColoredBox(
                  color: tokens.mutedText.withValues(alpha: 0.15),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AboutItem {
  const _AboutItem({
    required this.id,
    required this.title,
    required this.icon,
    this.trailing,
  });

  final String id;
  final String title;
  final IconData icon;
  final String? trailing;
}
