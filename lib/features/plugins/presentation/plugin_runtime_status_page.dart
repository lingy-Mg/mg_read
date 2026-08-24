import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Runtime-backed data-source management presentation.
class PluginRuntimeStatusPage extends ConsumerWidget {
  const PluginRuntimeStatusPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    this.onSourcePressed = _ignoreSourcePressed,
    this.onRuntimeStatusRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String> onSourcePressed;
  final VoidCallback? onRuntimeStatusRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PluginRuntimeConnection> connection = ref.watch(
      pluginRuntimeConnectionProvider,
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('data-source-top-bar'),
                backButtonKey: const Key('profile-detail-back'),
                title: '管理数据来源',
                onBack: onBackRequested,
                actions: <Widget>[
                  if (onRuntimeStatusRequested != null)
                    AppSecondaryPageIconButton(
                      key: const Key('data-source-runtime-status'),
                      label: 'Node 状态',
                      icon: Icons.monitor_heart_outlined,
                      onPressed: onRuntimeStatusRequested!,
                    ),
                  AppSecondaryPageIconButton(
                    key: const Key('data-source-management-help'),
                    label: '数据来源说明',
                    icon: Icons.help_outline,
                    onPressed: () => _showHelp(context, ref),
                  ),
                ],
              ),
              Expanded(
                child: connection.when(
                  loading: () => const _DataSourceLoading(),
                  error: (Object _, StackTrace _) => _DataSourceFailure(
                    onRetry: () =>
                        ref.invalidate(pluginRuntimeConnectionProvider),
                  ),
                  data: (PluginRuntimeConnection value) => _DataSourceContent(
                    sources: _sourcesFromConnection(value),
                    onSourcePressed: onSourcePressed,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHelp(BuildContext context, WidgetRef ref) {
    final bool isWindows = kDebugMode && Platform.isWindows;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('数据来源说明'),
        content: Text(
          isWindows
              ? '在这里查看已添加的数据来源，并直接启用或停用它们。Windows 调试时还可以添加开发目录，目录内的数据源会即时生效。'
              : '在这里查看已添加的数据来源，并直接启用或停用它们。',
        ),
        actions: <Widget>[
          if (isWindows)
            TextButton(
              key: const Key('data-source-add-development-directory'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_selectDevelopmentDirectory(context, ref));
              },
              child: const Text('添加开发目录'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectDevelopmentDirectory(
    BuildContext context,
    WidgetRef ref,
  ) async {
    try {
      final selected = await ref
          .read(pluginRuntimeDevelopmentDirectoryProvider.notifier)
          .selectDirectory();
      if (!context.mounted || !selected) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('开发目录已添加并即时生效。')));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('开发目录添加失败，请检查目录后重试。')));
    }
  }
}

void _ignoreSourcePressed(String _) {}

class _DataSourceLoading extends StatelessWidget {
  const _DataSourceLoading();

  @override
  Widget build(BuildContext context) {
    return const AppLoadingState(
      label: '正在加载数据来源',
      message: '正在加载数据来源',
      progressKey: Key('data-source-management-loading'),
    );
  }
}

class _DataSourceFailure extends StatelessWidget {
  const _DataSourceFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        key: const Key('data-source-management-retry'),
        onPressed: onRetry,
        child: const Text('数据来源暂不可用，点击重试'),
      ),
    );
  }
}

class _DataSourceContent extends ConsumerStatefulWidget {
  const _DataSourceContent({
    required this.sources,
    required this.onSourcePressed,
  });

  final List<_DataSourceViewData> sources;
  final ValueChanged<String> onSourcePressed;

  @override
  ConsumerState<_DataSourceContent> createState() => _DataSourceContentState();
}

class _DataSourceContentState extends ConsumerState<_DataSourceContent> {
  Future<void> _setSourceEnabled(
    _DataSourceViewData source,
    bool enabled,
  ) async {
    try {
      await ref
          .read(pluginRuntimeSourceActionProvider.notifier)
          .setEnabled(pluginId: source.id, enabled: enabled);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('数据来源状态更新失败，请稍后重试。')));
    }
  }

  Future<void> _importDataSource() async {
    try {
      final imported = await ref
          .read(pluginRuntimeSourceImportProvider.notifier)
          .importLocalPlugin();
      if (!mounted || !imported) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('数据来源已添加。')));
    } on Object catch (error) {
      if (!mounted) return;
      await _showImportError(context, AppError.fromUnknown(error));
    }
  }

  Future<void> _openRuntimePrivateDirectory() async {
    try {
      await ref.read(pluginRuntimePrivateDirectoryProvider.notifier).open();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已打开 Runtime 私有目录。')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Runtime 私有目录打开失败，请稍后重试。')));
    }
  }

  Future<void> _showImportError(BuildContext context, AppError error) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('数据来源导入失败'),
        content: SelectableText(
          '${_importErrorMessage(error.code)}\n\n错误码：${error.code.wireValue}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  String _importErrorMessage(AppErrorCode code) {
    return switch (code) {
      AppErrorCode.invalidRequest || AppErrorCode.invalidFormat =>
        '选择的文件不是有效的 MgRead 数据来源包，请确认文件后缀为 .mgplugin，且文件没有损坏。',
      AppErrorCode.fileNameInvalid => '选择的文件名称不是 .mgplugin。请重新选择 MgRead 数据来源包。',
      AppErrorCode.fileUnavailable => '手机找不到选择的文件。请把文件复制到手机本地存储后重新选择。',
      AppErrorCode.fileUnreadable ||
      AppErrorCode.fileReadFailed => '手机无法读取选择的文件。请检查文件权限，并把文件复制到手机本地存储后重试。',
      AppErrorCode.fileTooLarge => '数据来源包超过 32 MB，无法导入。',
      AppErrorCode.pluginInstallFailed =>
        '文件已经读取，但数据来源安装失败。请确认这是标准 MgRead .mgplugin 包，并重新导出后再试。',
      AppErrorCode.diskFull => '手机存储空间不足，清理空间后再试。',
      AppErrorCode.runtimeStartFailed ||
      AppErrorCode.runtimeUnavailable ||
      AppErrorCode.runtimeNotReady => '数据来源运行环境启动失败。请完全退出应用后重试；如果仍失败，请提供这个错误码。',
      _ => '导入过程遇到未分类错误，请提供这个错误码以便继续定位。',
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Set<String> pendingSourceIds = ref.watch(
      pluginRuntimeSourceActionProvider,
    );
    final PluginSourceImportState importState = ref.watch(
      pluginRuntimeSourceImportProvider,
    );
    final int enabledCount = widget.sources
        .where((_DataSourceViewData source) => source.enabled)
        .length;
    return ListView(
      key: const Key('data-source-management-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.comfortable,
      ),
      children: <Widget>[
        DecoratedBox(
          key: const Key('data-source-management-card'),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.profileList,
            border: Border.all(color: tokens.divider),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: tokens.shadow.withValues(alpha: 0.16),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.comfortable,
              AppSpacing.comfortable + AppSpacing.compact,
              AppSpacing.comfortable,
              AppSpacing.regular,
            ),
            child: Column(
              children: <Widget>[
                _DataSourceSectionHeader(
                  enabledCount: enabledCount,
                  sourceCount: widget.sources.length,
                ),
                const SizedBox(height: AppSpacing.compact),
                if (widget.sources.isEmpty)
                  const _DataSourceEmptyState()
                else
                  ...List<Widget>.generate(widget.sources.length, (int index) {
                    final _DataSourceViewData source = widget.sources[index];
                    return Column(
                      children: <Widget>[
                        _DataSourceRow(
                          source: source,
                          isPending: pendingSourceIds.contains(source.id),
                          onPressed: () => widget.onSourcePressed(source.id),
                          onChanged: (bool enabled) =>
                              _setSourceEnabled(source, enabled),
                        ),
                        if (index < widget.sources.length - 1)
                          Padding(
                            padding: const EdgeInsets.only(
                              left:
                                  AppSpacing.dataSourceMarkExtent +
                                  AppSpacing.regular,
                            ),
                            child: Divider(height: 1, color: tokens.divider),
                          ),
                      ],
                    );
                  }),
                const SizedBox(height: AppSpacing.comfortable),
                if (importState.isImporting) ...<Widget>[
                  _DataSourceImportProgress(state: importState),
                  if (importState.logs.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.unit),
                    _DataSourceImportLog(logs: importState.logs),
                  ],
                  const SizedBox(height: AppSpacing.compact),
                ],
                _AddDataSourceButton(
                  isImporting: importState.isImporting,
                  onPressed: importState.isImporting ? null : _importDataSource,
                ),
                if (Platform.isWindows) ...<Widget>[
                  const SizedBox(height: AppSpacing.regular),
                  _RuntimePrivateDirectoryButton(
                    isOpening: ref.watch(pluginRuntimePrivateDirectoryProvider),
                    onPressed: _openRuntimePrivateDirectory,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DataSourceImportProgress extends StatelessWidget {
  const _DataSourceImportProgress({required this.state});

  final PluginSourceImportState state;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final double? fraction = state.fraction?.clamp(0, 1).toDouble();
    final String percent = fraction == null
        ? '处理中'
        : '${(fraction * 100).round()}%';
    return Semantics(
      liveRegion: true,
      label: '${state.message}，$percent',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  state.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: tokens.dataSourceAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                percent,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.unit),
          LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            backgroundColor: tokens.mutedSurface,
            color: tokens.dataSourceAccent,
          ),
        ],
      ),
    );
  }
}

class _DataSourceImportLog extends StatelessWidget {
  const _DataSourceImportLog({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Container(
      key: const Key('data-source-import-log'),
      constraints: const BoxConstraints(maxHeight: 128),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.compact,
        vertical: AppSpacing.unit,
      ),
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.detailControl,
      ),
      child: ListView(
        shrinkWrap: true,
        children: logs
            .map(
              (String log) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '· $log',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _RuntimePrivateDirectoryButton extends StatelessWidget {
  const _RuntimePrivateDirectoryButton({
    required this.isOpening,
    required this.onPressed,
  });

  final bool isOpening;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('data-source-open-runtime-directory'),
    onPressed: isOpening ? null : onPressed,
    icon: isOpening
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.folder_open_outlined),
    label: Text(isOpening ? '正在打开…' : '打开 Runtime 私有目录'),
  );
}

class _DataSourceSectionHeader extends StatelessWidget {
  const _DataSourceSectionHeader({
    required this.enabledCount,
    required this.sourceCount,
  });

  final int enabledCount;
  final int sourceCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '我的数据来源',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.3,
            ),
          ),
        ),
        Text(
          '已启用 $enabledCount/$sourceCount',
          key: const Key('data-source-enabled-count'),
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
      ],
    );
  }
}

class _DataSourceEmptyState extends StatelessWidget {
  const _DataSourceEmptyState();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: AppSpacing.dataSourceRowHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '暂无已安装的数据来源',
          key: const Key('data-source-management-empty'),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
      ),
    );
  }
}

class _DataSourceRow extends StatelessWidget {
  const _DataSourceRow({
    required this.source,
    required this.isPending,
    required this.onPressed,
    required this.onChanged,
  });

  final _DataSourceViewData source;
  final bool isPending;
  final VoidCallback onPressed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      label:
          '${source.name}，${source.kindLabel}，${source.enabled ? '已启用' : '未启用'}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('data-source-${source.id}'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryTile,
          child: SizedBox(
            height: AppSpacing.dataSourceRowHeight,
            child: Row(
              children: <Widget>[
                _DataSourceBrandMark(brand: source.brand),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.12,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        source.kindLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: tokens.mutedText,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: AppSpacing.minimumTouchTarget,
                  height: AppSpacing.minimumTouchTarget,
                  child: Transform.scale(
                    scale: 0.70,
                    child: Switch(
                      key: ValueKey<String>('data-source-toggle-${source.id}'),
                      value: source.enabled,
                      onChanged: isPending || source.isDevelopment
                          ? null
                          : onChanged,
                      activeTrackColor: tokens.dataSourceAccent,
                      activeThumbColor: theme.colorScheme.onPrimary,
                      inactiveTrackColor: tokens.mutedSurface,
                      inactiveThumbColor: tokens.surface,
                      trackOutlineColor: const WidgetStatePropertyAll<Color>(
                        Colors.transparent,
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
}

class _DataSourceBrandMark extends StatelessWidget {
  const _DataSourceBrandMark({required this.brand});

  final _DataSourceBrand brand;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final Color foreground = switch (brand) {
      _DataSourceBrand.qimao => theme.colorScheme.onSurface,
      _DataSourceBrand.generic => tokens.dataSourceAccent,
      _ => theme.colorScheme.onPrimary,
    };
    final _BrandColors colors = switch (brand) {
      _DataSourceBrand.qidian => _BrandColors(tokens.notification, foreground),
      _DataSourceBrand.tomato => _BrandColors(
        tokens.dataSourceAccent,
        foreground,
      ),
      _DataSourceBrand.qimao => _BrandColors(tokens.dataSourceCat, foreground),
      _DataSourceBrand.zongheng => _BrandColors(
        tokens.notification,
        foreground,
      ),
      _DataSourceBrand.jinjiang => _BrandColors(
        tokens.dataSourceCommunity,
        foreground,
      ),
      _DataSourceBrand.seventeenK => _BrandColors(
        tokens.dataSourceAccent,
        foreground,
      ),
      _DataSourceBrand.generic => _BrandColors(tokens.accentSoft, foreground),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: AppRadii.discoveryTile,
      ),
      child: SizedBox(
        width: AppSpacing.dataSourceMarkExtent,
        height: AppSpacing.dataSourceMarkExtent,
        child: Center(
          child: _BrandGlyph(brand: brand, color: colors.foreground),
        ),
      ),
    );
  }
}

class _BrandGlyph extends StatelessWidget {
  const _BrandGlyph({required this.brand, required this.color});

  final _DataSourceBrand brand;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return switch (brand) {
      _DataSourceBrand.qidian => Text(
        '起',
        style: _glyphTextStyle(context, color),
      ),
      _DataSourceBrand.tomato => CustomPaint(
        size: const Size.square(AppSpacing.dataSourceMarkExtent),
        painter: _TomatoMarkPainter(color),
      ),
      _DataSourceBrand.qimao => CustomPaint(
        size: const Size.square(AppSpacing.dataSourceMarkExtent),
        painter: _CatMarkPainter(color),
      ),
      _DataSourceBrand.zongheng => _GridBrandGlyph(color: color),
      _DataSourceBrand.jinjiang => CustomPaint(
        size: const Size.square(AppSpacing.dataSourceMarkExtent),
        painter: _JinjiangMarkPainter(color),
      ),
      _DataSourceBrand.seventeenK => Text(
        '17K',
        style: _glyphTextStyle(context, color),
      ),
      _DataSourceBrand.generic => Icon(
        Icons.extension_rounded,
        color: color,
        size: AppSpacing.dataSourceAddIconSize,
      ),
    };
  }

  TextStyle? _glyphTextStyle(BuildContext context, Color foreground) {
    return Theme.of(context).textTheme.titleLarge?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w700,
      height: 1,
      letterSpacing: -0.8,
    );
  }
}

class _GridBrandGlyph extends StatelessWidget {
  const _GridBrandGlyph({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSpacing.dataSourceMarkExtent - AppSpacing.regular,
      height: AppSpacing.dataSourceMarkExtent - AppSpacing.regular,
      child: Wrap(
        spacing: AppSpacing.unit,
        runSpacing: AppSpacing.unit,
        children: List<Widget>.generate(
          9,
          (_) => SizedBox(
            width: AppSpacing.unit * 2,
            height: AppSpacing.unit * 2,
            child: DecoratedBox(decoration: BoxDecoration(color: color)),
          ),
        ),
      ),
    );
  }
}

class _TomatoMarkPainter extends CustomPainter {
  const _TomatoMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    final double unit = size.width / AppSpacing.dataSourceMarkExtent;
    final Path stem = Path()
      ..moveTo(20 * unit, 0)
      ..lineTo(27 * unit, 0)
      ..lineTo(29 * unit, 10 * unit)
      ..lineTo(22 * unit, 8 * unit)
      ..close();
    canvas.drawPath(stem, paint);

    for (final Offset center in <Offset>[
      Offset(12 * unit, 23 * unit),
      Offset(18 * unit, 19 * unit),
      Offset(24 * unit, 23 * unit),
      Offset(18 * unit, 27 * unit),
    ]) {
      canvas.drawCircle(center, 1.7 * unit, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TomatoMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _CatMarkPainter extends CustomPainter {
  const _CatMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.width / AppSpacing.dataSourceMarkExtent;
    final Paint paint = Paint()..color = color;
    final Path cat = Path()
      ..moveTo(8 * unit, 29 * unit)
      ..lineTo(8 * unit, 14 * unit)
      ..lineTo(13 * unit, 8 * unit)
      ..lineTo(16 * unit, 11 * unit)
      ..lineTo(24 * unit, 11 * unit)
      ..lineTo(28 * unit, 7 * unit)
      ..lineTo(29 * unit, 17 * unit)
      ..quadraticBezierTo(28 * unit, 25 * unit, 23 * unit, 27 * unit)
      ..lineTo(25 * unit, 31 * unit)
      ..lineTo(25 * unit, 34 * unit)
      ..lineTo(10 * unit, 34 * unit)
      ..lineTo(10 * unit, 29 * unit)
      ..close();
    canvas.drawPath(cat, paint);

    final Paint eyePaint = Paint()..color = Colors.white;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(15 * unit, 17 * unit),
        width: 5 * unit,
        height: 3 * unit,
      ),
      eyePaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(23 * unit, 17 * unit),
        width: 5 * unit,
        height: 3 * unit,
      ),
      eyePaint,
    );
    canvas.drawCircle(Offset(16 * unit, 17 * unit), unit, paint);
    canvas.drawCircle(Offset(22 * unit, 17 * unit), unit, paint);
  }

  @override
  bool shouldRepaint(covariant _CatMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _JinjiangMarkPainter extends CustomPainter {
  const _JinjiangMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width / 11
      ..strokeCap = StrokeCap.round;
    final double unit = size.width / AppSpacing.dataSourceMarkExtent;
    final Path leaf = Path()
      ..moveTo(7 * unit, 29 * unit)
      ..quadraticBezierTo(10 * unit, 12 * unit, 11 * unit, 6 * unit)
      ..quadraticBezierTo(18 * unit, 13 * unit, 19 * unit, 24 * unit)
      ..quadraticBezierTo(25 * unit, 18 * unit, 29 * unit, 10 * unit)
      ..quadraticBezierTo(28 * unit, 25 * unit, 18 * unit, 31 * unit)
      ..quadraticBezierTo(11 * unit, 33 * unit, 7 * unit, 29 * unit);
    canvas.drawPath(leaf, paint);
    canvas.drawLine(
      Offset(11 * unit, 28 * unit),
      Offset(20 * unit, 16 * unit),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _JinjiangMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _AddDataSourceButton extends StatelessWidget {
  const _AddDataSourceButton({required this.isImporting, this.onPressed});

  final bool isImporting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '添加数据来源',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('data-source-add'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryTile,
          child: SizedBox(
            width: double.infinity,
            child: Ink(
              height: AppSpacing.dataSourceAddButtonHeight,
              decoration: BoxDecoration(
                borderRadius: AppRadii.discoveryTile,
                border: Border.all(color: tokens.accentSoft),
                color: tokens.pageBackground,
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (isImporting)
                      SizedBox(
                        width: AppSpacing.dataSourceAddIconSize,
                        height: AppSpacing.dataSourceAddIconSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tokens.dataSourceAccent,
                        ),
                      )
                    else
                      Icon(
                        Icons.add_rounded,
                        color: tokens.dataSourceAccent,
                        size: AppSpacing.dataSourceAddIconSize,
                      ),
                    const SizedBox(width: AppSpacing.compact),
                    Text(
                      isImporting ? '正在添加数据来源…' : '添加数据来源',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: tokens.dataSourceAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DataSourceViewData {
  const _DataSourceViewData({
    required this.id,
    required this.name,
    required this.kindLabel,
    required this.enabled,
    required this.brand,
    required this.isDevelopment,
  });

  final String id;
  final String name;
  final String kindLabel;
  final bool enabled;
  final _DataSourceBrand brand;
  final bool isDevelopment;
}

class _BrandColors {
  const _BrandColors(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

enum _DataSourceBrand {
  qidian,
  tomato,
  qimao,
  zongheng,
  jinjiang,
  seventeenK,
  generic,
}

List<_DataSourceViewData> _sourcesFromConnection(
  PluginRuntimeConnection connection,
) {
  return connection.plugins
      .where(
        (PluginRuntimePlugin plugin) =>
            plugin.contentKinds.contains('novel') ||
            plugin.contentKinds.contains('manga'),
      )
      .map(
        (PluginRuntimePlugin plugin) => _DataSourceViewData(
          id: plugin.id,
          name: plugin.displayName,
          kindLabel: _sourceMetadataLabel(plugin),
          enabled: plugin.enabled,
          brand: _brandForPlugin(plugin),
          isDevelopment: plugin.status == 'development',
        ),
      )
      .toList(growable: false);
}

String _contentKindLabel(List<String> contentKinds) {
  final List<String> labels = <String>[
    if (contentKinds.contains('novel')) '小说',
    if (contentKinds.contains('manga')) '漫画',
  ];
  return labels.isEmpty ? '数据源' : labels.join(' · ');
}

String _sourceMetadataLabel(PluginRuntimePlugin plugin) {
  final String kindLabel = _contentKindLabel(plugin.contentKinds);
  if (plugin.status == 'development') return '$kindLabel · 开发源（即时生效）';
  final String? origin = switch (plugin.displayName) {
    '起点中文网' || '番茄小说' || '七猫中文网' || '纵横中文网' => '官方源',
    '晋江文学城' || '17K小说网' || '17K 小说网' => '社区源',
    _ => null,
  };
  return origin == null ? kindLabel : '$kindLabel · $origin';
}

_DataSourceBrand _brandForPlugin(PluginRuntimePlugin plugin) {
  return switch (plugin.displayName) {
    '起点中文网' => _DataSourceBrand.qidian,
    '番茄小说' => _DataSourceBrand.tomato,
    '七猫中文网' => _DataSourceBrand.qimao,
    '纵横中文网' => _DataSourceBrand.zongheng,
    '晋江文学城' => _DataSourceBrand.jinjiang,
    '17K小说网' || '17K 小说网' => _DataSourceBrand.seventeenK,
    _ => _DataSourceBrand.generic,
  };
}
