/// 本地通知与书架操作记录页面。
///
/// 职责：
/// - 按时间倒序展示有界书架操作记录。
/// - 提供显式刷新和清空操作，不在后台持续读取。
///
/// 注意：
/// - 页面最多渲染 Content Library 保留的 100 条记录，并使用懒构建列表。
/// - 未来内容更新通知复用现有类型，不在当前版本启动轮询或后台刷新。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/notifications/application/notification_center.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

final class NotificationsPage extends StatefulWidget {
  const NotificationsPage({required this.center, required this.onBackRequested, super.key});

  final NotificationCenter center;
  final VoidCallback onBackRequested;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

final class _NotificationsPageState extends State<NotificationsPage> {
  List<LibraryNotification> _entries = const <LibraryNotification>[];
  bool _loading = true;
  bool _clearing = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                title: '通知',
                onBack: widget.onBackRequested,
                headerKey: const Key('notifications-top-bar'),
                backButtonKey: const Key('notifications-back'),
              ),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator(key: Key('notifications-loading')));
    }
    if (_error != null && _entries.isEmpty) {
      return _NotificationsMessage(
        key: const Key('notifications-error'),
        icon: Icons.error_outline_rounded,
        title: '通知暂时无法读取',
        description: '书架功能不受影响，可以稍后重试。',
        actionLabel: '重新加载',
        onAction: _load,
      );
    }
    if (_entries.isEmpty) {
      return const _NotificationsMessage(
        key: Key('notifications-empty'),
        icon: Icons.notifications_none_rounded,
        title: '暂无通知',
        description: '加入或移出书架后，操作记录会显示在这里。',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        key: const Key('notifications-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppDetailMetrics.horizontalPadding,
          AppSpacing.regular,
          AppDetailMetrics.horizontalPadding,
          AppSpacing.section,
        ),
        itemCount: _entries.length + 2,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) return const _NotificationListIntro();
          if (index <= _entries.length) {
            return Padding(
              padding: EdgeInsets.only(bottom: index == _entries.length ? 0 : AppSpacing.compact),
              child: _NotificationTile(entry: _entries[index - 1]),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(top: AppSpacing.comfortable),
            child: Center(
              child: TextButton.icon(
                key: const Key('notifications-clear'),
                onPressed: _clearing ? null : _confirmClear,
                icon: _clearing
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.delete_outline_rounded),
                label: const Text('清空操作记录'),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final entries = await widget.center.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'load_failed';
      });
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空操作记录？'),
        content: const Text('这只会删除本机通知记录，不会修改书架内容。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('清空')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.center.clear();
      if (!mounted) return;
      setState(() {
        _entries = const <LibraryNotification>[];
        _clearing = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _clearing = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('操作记录清空失败，请稍后重试。')));
    }
  }
}

final class _NotificationListIntro extends StatelessWidget {
  const _NotificationListIntro();

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.regular),
      child: Text(
        '操作记录',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w600),
      ),
    );
  }
}

final class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.entry});

  final LibraryNotification entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final metadata = _notificationVisual(entry.kind);
    return DecoratedBox(
      key: Key('notification-${entry.id}'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.card,
        border: Border.all(color: tokens.divider.withValues(alpha: 0.72)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: metadata.color(tokens).withValues(alpha: 0.11), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(metadata.icon, size: 21, color: metadata.color(tokens)),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(metadata.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.unit / 2),
                  Text(
                    metadata.message(entry.title),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.4),
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    _formatOccurredAt(entry.occurredAt),
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText.withValues(alpha: 0.78)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _NotificationsMessage extends StatelessWidget {
  const _NotificationsMessage({
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: tokens.accent),
            const SizedBox(height: AppSpacing.regular),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.unit),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

typedef _TokenColor = Color Function(AppThemeTokens tokens);

final class _NotificationVisual {
  const _NotificationVisual({required this.title, required this.icon, required this.color, required this.message});

  final String title;
  final IconData icon;
  final _TokenColor color;
  final String Function(String bookTitle) message;
}

_NotificationVisual _notificationVisual(LibraryNotificationKind kind) => switch (kind) {
  LibraryNotificationKind.bookshelfAdded => _NotificationVisual(
    title: '已加入书架',
    icon: Icons.bookmark_add_outlined,
    color: (tokens) => tokens.success,
    message: (title) => '《$title》已加入书架。',
  ),
  LibraryNotificationKind.bookshelfRemoved => _NotificationVisual(
    title: '已移出书架',
    icon: Icons.bookmark_remove_outlined,
    color: (tokens) => tokens.warning,
    message: (title) => '《$title》已从书架移除。',
  ),
  LibraryNotificationKind.contentUpdated => _NotificationVisual(
    title: '内容更新',
    icon: Icons.auto_stories_outlined,
    color: (tokens) => tokens.accent,
    message: (title) => '《$title》有新的内容更新。',
  ),
};

String _formatOccurredAt(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return '今天 $time';
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $time';
  return '${local.month}月${local.day}日 $time';
}
