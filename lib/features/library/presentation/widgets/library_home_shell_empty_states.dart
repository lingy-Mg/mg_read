/// 书架首页的提示、无进度与首次使用空状态。
///
/// 职责：
/// - 渲染书架壳内部的反馈横幅和空状态。
/// - 保持首次使用引导的语义、操作回调与视觉组成集中。
///
/// 注意：
/// - 本文件是 [LibraryHomeShell] 的私有 part，不持有页面状态或执行持久化。
/// - 所有操作意图由书架壳传入，不在展示组件内导航。
/// - 欢迎图使用最小高度，窄屏文字换行后可增高，避免真实手机视口溢出。
part of 'library_home_shell.dart';

class _ActionFeedbackBanner extends StatelessWidget {
  const _ActionFeedbackBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          border: Border.all(color: tokens.accent),
          borderRadius: AppRadii.control,
        ),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.regular,
            top: AppSpacing.compact,
            right: AppSpacing.compact,
            bottom: AppSpacing.compact,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: tokens.accent),
              const SizedBox(width: AppSpacing.compact),
              Expanded(
                child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
              ),
              IconButton(tooltip: '关闭提示', onPressed: onDismiss, icon: const Icon(Icons.close_rounded)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoReadingProgressCard extends StatelessWidget {
  const _NoReadingProgressCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        border: Border.all(color: tokens.divider),
        borderRadius: AppRadii.card,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Row(
          children: <Widget>[
            Icon(Icons.menu_book_outlined, color: tokens.accent),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('从书架开始阅读', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.compact),
                  Text('阅读进度接入本地资料后会显示在这里。', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FirstRunWelcomeCard extends StatelessWidget {
  const _FirstRunWelcomeCard({required this.onDiscover, required this.onManageSources});

  final VoidCallback onDiscover;
  final VoidCallback onManageSources;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      key: const Key('library-first-run-welcome'),
      container: true,
      liveRegion: true,
      label: '欢迎来到 MgRead，从一本书开始，发现更大的世界',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border.all(color: tokens.divider),
          borderRadius: AppRadii.card,
          boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.06), blurRadius: 22, offset: const Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: AppRadii.card,
          child: Column(
            children: <Widget>[
              _FirstRunHero(tokens: tokens),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.section, AppSpacing.comfortable, AppSpacing.section, AppSpacing.section),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('三步开启阅读', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: AppSpacing.regular),
                    const _FirstRunSteps(),
                    const SizedBox(height: AppSpacing.section),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('first-run-discover-cta'),
                        onPressed: onDiscover,
                        icon: const Icon(Icons.explore_rounded, size: 20),
                        label: const Text('去发现好书'),
                      ),
                    ),
                    Center(
                      child: TextButton(key: const Key('first-run-manage-sources'), onPressed: onManageSources, child: const Text('管理数据源')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FirstRunHero extends StatelessWidget {
  const _FirstRunHero({required this.tokens});

  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 214),
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[tokens.featureSurface, tokens.accentSoft, tokens.surface],
                ),
              ),
            ),
          ),
          Positioned(
            left: -42,
            top: -66,
            child: DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.4)),
              child: const SizedBox(width: 190, height: 190),
            ),
          ),
          Positioned(
            right: -20,
            bottom: -54,
            width: 205,
            height: 230,
            child: ExcludeSemantics(child: Image.asset('assets/illustrations/library_empty_updates.png', fit: BoxFit.contain)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.section, AppSpacing.section, 150, AppSpacing.section),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(color: tokens.surface.withValues(alpha: 0.74), borderRadius: AppRadii.pill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
                    child: Text(
                      '欢迎来到 MgRead',
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens.accent, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.regular),
                Text(
                  '从一本书开始，\n发现更大的世界',
                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 23, height: 1.18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.compact),
                Text('把喜欢的作品收进你的阅读空间', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FirstRunSteps extends StatelessWidget {
  const _FirstRunSteps();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    const steps = <({IconData icon, String label, String detail})>[
      (icon: Icons.tune_rounded, label: '添加数据源', detail: '连接内容'),
      (icon: Icons.auto_awesome_rounded, label: '发现作品', detail: '挑选喜欢'),
      (icon: Icons.menu_book_rounded, label: '开始阅读', detail: '随时继续'),
    ];
    return Row(
      children: <Widget>[
        for (int index = 0; index < steps.length; index++) ...<Widget>[
          Expanded(
            child: Column(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(color: tokens.accentSoft, shape: BoxShape.circle),
                  child: SizedBox(width: 40, height: 40, child: Icon(steps[index].icon, size: 21, color: tokens.accent)),
                ),
                const SizedBox(height: AppSpacing.compact),
                Text(
                  steps[index].label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  steps[index].detail,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontSize: 11),
                ),
              ],
            ),
          ),
          if (index < steps.length - 1)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 38),
                child: Divider(color: tokens.accent.withValues(alpha: 0.24), thickness: 1),
              ),
            ),
        ],
      ],
    );
  }
}

class _NoMatchingBooks extends StatelessWidget {
  const _NoMatchingBooks({required this.tokens});

  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.section),
        child: Text('没有符合当前筛选条件的书籍', style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText)),
      ),
    );
  }
}
