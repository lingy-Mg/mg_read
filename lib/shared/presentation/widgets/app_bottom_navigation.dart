/// MgRead 底部导航的悬浮式外观与短时选中反馈。
///
/// 职责：
/// - 渲染四个主目的地与共享胶囊；选中前后始终保留标签和图标位置。
/// - 接收页面提供的目的地图标覆盖和显式长按回调。
/// - 消费 MotionScope 的状态，不拥有跨路由 controller。
///
/// 注意：
/// - 跨路由移动、减少动态效果和资源释放属于 sibling MotionScope。
/// - 本模块不处理导航路由或业务状态。
///
library;

export 'package:mg_read/shared/presentation/motion/app_bottom_navigation_motion_scope.dart';

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/motion/app_bottom_navigation_motion_scope.dart';

/// Optional icon appearance supplied by a destination page.
final class AppNavigationIconOverride {
  const AppNavigationIconOverride({required this.icon, required this.selectedIcon});

  final IconData icon;
  final IconData selectedIcon;
}

/// Bottom destinations for the mobile-first root feature surfaces.
class AppBottomNavigation extends StatelessWidget {
  /// Creates a navigation bar with one selected destination.
  const AppBottomNavigation({
    required this.selected,
    required this.onSelected,
    this.onLongPressed,
    this.iconOverrides = const <AppNavigationDestination, AppNavigationIconOverride>{},
    this.height = AppSpacing.bottomNavigationHeight,
    super.key,
  });

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final ValueChanged<AppNavigationDestination>? onLongPressed;
  final Map<AppNavigationDestination, AppNavigationIconOverride> iconOverrides;

  final double height;

  @override
  Widget build(BuildContext context) {
    if (TvModeScope.isEnabled(context)) {
      return SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final destination in AppNavigationDestination.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: TvFocusable(
                        key: Key('app-nav-${destination.name}'),
                        selected: destination == selected,
                        onPressed: () => onSelected(destination),
                        child: Text(switch (destination) {
                          AppNavigationDestination.home => '影视首页',
                          AppNavigationDestination.search => '搜索',
                          AppNavigationDestination.discover => '发现',
                          AppNavigationDestination.profile => '设置',
                        }, style: Theme.of(context).textTheme.titleLarge),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final AppBottomNavigationMotion? motion = AppBottomNavigationMotionScope.maybeOf(context);
    if (motion == null) {
      return AppBottomNavigationMotionScope(
        initialDestination: selected,
        child: _AppBottomNavigationContent(
          selected: selected,
          onSelected: onSelected,
          onLongPressed: onLongPressed,
          iconOverrides: iconOverrides,
          height: height,
        ),
      );
    }

    return _AppBottomNavigationContent(
      selected: selected,
      onSelected: onSelected,
      onLongPressed: onLongPressed,
      iconOverrides: iconOverrides,
      height: height,
    );
  }
}

class _AppBottomNavigationContent extends StatelessWidget {
  const _AppBottomNavigationContent({
    required this.selected,
    required this.onSelected,
    required this.onLongPressed,
    required this.iconOverrides,
    required this.height,
  });

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final ValueChanged<AppNavigationDestination>? onLongPressed;
  final Map<AppNavigationDestination, AppNavigationIconOverride> iconOverrides;
  final double height;

  @override
  Widget build(BuildContext context) {
    final AppBottomNavigationMotion motion = AppBottomNavigationMotionScope.maybeOf(context)!;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (motion.isMounted) motion.ensureDestination(selected);
    });

    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return SizedBox(
      width: double.infinity,
      height: height,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSpacing.bottomNavigationMaxWidth),
          child: SizedBox(
            key: const Key('app-bottom-navigation'),
            width: double.infinity,
            height: height,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return AnimatedBuilder(
                  animation: motion.animation,
                  builder: (BuildContext context, Widget? child) {
                    final double innerWidth = constraints.maxWidth - AppSpacing.regular * 2;
                    final double innerHeight = constraints.maxHeight - AppSpacing.compact * 2;
                    final double itemWidth = innerWidth / AppNavigationDestination.values.length;
                    final double position = motion.positionFor(selected).clamp(0, AppNavigationDestination.values.length - 1);
                    final double indicatorWidth = AppSpacing.bottomNavigationIndicatorWidth * motion.pillWidthScale;
                    final double indicatorHeight = AppSpacing.bottomNavigationIndicatorHeight * motion.pillHeightScale;
                    final double indicatorLeft = itemWidth * (position + 0.5) - indicatorWidth / 2;
                    final double indicatorTop = (innerHeight - indicatorHeight) / 2;
                    final AppNavigationDestination visualSelection = motion.visualSelectionFor(selected);

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
                      child: ClipRRect(
                        borderRadius: AppRadii.card,
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: DecoratedBox(
                            key: const Key('app-bottom-navigation-backdrop'),
                            decoration: BoxDecoration(
                              // Keep the surface translucent so the content below
                              // is softened by blur instead of being painted over.
                              color: tokens.surface.withValues(alpha: 0.68),
                              border: Border.all(color: tokens.divider.withValues(alpha: 0.86)),
                              borderRadius: AppRadii.card,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: tokens.shadow.withValues(alpha: 0.22),
                                  blurRadius: AppSpacing.comfortable,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                Positioned(
                                  left: indicatorLeft,
                                  top: indicatorTop,
                                  width: indicatorWidth,
                                  height: indicatorHeight,
                                  child: DecoratedBox(
                                    key: const Key('app-bottom-navigation-moving-indicator'),
                                    decoration: BoxDecoration(
                                      color: tokens.accentSoft,
                                      border: Border.all(color: tokens.accent.withValues(alpha: 0.12)),
                                      borderRadius: AppRadii.pill,
                                    ),
                                  ),
                                ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: AppNavigationDestination.values
                                      .map(
                                        (AppNavigationDestination destination) => Expanded(
                                          child: _AppNavigationItem(
                                            destination: destination,
                                            visuallySelected: destination == visualSelection,
                                            semanticallySelected: destination == selected,
                                            onSelected: (value) {
                                              motion.animateTo(value);
                                              onSelected(value);
                                            },
                                            onLongPressed: onLongPressed,
                                            iconOverride: iconOverrides[destination],
                                            theme: theme,
                                            tokens: tokens,
                                          ),
                                        ),
                                      )
                                      .toList(growable: false),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AppNavigationItem extends StatelessWidget {
  const _AppNavigationItem({
    required this.destination,
    required this.visuallySelected,
    required this.semanticallySelected,
    required this.onSelected,
    required this.onLongPressed,
    required this.iconOverride,
    required this.theme,
    required this.tokens,
  });

  final AppNavigationDestination destination;
  final bool visuallySelected;
  final bool semanticallySelected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final ValueChanged<AppNavigationDestination>? onLongPressed;
  final AppNavigationIconOverride? iconOverride;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final _AppNavigationItemData data = _dataFor(destination);
    final IconData icon = visuallySelected ? iconOverride?.selectedIcon ?? data.selectedIcon : iconOverride?.icon ?? data.icon;
    final Color foreground = visuallySelected ? tokens.accent : theme.colorScheme.onSurface.withValues(alpha: 0.82);
    final TextStyle labelStyle = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: foreground,
      fontWeight: visuallySelected ? FontWeight.w600 : FontWeight.w400,
      height: 1.1,
    );

    return Semantics(
      button: true,
      selected: semanticallySelected,
      label: data.label,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          key: ValueKey<String>('app-nav-${destination.name}'),
          onTap: () => onSelected(destination),
          onLongPress: onLongPressed == null ? null : () => onLongPressed!(destination),
          radius: AppSpacing.minimumTouchTarget / 2,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: tokens.focusRing.withValues(alpha: 0.16),
          child: SizedBox.expand(
            child: Stack(
              children: <Widget>[
                AnimatedAlign(
                  key: ValueKey<String>('app-nav-icon-motion-${destination.name}'),
                  duration: AppMotion.effectiveDuration(context, AppMotion.bottomNavigationIconResponse),
                  curve: visuallySelected ? AppMotion.navigationCurve : AppMotion.navigationReverseCurve,
                  alignment: const Alignment(0, AppMotion.bottomNavigationUnselectedIconAlignmentY),
                  child: AnimatedScale(
                    duration: AppMotion.effectiveDuration(context, AppMotion.bottomNavigationIconResponse),
                    curve: visuallySelected ? AppMotion.navigationCurve : AppMotion.navigationReverseCurve,
                    scale: visuallySelected ? AppMotion.bottomNavigationSelectedIconScale : 1,
                    child: Transform.translate(
                      offset: data.opticalOffset,
                      child: AnimatedSwitcher(
                        duration: AppMotion.effectiveDuration(context, AppMotion.navigationSelection),
                        switchInCurve: AppMotion.navigationCurve,
                        switchOutCurve: AppMotion.navigationReverseCurve,
                        transitionBuilder: (Widget child, Animation<double> animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(scale: Tween<double>(begin: 0.9, end: 1).animate(animation), child: child),
                          );
                        },
                        child: Icon(key: ValueKey<IconData>(icon), icon, size: AppSpacing.bottomNavigationIconSize, color: foreground),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: const Alignment(0, AppMotion.bottomNavigationLabelAlignmentY),
                  child: ExcludeSemantics(
                    child: AnimatedSlide(
                      key: ValueKey<String>('app-nav-label-motion-${destination.name}'),
                      duration: AppMotion.effectiveDuration(context, AppMotion.bottomNavigationLabelResponse),
                      curve: visuallySelected ? AppMotion.navigationCurve : AppMotion.navigationReverseCurve,
                      offset: Offset.zero,
                      child: AnimatedScale(
                        duration: AppMotion.effectiveDuration(context, AppMotion.bottomNavigationLabelResponse),
                        curve: visuallySelected ? AppMotion.navigationCurve : AppMotion.navigationReverseCurve,
                        scale: 1,
                        child: AnimatedOpacity(
                          duration: AppMotion.effectiveDuration(context, AppMotion.bottomNavigationLabelResponse),
                          curve: AppMotion.navigationCurve,
                          opacity: 1,
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.effectiveDuration(context, AppMotion.navigationSelection),
                            curve: AppMotion.navigationCurve,
                            style: labelStyle,
                            child: Text(data.label),
                          ),
                        ),
                      ),
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

  _AppNavigationItemData _dataFor(AppNavigationDestination value) {
    return switch (value) {
      AppNavigationDestination.home => const _AppNavigationItemData(
        label: '首页',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home_rounded,
        opticalOffset: Offset(0, 0.25),
      ),
      AppNavigationDestination.search => const _AppNavigationItemData(
        label: '搜索',
        icon: Icons.search_rounded,
        selectedIcon: Icons.search_rounded,
        opticalOffset: Offset(-0.5, -0.5),
      ),
      AppNavigationDestination.discover => const _AppNavigationItemData(
        label: '发现',
        icon: Icons.explore_outlined,
        selectedIcon: Icons.explore_rounded,
        opticalOffset: Offset(0, -0.25),
      ),
      AppNavigationDestination.profile => const _AppNavigationItemData(
        label: '我的',
        icon: Icons.person_outline_rounded,
        selectedIcon: Icons.person_rounded,
        opticalOffset: Offset(0, -0.75),
      ),
    };
  }
}

class _AppNavigationItemData {
  const _AppNavigationItemData({required this.label, required this.icon, required this.selectedIcon, required this.opticalOffset});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Offset opticalOffset;
}
