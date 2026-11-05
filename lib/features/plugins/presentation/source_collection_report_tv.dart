/// TV 更新确认与批量结果：摘要和明细分栏，按钮固定在底部。
/// 仅显示调用方提供的真实版本和结果；确认意图由调用方处理。
part of 'source_collection_import_sheet.dart';

class _TvSourceCollectionReview extends StatelessWidget {
  const _TvSourceCollectionReview({
    required this.title,
    required this.summary,
    required this.message,
    required this.icon,
    required this.rows,
    required this.actions,
  });
  final String title;
  final String summary;
  final String message;
  final IconData icon;
  final List<(String, String)> rows;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Expanded(
              child: TvSourceWorkspace(
                sidebar: TvSourceScrollBody(
                  child: TvSourcePanel(title: summary, icon: icon, child: Text(message)),
                ),
                child: ListView(
                  padding: const EdgeInsets.all(4),
                  children: [
                    for (final (name, detail) in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SourceManagementInfo(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(name, style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Text(detail),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Wrap(alignment: WrapAlignment.end, spacing: 16, runSpacing: 8, children: actions),
          ],
        ),
      ),
    ),
  );
}
