/// 数据源管理的操作面板。
///
/// 职责：将安装方式与低频管理操作分层展示，返回选择意图。
/// 注意：面板不执行 IO；调用方在关闭面板后检查生命周期与忙碌状态。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

enum DataSourceManagementAction { verify, diagnostics, help, uninstall }

bool get supportsNativeSourceImport =>
    !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME') &&
    !const bool.fromEnvironment('MGREAD_NODE_ONLY') &&
    (Platform.isWindows || Platform.isAndroid);

Future<bool?> showDataSourceImportSheet(BuildContext context) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _ActionSheet(
    title: '添加数据源',
    description: '从设备选择数据源文件，按提供方注明的类型导入。',
    children: [
      _ActionTile(
        actionKey: const Key('data-source-add-node'),
        icon: Icons.insert_drive_file_outlined,
        title: const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME') ? '原生数据源' : 'Node 数据源',
        subtitle: const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME') ? '选择 .mgplugin 安装包' : '选择 .mgplugin.js 或 .mgplugin 文件',
        onTap: () => Navigator.pop(context, false),
      ),
      if (supportsNativeSourceImport)
        _ActionTile(
          actionKey: const Key('data-source-add-native'),
          icon: Icons.developer_board_outlined,
          title: '原生数据源',
          subtitle: '选择适用于当前平台的 .mgplugin 安装包',
          onTap: () => Navigator.pop(context, true),
        ),
    ],
  ),
);

class DataSourceManagementSheet extends StatelessWidget {
  const DataSourceManagementSheet({
    required this.canVerify,
    required this.canDiagnose,
    required this.canUninstall,
    required this.busy,
    super.key,
  });

  final bool canVerify;
  final bool canDiagnose;
  final bool canUninstall;
  final bool busy;

  @override
  Widget build(BuildContext context) => _ActionSheet(
    title: '数据源工具',
    description: busy ? '正在处理数据源，完成后可检测或卸载。' : '检查可用性、排查问题或查看使用帮助。',
    children: [
      if (canVerify)
        _ActionTile(
          actionKey: const Key('data-source-verify-all'),
          icon: Icons.playlist_add_check_rounded,
          title: '检测数据源',
          subtitle: '进入检测页，检查已启用的数据源',
          onTap: busy ? null : () => Navigator.pop(context, DataSourceManagementAction.verify),
        ),
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
  Widget build(BuildContext context) => SafeArea(
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
  Widget build(BuildContext context) => ListTile(
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
