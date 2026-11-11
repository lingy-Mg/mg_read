/// 单源详情的启停、验证、文件与卸载操作组件。
/// 仅展示明确的管理意图；操作互斥和 IO 由页面及应用端口负责。
part of 'plugin_runtime_source_detail_page.dart';

class _VerifySourceButton extends StatelessWidget {
  const _VerifySourceButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('data-source-detail-verify'),
        onPressed: onPressed,
        icon: const Icon(Icons.fact_check_outlined),
        label: _detailActionLabel('检测搜索、发现与阅读链路', compact),
      ),
    );
  }
}

class _RemoveSourceButton extends StatelessWidget {
  const _RemoveSourceButton({required this.isRemoving, required this.onPressed});

  final bool isRemoving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const Key('data-source-detail-remove'),
        onPressed: onPressed,
        icon: isRemoving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.delete_outline),
        label: _detailActionLabel(isRemoving ? '正在处理' : '卸载数据源', compact),
        style: OutlinedButton.styleFrom(foregroundColor: tokens.notification),
      ),
    );
  }
}

class _DetailActions extends StatelessWidget {
  const _DetailActions({
    required this.busy,
    required this.enabledControl,
    required this.isDesktop,
    required this.isDevelopment,
    required this.isWindows,
    required this.opensArchive,
    required this.opening,
    required this.packaging,
    required this.removing,
    required this.canVerify,
    required this.onVerify,
    required this.onOpenDirectory,
    required this.onPackage,
    required this.onRemove,
  });

  final bool busy;
  final Widget enabledControl;
  final bool isDesktop;
  final bool isDevelopment;
  final bool isWindows;
  final bool opensArchive;
  final bool opening;
  final bool packaging;
  final bool removing;
  final bool canVerify;
  final VoidCallback? onVerify;
  final VoidCallback onOpenDirectory;
  final VoidCallback onPackage;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (TvModeScope.isEnabled(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          enabledControl,
          const SizedBox(height: 12),
          _tvAction('verify', Icons.fact_check_outlined, '检测数据源', canVerify ? onVerify : null),
          if (!isDesktop) const Padding(padding: EdgeInsets.all(12), child: Text('全链路检测需在电脑运行')),
          if (isDevelopment && isWindows)
            _tvAction('package', Icons.inventory_2_outlined, packaging ? '正在打包…' : '打包数据源', busy ? null : onPackage),
          if (isDesktop)
            _tvAction(
              'open-directory',
              Icons.folder_open_outlined,
              opening
                  ? '正在打开…'
                  : opensArchive
                  ? '打开安装包目录'
                  : '打开代码目录',
              busy ? null : onOpenDirectory,
            ),
          if (!isDevelopment) _tvAction('remove', Icons.delete_outline, removing ? '正在处理…' : '卸载数据源', busy ? null : onRemove),
        ],
      );
    }
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.profileList,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('数据源操作', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.regular),
            _VerifySourceButton(onPressed: canVerify ? onVerify : null),
            if (!isDesktop)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.unit),
                child: Text('全链路检测需在电脑运行。请返回数据源工具使用运行诊断，或通过搜索验证该源。'),
              ),
            if (isDevelopment && isWindows) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _PackageDevelopmentButton(isPackaging: packaging, onPressed: busy ? null : onPackage),
            ],
            if (isDesktop) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _OpenDirectoryButton(
                isDevelopment: isDevelopment,
                opensArchive: opensArchive,
                isOpening: opening,
                onPressed: busy ? null : onOpenDirectory,
              ),
            ] else ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline, size: 18, color: tokens.mutedText),
                  const SizedBox(width: AppSpacing.unit),
                  Expanded(
                    child: Text('代码文件夹可在桌面端打开。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                  ),
                ],
              ),
            ],
            if (!isDevelopment) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              Divider(height: 1, color: tokens.divider),
              const SizedBox(height: AppSpacing.regular),
              _RemoveSourceButton(isRemoving: removing, onPressed: busy ? null : onRemove),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tvAction(String id, IconData icon, String label, VoidCallback? callback) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TvFocusable(
      key: Key('data-source-detail-$id'),
      onPressed: callback,
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    ),
  );
}

class _OpenDirectoryButton extends StatelessWidget {
  const _OpenDirectoryButton({required this.isDevelopment, required this.opensArchive, required this.isOpening, required this.onPressed});

  final bool isDevelopment;
  final bool opensArchive;
  final bool isOpening;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('data-source-detail-open-directory'),
        onPressed: onPressed,
        icon: isOpening
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.folder_open_outlined),
        label: _detailActionLabel(
          isOpening
              ? '正在打开…'
              : isDevelopment
              ? '打开开发项目文件夹'
              : opensArchive
              ? '打开原始安装包文件夹'
              : '打开已安装源码文件夹',
          compact,
        ),
      ),
    );
  }
}

class _PackageDevelopmentButton extends StatelessWidget {
  const _PackageDevelopmentButton({required this.isPackaging, required this.onPressed});

  final bool isPackaging;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const Key('data-source-detail-package-development'),
        onPressed: onPressed,
        icon: isPackaging
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.inventory_2_outlined),
        label: _detailActionLabel(isPackaging ? '正在打包…' : '打包数据源插件', compact),
      ),
    );
  }
}

bool _useCompactDetailActionLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 360 || MediaQuery.textScalerOf(context).scale(1) > 1;

Widget _detailActionLabel(String label, bool compact) => compact ? Text(label, textAlign: TextAlign.center, softWrap: true) : Text(label);

class _SourceEnabledControl extends ConsumerWidget {
  const _SourceEnabledControl({required this.source, required this.busy});
  final PluginRuntimePlugin source;
  final bool busy;

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    if (ref.read(pluginRuntimeSourceManagementBusyProvider)) return;
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).setEnabled(pluginId: source.id, enabled: !source.enabled);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已${source.enabled ? '停用' : '启用'}“${source.displayName}”。')));
      }
    } on Object {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源状态更新失败，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final development = source.status == 'development';
    final description = development
        ? '开发数据源由开发目录管理，即时生效。'
        : busy
        ? '正在处理数据源，请稍候。'
        : '停用后保留数据，可随时重新启用。';
    if (TvModeScope.isEnabled(context)) {
      return TvFocusable(
        key: const Key('data-source-detail-enabled'),
        onPressed: busy || development ? null : () => _toggle(context, ref),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              development
                  ? '开发数据源'
                  : source.enabled
                  ? '已启用 · 确认停用'
                  : '已停用 · 确认启用',
            ),
            Text(description, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: SwitchListTile.adaptive(
        key: const Key('data-source-detail-enabled'),
        contentPadding: EdgeInsets.zero,
        title: Text(
          development
              ? '开发数据源'
              : source.enabled
              ? '已启用'
              : '已停用',
        ),
        subtitle: Text(description),
        value: source.enabled,
        onChanged: busy || development ? null : (_) => _toggle(context, ref),
      ),
    );
  }
}
