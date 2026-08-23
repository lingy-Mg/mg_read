part of mgread_plugin_runtime;

enum PluginContentKind {
  novel('novel'),
  manga('manga');

  const PluginContentKind(this.code);
  final String code;
}

enum PluginContentStatus {
  ongoing('ongoing'),
  completed('completed'),
  hiatus('hiatus'),
  unknown('unknown');

  const PluginContentStatus(this.code);
  final String code;
}

enum PluginAccessKind {
  free('free'),
  paid('paid'),
  mixed('mixed'),
  unknown('unknown');

  const PluginAccessKind(this.code);
  final String code;
}

enum PluginDiscoveryContentLayout {
  featured('featured'),
  carousel('carousel'),
  ranking('ranking'),
  list('list');

  const PluginDiscoveryContentLayout(this.code);
  final String code;
}

enum PluginDiscoveryCategoryLayout {
  grid('grid'),
  list('list');

  const PluginDiscoveryCategoryLayout(this.code);
  final String code;
}

enum PluginDiscoveryGroupLayout {
  vertical('vertical'),
  horizontal('horizontal'),
  grid('grid');

  const PluginDiscoveryGroupLayout(this.code);
  final String code;
}

@immutable
final class PluginContentAttribute {
  const PluginContentAttribute({
    required this.key,
    required this.label,
    required this.value,
  });

  final String key;
  final String label;
  final String value;
}

@immutable
final class PluginLatestChapter {
  const PluginLatestChapter({
    required this.id,
    required this.title,
    required this.url,
    required this.updatedAt,
  });

  final String? id;
  final String title;
  final Uri? url;
  final DateTime? updatedAt;
}

/// Rich, closed content projection shared by search, discovery and detail.
@immutable
final class PluginContentSummary {
  PluginContentSummary({
    required this.id,
    required this.title,
    required this.contentKind,
    required this.author,
    required this.url,
    required this.coverUrl,
    required this.description,
    required this.language,
    required this.status,
    required this.access,
    required this.wordCount,
    required this.chapterCount,
    required this.publishedAt,
    required this.updatedAt,
    required this.latestChapter,
    required List<String> categories,
    required List<String> tags,
    required List<PluginContentAttribute> attributes,
  }) : categories = List<String>.unmodifiable(categories),
       tags = List<String>.unmodifiable(tags),
       attributes = List<PluginContentAttribute>.unmodifiable(attributes);

  final String id;
  final String title;
  final PluginContentKind contentKind;
  final String? author;
  final Uri? url;
  final Uri? coverUrl;
  final String? description;
  final String? language;
  final PluginContentStatus status;
  final PluginAccessKind access;
  final int? wordCount;
  final int? chapterCount;
  final DateTime? publishedAt;
  final DateTime? updatedAt;
  final PluginLatestChapter? latestChapter;
  final List<String> categories;
  final List<String> tags;
  final List<PluginContentAttribute> attributes;
}

@immutable
final class SourceSearchInvocation
    extends PluginInvocation<PluginSearchResult> {
  const SourceSearchInvocation({
    required this.pluginId,
    required this.query,
    this.cursor,
    this.pageSize = 20,
  });

  final String pluginId;
  final String query;
  final String? cursor;
  final int pageSize;

  @override
  String get _wireMethod => 'source.search.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'query': query,
    'cursor': cursor,
    'pageSize': pageSize,
  };

  @override
  PluginSearchResult _decodeResult(Object? value) {
    final result = _contentObject(value, 'Source search result');
    _requireMatchingPlugin(result, pluginId, 'Source search result');
    final items = _contentList(result, 'items', 'Source search result')
        .map((raw) => _decodeContentSummary(raw, 'Source search item'))
        .toList(growable: false);
    _requireUnique(items.map((item) => item.id), 'Source search result');
    return PluginSearchResult(
      pluginId: pluginId,
      sourceName: _contentString(result, 'sourceName', 'Source search result'),
      items: items,
      nextCursor: _contentNullableString(
        result,
        'nextCursor',
        'Source search result',
      ),
      totalCount: _contentNullableInt(
        result,
        'totalCount',
        'Source search result',
      ),
    );
  }
}

@immutable
final class PluginSearchResult {
  PluginSearchResult({
    required this.pluginId,
    required this.sourceName,
    required List<PluginContentSummary> items,
    required this.nextCursor,
    required this.totalCount,
  }) : items = List<PluginContentSummary>.unmodifiable(items);

  final String pluginId;
  final String sourceName;
  final List<PluginContentSummary> items;
  final String? nextCursor;
  final int? totalCount;
}

@immutable
final class SourceSearchSuggestionsInvocation
    extends PluginInvocation<PluginSearchSuggestionsResult> {
  const SourceSearchSuggestionsInvocation({
    required this.pluginId,
    this.cursor,
    this.pageSize = 20,
  });

  final String pluginId;
  final String? cursor;
  final int pageSize;

  @override
  String get _wireMethod => 'source.searchSuggestions.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'cursor': cursor,
    'pageSize': pageSize,
  };

  @override
  PluginSearchSuggestionsResult _decodeResult(Object? value) {
    final result = _contentObject(value, 'Source search suggestions result');
    _requireMatchingPlugin(result, pluginId, 'Source search suggestions result');
    final items = _contentList(
      result,
      'items',
      'Source search suggestions result',
    ).map((raw) {
      final item = _contentObject(raw, 'Source search suggestion');
      return PluginSearchSuggestion(
        query: _contentString(item, 'query', 'Source search suggestion'),
        metric: _contentNullableString(
          item,
          'metric',
          'Source search suggestion',
        ),
      );
    }).toList(growable: false);
    _requireUnique(
      items.map((item) => item.query),
      'Source search suggestions result',
    );
    return PluginSearchSuggestionsResult(
      pluginId: pluginId,
      sourceName: _contentString(
        result,
        'sourceName',
        'Source search suggestions result',
      ),
      items: items,
      nextCursor: _contentNullableString(
        result,
        'nextCursor',
        'Source search suggestions result',
      ),
    );
  }
}

@immutable
final class PluginSearchSuggestionsResult {
  PluginSearchSuggestionsResult({
    required this.pluginId,
    required this.sourceName,
    required List<PluginSearchSuggestion> items,
    required this.nextCursor,
  }) : items = List<PluginSearchSuggestion>.unmodifiable(items);

  final String pluginId;
  final String sourceName;
  final List<PluginSearchSuggestion> items;
  final String? nextCursor;
}

@immutable
final class PluginSearchSuggestion {
  const PluginSearchSuggestion({required this.query, required this.metric});

  final String query;
  final String? metric;
}

@immutable
final class SourceDiscoverInvocation
    extends PluginInvocation<PluginDiscoverResult> {
  const SourceDiscoverInvocation({
    required this.pluginId,
    this.target,
    this.cursor,
    this.collectionId,
    this.pageSize = 20,
  });

  final String pluginId;
  final String? target;
  final String? cursor;
  final String? collectionId;
  final int pageSize;

  @override
  String get _wireMethod => 'source.discover.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'target': target,
    'cursor': cursor,
    'collectionId': collectionId,
    'pageSize': pageSize,
  };

  @override
  PluginDiscoverResult _decodeResult(Object? value) {
    final result = _contentObject(value, 'Source discovery result');
    _requireMatchingPlugin(result, pluginId, 'Source discovery result');
    final sourceName = _contentString(
      result,
      'sourceName',
      'Source discovery result',
    );
    return switch (_contentString(result, 'kind', 'Source discovery result')) {
      'document' => PluginDiscoveryDocumentResult(
        pluginId: pluginId,
        sourceName: sourceName,
        document: _decodeDiscoveryDocument(
          _contentField(result, 'document', 'Source discovery result'),
        ),
      ),
      'append' => PluginDiscoveryAppendResult(
        pluginId: pluginId,
        sourceName: sourceName,
        collectionId: _contentString(
          result,
          'collectionId',
          'Source discovery result',
        ),
        items: _contentList(
          result,
          'items',
          'Source discovery result',
        ).map(_decodeDiscoveryContentItem).toList(growable: false),
        continuation: _decodeDiscoveryContinuation(
          _contentField(result, 'continuation', 'Source discovery result'),
        ),
      ),
      _ => _contentInvalid(
        'Source discovery result has an unknown result kind.',
      ),
    };
  }
}

@immutable
sealed class PluginDiscoverResult {
  const PluginDiscoverResult({
    required this.pluginId,
    required this.sourceName,
  });

  final String pluginId;
  final String sourceName;
}

@immutable
final class PluginDiscoveryDocumentResult extends PluginDiscoverResult {
  const PluginDiscoveryDocumentResult({
    required super.pluginId,
    required super.sourceName,
    required this.document,
  });

  final PluginDiscoveryDocument document;
}

@immutable
final class PluginDiscoveryAppendResult extends PluginDiscoverResult {
  PluginDiscoveryAppendResult({
    required super.pluginId,
    required super.sourceName,
    required this.collectionId,
    required List<PluginDiscoveryContentItem> items,
    required this.continuation,
  }) : items = List<PluginDiscoveryContentItem>.unmodifiable(items);

  final String collectionId;
  final List<PluginDiscoveryContentItem> items;
  final PluginDiscoveryContinuation? continuation;
}

@immutable
final class PluginDiscoveryTab {
  const PluginDiscoveryTab({
    required this.id,
    required this.label,
    required this.target,
  });

  final String id;
  final String label;
  final String target;
}

@immutable
final class PluginDiscoveryMetric {
  const PluginDiscoveryMetric({required this.label, required this.value});

  final String label;
  final String value;
}

@immutable
final class PluginDiscoveryContentItem {
  const PluginDiscoveryContentItem({
    required this.content,
    required this.rank,
    required this.metric,
    required this.recommendation,
  });

  final PluginContentSummary content;
  final int? rank;
  final PluginDiscoveryMetric? metric;
  final String? recommendation;
}

@immutable
final class PluginDiscoveryCategory {
  const PluginDiscoveryCategory({
    required this.id,
    required this.title,
    required this.target,
    required this.count,
    required this.url,
  });

  final String id;
  final String title;
  final String target;
  final int? count;
  final Uri? url;
}

@immutable
final class PluginDiscoveryContinuation {
  const PluginDiscoveryContinuation({
    required this.target,
    required this.cursor,
  });

  final String target;
  final String cursor;
}

@immutable
final class PluginDiscoveryDocument {
  PluginDiscoveryDocument({required List<PluginDiscoveryComponent> components})
    : components = List<PluginDiscoveryComponent>.unmodifiable(components);

  final List<PluginDiscoveryComponent> components;
}

@immutable
sealed class PluginDiscoveryComponent {
  const PluginDiscoveryComponent({required this.id});

  final String id;
}

final class PluginDiscoveryTabsComponent extends PluginDiscoveryComponent {
  PluginDiscoveryTabsComponent({
    required super.id,
    required List<PluginDiscoveryTab> tabs,
    required this.selectedTabId,
  }) : tabs = List<PluginDiscoveryTab>.unmodifiable(tabs);

  final List<PluginDiscoveryTab> tabs;
  final String? selectedTabId;
}

final class PluginDiscoverySectionComponent extends PluginDiscoveryComponent {
  PluginDiscoverySectionComponent({
    required super.id,
    required this.title,
    required this.subtitle,
    required List<PluginDiscoveryComponent> children,
  }) : children = List<PluginDiscoveryComponent>.unmodifiable(children);

  final String title;
  final String? subtitle;
  final List<PluginDiscoveryComponent> children;
}

final class PluginDiscoveryGroupComponent extends PluginDiscoveryComponent {
  PluginDiscoveryGroupComponent({
    required super.id,
    required this.layout,
    required List<PluginDiscoveryComponent> children,
  }) : children = List<PluginDiscoveryComponent>.unmodifiable(children);

  final PluginDiscoveryGroupLayout layout;
  final List<PluginDiscoveryComponent> children;
}

final class PluginDiscoveryContentCollectionComponent
    extends PluginDiscoveryComponent {
  PluginDiscoveryContentCollectionComponent({
    required super.id,
    required this.layout,
    required List<PluginDiscoveryContentItem> items,
    required this.continuation,
  }) : items = List<PluginDiscoveryContentItem>.unmodifiable(items);

  final PluginDiscoveryContentLayout layout;
  final List<PluginDiscoveryContentItem> items;
  final PluginDiscoveryContinuation? continuation;
}

final class PluginDiscoveryCategoryCollectionComponent
    extends PluginDiscoveryComponent {
  PluginDiscoveryCategoryCollectionComponent({
    required super.id,
    required this.layout,
    required List<PluginDiscoveryCategory> categories,
  }) : categories = List<PluginDiscoveryCategory>.unmodifiable(categories);

  final PluginDiscoveryCategoryLayout layout;
  final List<PluginDiscoveryCategory> categories;
}

final class PluginDiscoveryTextComponent extends PluginDiscoveryComponent {
  const PluginDiscoveryTextComponent({required super.id, required this.text});

  final String text;
}

final class PluginDiscoveryDividerComponent extends PluginDiscoveryComponent {
  const PluginDiscoveryDividerComponent({required super.id});
}

@immutable
final class SourceDetailInvocation
    extends PluginInvocation<PluginContentDetail> {
  const SourceDetailInvocation({required this.pluginId, required this.id});

  final String pluginId;
  final String id;

  @override
  String get _wireMethod => 'source.getDetail.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'id': id,
  };

  @override
  PluginContentDetail _decodeResult(Object? value) {
    final result = _contentObject(value, 'Source detail result');
    _requireMatchingPlugin(result, pluginId, 'Source detail result');
    final summary = _decodeContentSummary(result, 'Source detail summary');
    if (summary.id != id) {
      _contentInvalid('Source detail result does not match its request.');
    }
    return PluginContentDetail(
      pluginId: pluginId,
      sourceName: _contentString(result, 'sourceName', 'Source detail result'),
      summary: summary,
      aliases: _contentStringList(result, 'aliases', 'Source detail result'),
      catalogUrl: _contentNullableUri(
        result,
        'catalogUrl',
        'Source detail result',
      ),
    );
  }
}

@immutable
final class PluginContentDetail {
  PluginContentDetail({
    required this.pluginId,
    required this.sourceName,
    required this.summary,
    required List<String> aliases,
    required this.catalogUrl,
  }) : aliases = List<String>.unmodifiable(aliases);

  final String pluginId;
  final String sourceName;
  final PluginContentSummary summary;
  final List<String> aliases;
  final Uri? catalogUrl;
}

@immutable
final class SourceChaptersInvocation
    extends PluginInvocation<PluginChaptersResult> {
  const SourceChaptersInvocation({
    required this.pluginId,
    required this.id,
    this.cursor,
    this.pageSize = 50,
  });

  final String pluginId;
  final String id;
  final String? cursor;
  final int pageSize;

  @override
  String get _wireMethod => 'source.getChapters.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'id': id,
    'cursor': cursor,
    'pageSize': pageSize,
  };

  @override
  PluginChaptersResult _decodeResult(Object? value) {
    final result = _contentObject(value, 'Source chapters result');
    _requireMatchingPlugin(result, pluginId, 'Source chapters result');
    final items = _contentList(
      result,
      'items',
      'Source chapters result',
    ).map(_decodeChapterSummary).toList(growable: false);
    _requireUnique(items.map((item) => item.id), 'Source chapters result');
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: _contentString(
        result,
        'sourceName',
        'Source chapters result',
      ),
      items: items,
      nextCursor: _contentNullableString(
        result,
        'nextCursor',
        'Source chapters result',
      ),
      totalCount: _contentNullableInt(
        result,
        'totalCount',
        'Source chapters result',
      ),
    );
  }
}

@immutable
final class PluginChaptersResult {
  PluginChaptersResult({
    required this.pluginId,
    required this.sourceName,
    required List<PluginChapterSummary> items,
    required this.nextCursor,
    required this.totalCount,
  }) : items = List<PluginChapterSummary>.unmodifiable(items);

  final String pluginId;
  final String sourceName;
  final List<PluginChapterSummary> items;
  final String? nextCursor;
  final int? totalCount;
}

@immutable
final class PluginChapterSummary {
  PluginChapterSummary({
    required this.id,
    required this.title,
    required this.order,
    required this.url,
    required this.volumeTitle,
    required this.wordCount,
    required this.updatedAt,
    required this.isLocked,
    required List<PluginContentAttribute> attributes,
  }) : attributes = List<PluginContentAttribute>.unmodifiable(attributes);

  final String id;
  final String title;
  final int order;
  final Uri? url;
  final String? volumeTitle;
  final int? wordCount;
  final DateTime? updatedAt;
  final bool? isLocked;
  final List<PluginContentAttribute> attributes;
}

@immutable
final class SourceContentInvocation
    extends PluginInvocation<PluginChapterContent> {
  const SourceContentInvocation({
    required this.pluginId,
    required this.id,
    required this.chapterId,
  });

  final String pluginId;
  final String id;
  final String chapterId;

  @override
  String get _wireMethod => 'source.getContent.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'pluginId': pluginId,
    'id': id,
    'chapterId': chapterId,
  };

  @override
  PluginChapterContent _decodeResult(Object? value) {
    final result = _contentObject(value, 'Source content result');
    _requireMatchingPlugin(result, pluginId, 'Source content result');
    final resultChapterId = _contentString(
      result,
      'chapterId',
      'Source content result',
    );
    if (resultChapterId != chapterId) {
      _contentInvalid('Source content result does not match its request.');
    }
    final contentKind = _contentKind(
      _contentString(result, 'contentKind', 'Source content result'),
      'Source content result',
    );
    final text = _contentNullableString(
      result,
      'text',
      'Source content result',
      allowEmpty: true,
    );
    final pages = _contentList(
      result,
      'pages',
      'Source content result',
    ).map(_decodeMangaPage).toList(growable: false);
    _requireUnique(pages.map((page) => page.id), 'Source content pages');
    for (var index = 0; index < pages.length; index += 1) {
      if (pages[index].index != index) {
        _contentInvalid('Source content pages are not zero-based and ordered.');
      }
    }
    if ((contentKind == PluginContentKind.novel && text == null) ||
        (contentKind == PluginContentKind.novel && pages.isNotEmpty) ||
        (contentKind == PluginContentKind.manga && text != null) ||
        (contentKind == PluginContentKind.manga && pages.isEmpty)) {
      _contentInvalid('Source content result has inconsistent content fields.');
    }
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: _contentString(result, 'sourceName', 'Source content result'),
      contentKind: contentKind,
      chapterId: resultChapterId,
      title: _contentNullableString(result, 'title', 'Source content result'),
      updatedAt: _contentNullableDateTime(
        result,
        'updatedAt',
        'Source content result',
      ),
      text: text,
      pages: pages,
    );
  }
}

@immutable
final class PluginChapterContent {
  PluginChapterContent({
    required this.pluginId,
    required this.sourceName,
    required this.contentKind,
    required this.chapterId,
    required this.title,
    required this.updatedAt,
    required this.text,
    required List<PluginMangaPage> pages,
  }) : pages = List<PluginMangaPage>.unmodifiable(pages);

  final String pluginId;
  final String sourceName;
  final PluginContentKind contentKind;
  final String chapterId;
  final String? title;
  final DateTime? updatedAt;
  final String? text;
  final List<PluginMangaPage> pages;
}

@immutable
final class PluginMangaPage {
  const PluginMangaPage({
    required this.id,
    required this.index,
    required this.url,
    required this.mimeType,
    required this.width,
    required this.height,
  });

  final String id;
  final int index;
  final Uri url;
  final String? mimeType;
  final int? width;
  final int? height;
}

PluginContentSummary _decodeContentSummary(Object? value, String context) {
  final item = _contentObject(value, context);
  return PluginContentSummary(
    id: _contentString(item, 'id', context),
    title: _contentString(item, 'title', context),
    contentKind: _contentKind(
      _contentString(item, 'contentKind', context),
      context,
    ),
    author: _contentNullableString(item, 'author', context),
    url: _contentNullableUri(item, 'url', context),
    coverUrl: _contentNullableUri(item, 'coverUrl', context),
    description: _contentNullableString(item, 'description', context),
    language: _contentNullableString(item, 'language', context),
    status: _contentStatus(_contentString(item, 'status', context), context),
    access: _contentAccess(_contentString(item, 'access', context), context),
    wordCount: _contentNullableInt(item, 'wordCount', context),
    chapterCount: _contentNullableInt(item, 'chapterCount', context),
    publishedAt: _contentNullableDateTime(item, 'publishedAt', context),
    updatedAt: _contentNullableDateTime(item, 'updatedAt', context),
    latestChapter: _decodeLatestChapter(item, context),
    categories: _contentStringList(item, 'categories', context),
    tags: _contentStringList(item, 'tags', context),
    attributes: _contentList(item, 'attributes', context)
        .map((raw) => _decodeAttribute(raw, '$context attribute'))
        .toList(growable: false),
  );
}

PluginLatestChapter? _decodeLatestChapter(
  Map<String, Object?> item,
  String context,
) {
  final raw = _contentField(item, 'latestChapter', context);
  if (raw == null) return null;
  final chapter = _contentObject(raw, '$context latest chapter');
  return PluginLatestChapter(
    id: _contentNullableString(chapter, 'id', context),
    title: _contentString(chapter, 'title', context),
    url: _contentNullableUri(chapter, 'url', context),
    updatedAt: _contentNullableDateTime(chapter, 'updatedAt', context),
  );
}

PluginContentAttribute _decodeAttribute(Object? value, String context) {
  final item = _contentObject(value, context);
  return PluginContentAttribute(
    key: _contentString(item, 'key', context),
    label: _contentString(item, 'label', context),
    value: _contentString(item, 'value', context),
  );
}

PluginDiscoveryDocument _decodeDiscoveryDocument(Object? value) {
  const context = 'Source discovery document';
  final document = _contentObject(value, context);
  final state = _DiscoveryDecodeState();
  final components = _contentList(document, 'components', context)
      .asMap()
      .entries
      .map(
        (entry) => _decodeDiscoveryComponent(
          entry.value,
          state,
          depth: 1,
          isFirstRootComponent: entry.key == 0,
        ),
      )
      .toList(growable: false);
  final tabCount = components.whereType<PluginDiscoveryTabsComponent>().length;
  if (tabCount > 1 ||
      (tabCount == 1 && components.first is! PluginDiscoveryTabsComponent)) {
    _contentInvalid('$context has an invalid tabs placement.');
  }
  return PluginDiscoveryDocument(components: components);
}

PluginDiscoveryComponent _decodeDiscoveryComponent(
  Object? value,
  _DiscoveryDecodeState state, {
  required int depth,
  required bool isFirstRootComponent,
}) {
  const context = 'Source discovery component';
  if (depth > 8 || ++state.count > 128) {
    _contentInvalid('$context exceeds its bounded nesting budget.');
  }
  final item = _contentObject(value, context);
  final id = _contentString(item, 'id', context);
  if (!state.ids.add(id)) _contentInvalid('$context has a duplicate id.');
  final type = _contentString(item, 'type', context);
  List<PluginDiscoveryComponent> children() =>
      _contentList(item, 'children', context)
          .map(
            (child) => _decodeDiscoveryComponent(
              child,
              state,
              depth: depth + 1,
              isFirstRootComponent: false,
            ),
          )
          .toList(growable: false);
  return switch (type) {
    'tabs' when depth == 1 && isFirstRootComponent => _decodeDiscoveryTabs(
      item,
      id,
    ),
    'section' => PluginDiscoverySectionComponent(
      id: id,
      title: _contentString(item, 'title', context),
      subtitle: _contentNullableString(item, 'subtitle', context),
      children: children(),
    ),
    'group' => PluginDiscoveryGroupComponent(
      id: id,
      layout: _discoveryGroupLayout(
        _contentString(item, 'layout', context),
        context,
      ),
      children: children(),
    ),
    'contentCollection' => _decodeDiscoveryContentCollection(item, id),
    'categoryCollection' => _decodeDiscoveryCategoryCollection(item, id),
    'text' => PluginDiscoveryTextComponent(
      id: id,
      text: _contentString(item, 'text', context),
    ),
    'divider' => PluginDiscoveryDividerComponent(id: id),
    _ => _contentInvalid('$context has an unknown or misplaced type.'),
  };
}

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

Map<String, Object?> _contentObject(Object? value, String context) {
  return _jsonObject(value, context);
}

Object? _contentField(Map<String, Object?> object, String key, String context) {
  if (!object.containsKey(key)) {
    _contentInvalid('$context is missing the required $key key.');
  }
  return object[key];
}

String _contentString(Map<String, Object?> object, String key, String context) {
  final value = _contentField(object, key, context);
  if (value is! String || value.trim().isEmpty) {
    _contentInvalid('$context contains an invalid $key value.');
  }
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
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    _contentInvalid('$context contains an invalid nullable $key value.');
  }
  return value;
}

int _contentInt(Map<String, Object?> object, String key, String context) {
  final value = _contentField(object, key, context);
  if (value is! int || value < 0 || value > 9007199254740991) {
    _contentInvalid('$context contains an invalid $key count.');
  }
  return value;
}

int? _contentNullableInt(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final value = _contentField(object, key, context);
  if (value == null) return null;
  if (value is! int || value < 0 || value > 9007199254740991) {
    _contentInvalid('$context contains an invalid nullable $key count.');
  }
  return value;
}

bool? _contentNullableBool(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final value = _contentField(object, key, context);
  if (value == null) return null;
  if (value is! bool) {
    _contentInvalid('$context contains an invalid nullable $key flag.');
  }
  return value;
}

List<Object?> _contentList(
  Map<String, Object?> object,
  String key,
  String context,
) {
  final value = _contentField(object, key, context);
  if (value is! List<Object?>) {
    _contentInvalid('$context contains an invalid $key list.');
  }
  return value;
}

List<String> _contentStringList(
  Map<String, Object?> object,
  String key,
  String context,
) {
  return _contentList(object, key, context)
      .map((value) {
        if (value is! String || value.trim().isEmpty) {
          _contentInvalid('$context contains an invalid $key item.');
        }
        return value;
      })
      .toList(growable: false);
}

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
  if (_contentString(result, 'pluginId', context) != pluginId) {
    _contentInvalid('$context does not match its plugin request.');
  }
}

void _requireUnique(Iterable<String> values, String context) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) {
      _contentInvalid('$context contains duplicate identifiers.');
    }
  }
}

Never _contentInvalid(String message) {
  throw PluginRuntimeException('invalid_response', message);
}
