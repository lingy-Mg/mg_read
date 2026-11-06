/// Import filters share sheet-owned state across touch/desktop and TV layouts.
/// Online disclosure is explicit and resets whenever a new sheet is opened.
part of 'source_collection_import_sheet.dart';

enum _CollectionKind {
  all('全部'),
  novel('小说'),
  manga('漫画'),
  video('视频'),
  audio('音乐');

  const _CollectionKind(this.label);
  final String label;
}

class _CollectionFilters extends StatelessWidget {
  const _CollectionFilters({
    required this.kind,
    required this.onKindChanged,
    required this.online,
    required this.showR18,
    required this.onR18Changed,
  });

  final _CollectionKind kind;
  final ValueChanged<_CollectionKind> onKindChanged;
  final bool online;
  final bool showR18;
  final ValueChanged<bool> onR18Changed;

  @override
  Widget build(BuildContext context) {
    final tv = TvModeScope.isEnabled(context);
    final choices = [
      for (final value in _CollectionKind.values)
        if (tv)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.compact),
            child: TvFocusable(
              key: Key('source-collection-kind-${value.name}'),
              selected: kind == value,
              onPressed: () => onKindChanged(value),
              child: Text(value.label),
            ),
          )
        else
          ChoiceChip(
            key: Key('source-collection-kind-${value.name}'),
            label: Text(value.label),
            selected: kind == value,
            onSelected: (_) => onKindChanged(value),
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tv)
          ...choices
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(spacing: AppSpacing.compact, children: choices),
          ),
        if (online)
          if (tv)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.compact),
              child: TvFocusable(
                key: const Key('source-collection-show-r18'),
                selected: showR18,
                onPressed: () => onR18Changed(!showR18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('显示 R18 数据源：${showR18 ? '已开启' : '已关闭'}'),
                    Text('含未分级来源，仅本次开启', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            )
          else
            SwitchListTile(
              key: const Key('source-collection-show-r18'),
              contentPadding: EdgeInsets.zero,
              title: const Text('显示 R18 数据源'),
              subtitle: const Text('默认隐藏 R18 及未分级数据源，仅本次开启'),
              value: showR18,
              onChanged: onR18Changed,
            ),
      ],
    );
  }
}
