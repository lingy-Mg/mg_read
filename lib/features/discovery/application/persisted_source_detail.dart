/// 数据源详情的持久化快照编解码。
///
/// 职责：
/// - 将已通过 Runtime/Facade 校验的详情转换为 JSON 兼容动态数据。
/// - 为书架本地优先详情恢复完整摘要、来源链接和别名。
///
/// 注意：
/// - 只保存来源详情的应用展示投影。
/// - 解码必须容忍旧记录和局部损坏，失败时由调用方回退到强类型书架投影。
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

Map<String, Object?> encodePersistedSourceDetail(PluginContentDetail detail) => <String, Object?>{
  'sourceName': detail.sourceName,
  if (detail.catalogUrl != null) 'catalogUrl': detail.catalogUrl.toString(),
  if (detail.aliases.isNotEmpty) 'aliases': detail.aliases,
  'summary': _encodeSummary(detail.summary),
};

PluginContentDetail? decodePersistedSourceDetail({required String pluginId, required Map<String, Object?> data}) {
  final summary = _decodeSummary(_objectMap(data['summary']));
  if (summary == null) return null;
  return PluginContentDetail(
    pluginId: pluginId,
    sourceName: _nonBlankString(data['sourceName']) ?? '书架来源',
    summary: summary,
    aliases: _stringList(data['aliases']),
    catalogUrl: _uri(data['catalogUrl']),
  );
}

Map<String, Object?> _encodeSummary(PluginContentSummary summary) => <String, Object?>{
  'id': summary.id,
  'title': summary.title,
  'contentKind': summary.contentKind.code,
  'coverOrientation': summary.coverOrientation.code,
  if (summary.author != null) 'author': summary.author,
  if (summary.url != null) 'url': summary.url.toString(),
  if (summary.coverUrl != null) 'coverUrl': summary.coverUrl.toString(),
  if (summary.description != null) 'description': summary.description,
  if (summary.language != null) 'language': summary.language,
  'status': summary.status.code,
  'access': summary.access.code,
  if (summary.wordCount != null) 'wordCount': summary.wordCount,
  if (summary.chapterCount != null) 'chapterCount': summary.chapterCount,
  if (summary.publishedAt != null) 'publishedAt': summary.publishedAt!.toIso8601String(),
  if (summary.updatedAt != null) 'updatedAt': summary.updatedAt!.toIso8601String(),
  if (summary.latestChapter != null)
    'latestChapter': <String, Object?>{
      if (summary.latestChapter!.id != null) 'id': summary.latestChapter!.id,
      'title': summary.latestChapter!.title,
      if (summary.latestChapter!.url != null) 'url': summary.latestChapter!.url.toString(),
      if (summary.latestChapter!.updatedAt != null) 'updatedAt': summary.latestChapter!.updatedAt!.toIso8601String(),
    },
  if (summary.categories.isNotEmpty) 'categories': summary.categories,
  if (summary.tags.isNotEmpty) 'tags': summary.tags,
  if (summary.attributes.isNotEmpty)
    'attributes': <Map<String, String>>[
      for (final attribute in summary.attributes)
        <String, String>{'key': attribute.key, 'label': attribute.label, 'value': attribute.value},
    ],
};

PluginContentSummary? _decodeSummary(Map<String, Object?>? data) {
  if (data == null) return null;
  final id = _nonBlankString(data['id']);
  final title = _nonBlankString(data['title']);
  final contentKind = _contentKind(data['contentKind']);
  if (id == null || title == null || contentKind == null) return null;
  final latest = _objectMap(data['latestChapter']);
  final latestTitle = latest == null ? null : _nonBlankString(latest['title']);
  return PluginContentSummary(
    id: id,
    title: title,
    contentKind: contentKind,
    coverOrientation: _coverOrientation(data['coverOrientation'], contentKind),
    author: _nonBlankString(data['author']),
    url: _uri(data['url']),
    coverUrl: _uri(data['coverUrl']),
    description: _nonBlankString(data['description']),
    language: _nonBlankString(data['language']),
    status: _status(data['status']),
    access: _access(data['access']),
    wordCount: _nonNegativeInt(data['wordCount']),
    chapterCount: _nonNegativeInt(data['chapterCount']),
    publishedAt: _dateTime(data['publishedAt']),
    updatedAt: _dateTime(data['updatedAt']),
    latestChapter: latestTitle == null
        ? null
        : PluginLatestChapter(
            id: _nonBlankString(latest?['id']),
            title: latestTitle,
            url: _uri(latest?['url']),
            updatedAt: _dateTime(latest?['updatedAt']),
          ),
    categories: _stringList(data['categories']),
    tags: _stringList(data['tags']),
    attributes: _attributes(data['attributes']),
  );
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

String? _nonBlankString(Object? value) => value is String && value.isNotEmpty ? value : null;

Uri? _uri(Object? value) {
  final text = _nonBlankString(value);
  return text == null ? null : Uri.tryParse(text);
}

DateTime? _dateTime(Object? value) {
  final text = _nonBlankString(value);
  return text == null ? null : DateTime.tryParse(text);
}

int? _nonNegativeInt(Object? value) => value is int && value >= 0 ? value : null;

List<String> _stringList(Object? value) =>
    value is List<Object?> ? List<String>.unmodifiable(value.whereType<String>().where((item) => item.isNotEmpty)) : const <String>[];

List<PluginContentAttribute> _attributes(Object? value) {
  if (value is! List<Object?>) return const <PluginContentAttribute>[];
  final result = <PluginContentAttribute>[];
  for (final item in value) {
    final attribute = _objectMap(item);
    final key = _nonBlankString(attribute?['key']);
    final label = _nonBlankString(attribute?['label']);
    final content = _nonBlankString(attribute?['value']);
    if (key != null && label != null && content != null) {
      result.add(PluginContentAttribute(key: key, label: label, value: content));
    }
  }
  return List<PluginContentAttribute>.unmodifiable(result);
}

PluginContentKind? _contentKind(Object? value) => switch (value) {
  'audio' => PluginContentKind.audio,
  'novel' => PluginContentKind.novel,
  'manga' => PluginContentKind.manga,
  'video' => PluginContentKind.video,
  _ => null,
};

PluginCoverOrientation _coverOrientation(Object? value, PluginContentKind contentKind) => switch (value) {
  'landscape' => PluginCoverOrientation.landscape,
  'portrait' => PluginCoverOrientation.portrait,
  'square' => PluginCoverOrientation.square,
  _ => contentKind == PluginContentKind.video ? PluginCoverOrientation.landscape : PluginCoverOrientation.portrait,
};

PluginContentStatus _status(Object? value) => switch (value) {
  'ongoing' => PluginContentStatus.ongoing,
  'completed' => PluginContentStatus.completed,
  'hiatus' => PluginContentStatus.hiatus,
  _ => PluginContentStatus.unknown,
};

PluginAccessKind _access(Object? value) => switch (value) {
  'free' => PluginAccessKind.free,
  'paid' => PluginAccessKind.paid,
  'mixed' => PluginAccessKind.mixed,
  _ => PluginAccessKind.unknown,
};
