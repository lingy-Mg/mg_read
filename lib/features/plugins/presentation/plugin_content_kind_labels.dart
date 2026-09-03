/// 数据源插件内容类型的管理端展示规则。
///
/// 职责：
/// - 统一判断 Runtime 插件是否声明了受支持的数据源内容类型。
/// - 为管理列表与详情页提供稳定、完整的中文类型标签。
///
/// 注意：
/// - 类型集合必须与 Runtime 公开支持的 novel、manga、audio、video 保持一致。
/// - 此处只负责管理端展示，不参与发现、搜索或播放路由。
///
library;

const Map<String, String> _pluginContentKindLabels = <String, String>{'novel': '小说', 'manga': '漫画', 'audio': '音频', 'video': '视频'};

bool hasSupportedPluginContentKind(Iterable<String> contentKinds) => contentKinds.any(_pluginContentKindLabels.containsKey);

String pluginContentKindsLabel(Iterable<String> contentKinds) {
  final kinds = contentKinds.toSet();
  final labels = <String>[
    for (final entry in _pluginContentKindLabels.entries)
      if (kinds.contains(entry.key)) entry.value,
  ];
  return labels.isEmpty ? '数据源' : labels.join(' · ');
}
