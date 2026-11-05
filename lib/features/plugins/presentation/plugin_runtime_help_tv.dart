/// TV 帮助按操作、问题和开发工具分区；长正文可独立展开阅读。
part of 'plugin_runtime_help_page.dart';

class _TvHelpCard extends StatelessWidget {
  const _TvHelpCard({required this.title, required this.icon, required this.body});
  final String title;
  final IconData icon;
  final String body;
  @override
  Widget build(BuildContext context) => TvFocusable(
    onPressed: () => showSourceManagementDialog<void>(
      context: context,
      builder: (context) => SourceManagementDialog(
        title: Text(title),
        content: Text(body),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回'))],
      ),
    ),
    child: TvSourcePanel(
      title: title,
      icon: icon,
      child: Text(body, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge),
    ),
  );
}
