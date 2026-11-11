/// 数据源管理的操作面板。
///
/// 职责：将安装方式与低频管理操作分层展示，返回选择意图。
/// 注意：面板不执行 IO；调用方在关闭面板后检查生命周期与忙碌状态。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'source_management_tv.dart';

enum DataSourceManagementAction { checkUpdates, verify, diagnostics, help, uninstall }

enum DataSourceImportChoice { node, native, collection, onlineRepository }

bool get supportsNativeSourceImport =>
    !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME') &&
    !const bool.fromEnvironment('MGREAD_NODE_ONLY') &&
    (Platform.isWindows || Platform.isAndroid);

bool get supportsSourceCollectionImport => !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME');

Future<DataSourceImportChoice?> showDataSourceImportSheet(BuildContext context) => showSourceManagementSheet<DataSourceImportChoice>(
  context: context,
  builder: (context) => _ActionSheet(
    title: '添加数据源',
    description: '选择来源 → 核对数据源 → 确认安装。',
    children: [
      if (supportsSourceCollectionImport) ...[
        const _ActionGroupLabel('在线安装'),
        _ActionTile(
          actionKey: const Key('data-source-add-online-repository'),
          icon: Icons.cloud_download_outlined,
          title: '在线插件仓库',
          subtitle: '浏览数据源，勾选后确认安装或更新',
          onTap: () => Navigator.pop(context, DataSourceImportChoice.onlineRepository),
        ),
      ],
      const _ActionGroupLabel('本地导入'),
      _ActionTile(
        actionKey: const Key('data-source-add-node'),
        icon: Icons.insert_drive_file_outlined,
        title: const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME') ? '本地安装包（原生）' : '本地安装包（Node）',
        subtitle: const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME') ? '选择提供方给你的 .mgplugin 文件' : '选择 .mgplugin.js 或 .mgplugin 文件',
        onTap: () => Navigator.pop(context, DataSourceImportChoice.node),
      ),
      if (supportsNativeSourceImport)
        _ActionTile(
          actionKey: const Key('data-source-add-native'),
          icon: Icons.developer_board_outlined,
          title: '本地安装包（原生）',
          subtitle: '选择适用于当前平台的 .mgplugin 文件',
          onTap: () => Navigator.pop(context, DataSourceImportChoice.native),
        ),
      if (supportsSourceCollectionImport)
        _ActionTile(
          actionKey: const Key('data-source-add-collection'),
          icon: Icons.library_add_outlined,
          title: '导入数据源合集',
          subtitle: '选择 .mgplugins 文件，再勾选要安装的数据源',
          onTap: () => Navigator.pop(context, DataSourceImportChoice.collection),
        ),
    ],
  ),
);

class DataSourceManagementSheet extends StatelessWidget {
  const DataSourceManagementSheet({
    required this.canVerify,
    required this.canDiagnose,
    this.canCheckUpdates = false,
    required this.canUninstall,
    required this.busy,
    super.key,
  });

  final bool canVerify;
  final bool canDiagnose;
  final bool canCheckUpdates;
  final bool canUninstall;
  final bool busy;

  @override
  Widget build(BuildContext context) => _ActionSheet(
    title: '数据源工具',
    description: busy ? '正在处理数据源，完成后可检测、更新或卸载。' : '检查可用性、排查问题或查看使用帮助。',
    children: [
      const _ActionGroupLabel('更新与检查'),
      if (canCheckUpdates)
        _ActionTile(
          actionKey: const Key('data-source-check-updates'),
          icon: Icons.system_update_alt_rounded,
          title: '检查数据源更新',
          subtitle: '从 GitHub 检查已安装数据源的新版本',
          onTap: busy ? null : () => Navigator.pop(context, DataSourceManagementAction.checkUpdates),
        ),
      if (canVerify)
        _ActionTile(
          actionKey: const Key('data-source-verify-all'),
          icon: Icons.playlist_add_check_rounded,
          title: '检测数据源',
          subtitle: Platform.isWindows || Platform.isMacOS ? '进入检测页，检查已启用的数据源' : '全链路检测需在电脑运行；当前设备请使用运行诊断或搜索验证',
          onTap: busy || !(Platform.isWindows || Platform.isMacOS) ? null : () => Navigator.pop(context, DataSourceManagementAction.verify),
        ),
      const _ActionGroupLabel('帮助与排查'),
      if (canDiagnose)
        _ActionTile(
          actionKey: const Key('data-source-runtime-status'),
          icon: Icons.speed_outlined,
          title: '运行诊断',
          subtitle: '查看服务状态与故障信息',
          onTap: () => Navigator.pop(context, DataSourceManagementAction.diagnostics),
        ),
      _ActionTile(
        actionKey: const Key('data-source-management-help'),
        icon: Icons.menu_book_outlined,
        title: '使用帮助',
        subtitle: '了解添加、启停与常见问题',
        onTap: () => Navigator.pop(context, DataSourceManagementAction.help),
      ),
      const Divider(),
      const _ActionGroupLabel('危险操作'),
      _ActionTile(
        actionKey: const Key('data-source-clear-all'),
        icon: Icons.delete_outline_rounded,
        title: '卸载全部数据源',
        subtitle: canUninstall ? '移除已安装的数据源，保留书架内容' : '暂无可卸载的已安装数据源',
        destructive: true,
        onTap: busy || !canUninstall ? null : () => Navigator.pop(context, DataSourceManagementAction.uninstall),
      ),
    ],
  );
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({required this.title, required this.description, required this.children});

  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (TvModeScope.isEnabled(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Expanded(
            child: TvSourceWorkspace(
              sidebar: TvSourceScrollBody(
                child: TvSourcePanel(
                  title: title == '添加数据源' ? '选择安装方式' : '管理与维护',
                  icon: title == '添加数据源' ? Icons.add_to_queue_rounded : Icons.tune_rounded,
                  child: Text(description, style: Theme.of(context).textTheme.bodyLarge),
                ),
              ),
              child: ListView(padding: const EdgeInsets.all(4), children: children),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TvFocusable(
              key: const Key('tv-source-actions-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ),
        ],
      );
    }
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, 0, AppSpacing.comfortable, AppSpacing.comfortable),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.compact),
              Text(description, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppThemeTokens.of(context).mutedText)),
              const SizedBox(height: AppSpacing.regular),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.actionKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.destructive = false,
  });

  final Key actionKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    if (TvModeScope.isEnabled(context)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TvFocusable(
          key: actionKey,
          autofocus:
              actionKey == const Key('data-source-add-online-repository') ||
              (!supportsSourceCollectionImport && actionKey == const Key('data-source-add-node')) ||
              actionKey == const Key('data-source-check-updates'),
          onPressed: onTap,
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListTile(
      key: actionKey,
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
      enabled: onTap != null,
      leading: Icon(icon, color: onTap != null && destructive ? AppThemeTokens.of(context).notification : null),
      title: Text(title, style: TextStyle(color: onTap != null && destructive ? AppThemeTokens.of(context).notification : null)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }
}

class _ActionGroupLabel extends StatelessWidget {
  const _ActionGroupLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.regular, bottom: AppSpacing.unit),
    child: Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: AppThemeTokens.of(context).mutedText)),
  );
}
