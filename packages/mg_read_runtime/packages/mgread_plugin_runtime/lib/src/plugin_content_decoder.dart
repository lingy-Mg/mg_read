part of mgread_plugin_runtime;

/// Source discovery/content wire decoder implementation.
///
/// It remains a named library part because the decoder intentionally shares
/// the Runtime's private wire error and JSON helpers without exposing them.
final class _DiscoveryDecodeState {
  final Set<String> ids = <String>{};
  int count = 0;
}

PluginDiscoveryTabsComponent _decodeDiscoveryTabs(
  Map<String, Object?> item,
  String id,
) {
  const context = 'Source discovery tabs';
  final tabs = _contentList(
    item,
    'tabs',
    context,
  ).map(_decodeDiscoveryTab).toList(growable: false);
  _requireUnique(tabs.map((tab) => tab.id), context);
  final selectedTabId = _contentNullableString(item, 'selectedTabId', context);
  if ((tabs.isEmpty && selectedTabId != null) ||
      (selectedTabId != null && !tabs.any((tab) => tab.id == selectedTabId))) {
    _contentInvalid('$context contains an invalid selected tab.');
  }
  return PluginDiscoveryTabsComponent(
    id: id,
    tabs: tabs,
    selectedTabId: selectedTabId,
  );
}

PluginDiscoveryContentCollectionComponent _decodeDiscoveryContentCollection(
  Map<String, Object?> item,
  String id,
) {
  const context = 'Source discovery content collection';
  final items = _contentList(
    item,
    'items',
    context,
  ).map(_decodeDiscoveryContentItem).toList(growable: false);
  _requireUnique(items.map((entry) => entry.content.id), context);
  return PluginDiscoveryContentCollectionComponent(
    id: id,
    layout: _discoveryContentLayout(
      _contentString(item, 'layout', context),
      context,
    ),
    items: items,
    continuation: _decodeDiscoveryContinuation(
      _contentField(item, 'continuation', context),
    ),
  );
}

PluginDiscoveryCategoryCollectionComponent _decodeDiscoveryCategoryCollection(
  Map<String, Object?> item,
  String id,
) {
  const context = 'Source discovery category collection';
  final categories = _contentList(
    item,
    'categories',
    context,
  ).map(_decodeDiscoveryCategory).toList(growable: false);
  _requireUnique(categories.map((category) => category.id), context);
  return PluginDiscoveryCategoryCollectionComponent(
    id: id,
    layout: _discoveryCategoryLayout(
      _contentString(item, 'layout', context),
      context,
    ),
    categories: categories,
  );
}

PluginDiscoveryTab _decodeDiscoveryTab(Object? value) {
  const context = 'Source discovery tab';
  final item = _contentObject(value, context);
  return PluginDiscoveryTab(
    id: _contentString(item, 'id', context),
    label: _contentString(item, 'label', context),
    target: _contentString(item, 'target', context),
  );
}

PluginDiscoveryContinuation? _decodeDiscoveryContinuation(Object? value) {
  if (value == null) return null;
  const context = 'Source discovery continuation';
  final item = _contentObject(value, context);
  return PluginDiscoveryContinuation(
    target: _contentString(item, 'target', context),
    cursor: _contentString(item, 'cursor', context),
  );
}

PluginDiscoveryContentItem _decodeDiscoveryContentItem(Object? value) {
  const context = 'Source discovery content item';
  final item = _contentObject(value, context);
  final rawMetric = _contentField(item, 'metric', context);
  return PluginDiscoveryContentItem(
    content: _decodeContentSummary(
      _contentField(item, 'content', context),
      '$context content',
    ),
    rank: _contentNullableInt(item, 'rank', context),
    metric: rawMetric == null ? null : _decodeDiscoveryMetric(rawMetric),
    recommendation: _contentNullableString(item, 'recommendation', context),
  );
}

PluginDiscoveryMetric _decodeDiscoveryMetric(Object? value) {
  const context = 'Source discovery metric';
  final item = _contentObject(value, context);
  return PluginDiscoveryMetric(
    label: _contentString(item, 'label', context),
    value: _contentString(item, 'value', context),
  );
}

PluginDiscoveryCategory _decodeDiscoveryCategory(Object? value) {
  const context = 'Source discovery category';
  final item = _contentObject(value, context);
  return PluginDiscoveryCategory(
    id: _contentString(item, 'id', context),
    title: _contentString(item, 'title', context),
    target: _contentString(item, 'target', context),
    count: _contentNullableInt(item, 'count', context),
    url: _contentNullableUri(item, 'url', context),
  );
}

PluginChapterSummary _decodeChapterSummary(Object? value) {
  const context = 'Source chapter summary';
  final item = _contentObject(value, context);
  return PluginChapterSummary(
    id: _contentString(item, 'id', context),
    title: _contentString(item, 'title', context),
    order: _contentInt(item, 'order', context),
    url: _contentNullableUri(item, 'url', context),
    volumeTitle: _contentNullableString(item, 'volumeTitle', context),
    wordCount: _contentNullableInt(item, 'wordCount', context),
    updatedAt: _contentNullableDateTime(item, 'updatedAt', context),
    isLocked: _contentNullableBool(item, 'isLocked', context),
    attributes: _contentList(item, 'attributes', context)
        .map((raw) => _decodeAttribute(raw, '$context attribute'))
        .toList(growable: false),
  );
}

PluginMangaPage _decodeMangaPage(Object? value) {
  const context = 'Source manga page';
  final item = _contentObject(value, context);
  final url = _contentUri(item, 'url', context);
  return PluginMangaPage(
    id: _contentString(item, 'id', context),
    index: _contentInt(item, 'index', context),
    url: url,
    mimeType: _contentNullableString(item, 'mimeType', context),
    width: _contentNullableInt(item, 'width', context),
    height: _contentNullableInt(item, 'height', context),
  );
}

Map<String, Object?> _contentObject(Object? value, String context) =>
    _jsonObject(value, context);

Object? _contentField(Map<String, Object?> object, String key, String context) {
  if (!object.containsKey(key))
    _contentInvalid('$context is missing the required $key key.');
  return object[key];
}

String _contentString(Map<String, Object?> object, String key, String context) {
  final value = _contentField(object, key, context);
  if (value is! String || value.trim().isEmpty)
    _contentInvalid('$context contains an invalid $key value.');
  return value;
}

String? _contentNullableString(
  Map<String, Object?> object,
  String key,
  String context, {
  bool allowEmpty = false,
}) {
  final value = _contentField(object, key, context);
  if (value == null) return null;
  if (value is! String || (!allowEmpty && value.trim().isEmpty))
    _contentInvalid('$context contains an invalid nullable $key value.');
  return value;
}

int _contentInt(Map<String, Object?> object, String key, String context) {
  final value = _contentField(object, key, context);
  if (value is! int || value < 0 || value > 9007199254740991)
    _contentInvalid('$context contains an invalid $key count.');
  return value;
}

int? _contentNullableInt(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final value = _contentField(object, key, context);
  if (value == null) return null;
  if (value is! int || value < 0 || value > 9007199254740991)
    _contentInvalid('$context contains an invalid nullable $key count.');
  return value;
}

bool? _contentNullableBool(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final value = _contentField(object, key, context);
  if (value == null) return null;
  if (value is! bool)
    _contentInvalid('$context contains an invalid nullable $key flag.');
  return value;
}

List<Object?> _contentList(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final value = _contentField(object, key, context);
  if (value is! List<Object?>)
    _contentInvalid('$context contains an invalid $key list.');
  return value;
}

List<String> _contentStringList(
  Map<String, Object?> object,
  String key,
  String context,
) => _contentList(object, key, context)
    .map((value) {
      if (value is! String || value.trim().isEmpty)
        _contentInvalid('$context contains an invalid $key item.');
      return value;
    })
    .toList(growable: false);

Uri _contentUri(Map<String, Object?> object, String key, String context) {
  final raw = _contentString(object, key, context);
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    _contentInvalid('$context contains an invalid $key URL.');
  }
  return uri;
}

Uri? _contentNullableUri(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final raw = _contentNullableString(object, key, context);
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    _contentInvalid('$context contains an invalid nullable $key URL.');
  }
  return uri;
}

DateTime? _contentNullableDateTime(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final raw = _contentNullableString(object, key, context);
  if (raw == null) return null;
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$',
  ).hasMatch(raw)) {
    _contentInvalid('$context contains an invalid $key timestamp.');
  }
  try {
    return DateTime.parse(raw).toUtc();
  } on FormatException {
    _contentInvalid('$context contains an invalid $key timestamp.');
  }
}

PluginContentKind _contentKind(String value, String context) => switch (value) {
  'novel' => PluginContentKind.novel,
  'manga' => PluginContentKind.manga,
  _ => _contentInvalid('$context contains an unknown content kind.'),
};

PluginContentStatus _contentStatus(String value, String context) =>
    switch (value) {
      'ongoing' => PluginContentStatus.ongoing,
      'completed' => PluginContentStatus.completed,
      'hiatus' => PluginContentStatus.hiatus,
      'unknown' => PluginContentStatus.unknown,
      _ => _contentInvalid('$context contains an unknown content status.'),
    };

PluginAccessKind _contentAccess(String value, String context) =>
    switch (value) {
      'free' => PluginAccessKind.free,
      'paid' => PluginAccessKind.paid,
      'mixed' => PluginAccessKind.mixed,
      'unknown' => PluginAccessKind.unknown,
      _ => _contentInvalid('$context contains an unknown access kind.'),
    };

PluginDiscoveryContentLayout _discoveryContentLayout(
  String value,
  String context,
) => switch (value) {
  'featured' => PluginDiscoveryContentLayout.featured,
  'carousel' => PluginDiscoveryContentLayout.carousel,
  'ranking' => PluginDiscoveryContentLayout.ranking,
  'list' => PluginDiscoveryContentLayout.list,
  _ => _contentInvalid('$context contains an unknown discovery layout.'),
};

PluginDiscoveryCategoryLayout _discoveryCategoryLayout(
  String value,
  String context,
) => switch (value) {
  'grid' => PluginDiscoveryCategoryLayout.grid,
  'list' => PluginDiscoveryCategoryLayout.list,
  _ => _contentInvalid('$context contains an unknown category layout.'),
};

PluginDiscoveryGroupLayout _discoveryGroupLayout(
  String value,
  String context,
) => switch (value) {
  'vertical' => PluginDiscoveryGroupLayout.vertical,
  'horizontal' => PluginDiscoveryGroupLayout.horizontal,
  'grid' => PluginDiscoveryGroupLayout.grid,
  _ => _contentInvalid('$context contains an unknown group layout.'),
};

void _requireMatchingPlugin(
  Map<String, Object?> result,
  String pluginId,
  String context,
) {
  if (_contentString(result, 'pluginId', context) != pluginId)
    _contentInvalid('$context does not match its plugin request.');
}

void _requireUnique(Iterable<String> values, String context) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value))
      _contentInvalid('$context contains duplicate identifiers.');
  }
}

Never _contentInvalid(String message) =>
    throw PluginRuntimeException('invalid_response', message);
