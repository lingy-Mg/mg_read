/// “我的”顶层 TV 模式开关，复用根组件的模式状态与持久化回调。
/// 本组件不持有设置副本、不执行 IO；切换后由 ProfilePage 展示对应界面。
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

class ProfileTvModeCard extends StatelessWidget {
  const ProfileTvModeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = TvModeScope.maybeOf(context);
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.profileList,
        side: BorderSide(color: tokens.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile.adaptive(
        key: const Key('profile-tv-mode'),
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.compact),
        secondary: Icon(Icons.tv_rounded, color: tokens.accent),
        title: Text('TV 模式', style: Theme.of(context).textTheme.titleMedium),
        subtitle: const Text('大屏界面 · 遥控器操作'),
        value: mode?.enabled ?? false,
        onChanged: mode?.onChanged,
      ),
    );
  }
}
