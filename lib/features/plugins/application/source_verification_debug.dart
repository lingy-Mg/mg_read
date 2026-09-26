/// CLI 显式调试模式的内容投影；页面与普通报告不持有这些完整内容。
part of 'source_verification_engine.dart';

Map<String, Object?> _debugDiscover(PluginDiscoverResult result) => switch (result) {
  PluginDiscoveryDocumentResult(:final document) => <String, Object?>{
    'kind': 'document',
    'pluginId': result.pluginId,
    'sourceName': result.sourceName,
    'document': <String, Object?>{'components': document.components.map(_debugDiscoveryComponent).toList(growable: false)},
  },
  PluginDiscoveryAppendResult(:final collectionId, :final items, :final continuation) => <String, Object?>{
    'kind': 'append',
    'pluginId': result.pluginId,
    'sourceName': result.sourceName,
    'collectionId': collectionId,
    'items': items.map(_debugDiscoveryContentItem).toList(growable: false),
    'continuation': continuation == null ? null : <String, Object?>{'target': continuation.target, 'cursor': continuation.cursor},
  },
};

Map<String, Object?> _debugDiscoveryComponent(PluginDiscoveryComponent component) => switch (component) {
  PluginDiscoveryTabsComponent(:final tabs, :final selectedTabId) => <String, Object?>{
    'type': 'tabs',
    'id': component.id,
    'tabs': tabs
        .map((tab) => <String, Object?>{'id': tab.id, 'label': tab.label, 'target': tab.target, 'icon': tab.icon?.code})
        .toList(growable: false),
    'selectedTabId': selectedTabId,
  },
  PluginDiscoverySectionComponent(:final title, :final subtitle, :final children, :final icon) => <String, Object?>{
    'type': 'section',
    'id': component.id,
    'title': title,
    'subtitle': subtitle,
    'icon': icon?.code,
    'children': children.map(_debugDiscoveryComponent).toList(growable: false),
  },
  PluginDiscoveryGroupComponent(:final layout, :final children) => <String, Object?>{
    'type': 'group',
    'id': component.id,
    'layout': layout.code,
    'children': children.map(_debugDiscoveryComponent).toList(growable: false),
  },
  PluginDiscoveryContentCollectionComponent(:final layout, :final items, :final continuation) => <String, Object?>{
    'type': 'contentCollection',
    'id': component.id,
    'layout': layout.code,
    'items': items.map(_debugDiscoveryContentItem).toList(growable: false),
    'continuation': continuation == null ? null : <String, Object?>{'target': continuation.target, 'cursor': continuation.cursor},
  },
  PluginDiscoveryCategoryCollectionComponent(:final layout, :final categories) => <String, Object?>{
    'type': 'categoryCollection',
    'id': component.id,
    'layout': layout.code,
    'categories': categories
        .map(
          (category) => <String, Object?>{
            'id': category.id,
            'title': category.title,
            'target': category.target,
            'count': category.count,
            'url': category.url?.toString(),
            'icon': category.icon?.code,
          },
        )
        .toList(growable: false),
  },
  PluginDiscoveryTextComponent(:final text) => <String, Object?>{'type': 'text', 'id': component.id, 'text': text},
  PluginDiscoveryDividerComponent() => <String, Object?>{'type': 'divider', 'id': component.id},
};

Map<String, Object?> _debugDiscoveryContentItem(PluginDiscoveryContentItem item) => <String, Object?>{
  'content': _debugSummary(item.content),
  'rank': item.rank,
  'metric': item.metric == null ? null : <String, Object?>{'label': item.metric!.label, 'value': item.metric!.value},
  'recommendation': item.recommendation,
};

Map<String, Object?> _debugSearch(PluginSearchResult result) => <String, Object?>{
  'pluginId': result.pluginId,
  'sourceName': result.sourceName,
  'items': result.items.map(_debugSummary).toList(growable: false),
  'nextCursor': result.nextCursor,
  'totalCount': result.totalCount,
};

Map<String, Object?> _debugDetail(PluginContentDetail result) => <String, Object?>{
  'pluginId': result.pluginId,
  'sourceName': result.sourceName,
  'summary': _debugSummary(result.summary),
  'aliases': result.aliases,
  'catalogUrl': result.catalogUrl?.toString(),
};

Map<String, Object?> _debugChapters(PluginChaptersResult result) => <String, Object?>{
  'pluginId': result.pluginId,
  'sourceName': result.sourceName,
  'items': result.items.map(_debugChapter).toList(growable: false),
  'groups': result.groups
      .map(
        (group) => <String, Object?>{
          'id': group.id,
          'title': group.title,
          'order': group.order,
          'episodes': group.episodes.map(_debugChapter).toList(growable: false),
        },
      )
      .toList(growable: false),
};

Map<String, Object?> _debugContent(PluginChapterContent result) => <String, Object?>{
  'pluginId': result.pluginId,
  'sourceName': result.sourceName,
  'contentKind': result.contentKind.code,
  'chapterId': result.chapterId,
  'title': result.title,
  'updatedAt': result.updatedAt?.toIso8601String(),
  'text': result.text,
  'pages': result.pages
      .map(
        (page) => <String, Object?>{
          'id': page.id,
          'index': page.index,
          'url': page.url.toString(),
          'mimeType': page.mimeType,
          'width': page.width,
          'height': page.height,
          'resourcePolicy': page.resourcePolicy.code,
          'expiresAt': page.expiresAt?.toIso8601String(),
        },
      )
      .toList(growable: false),
  'media': result.media == null
      ? null
      : <String, Object?>{
          'url': result.media!.url.toString(),
          'resourceType': result.media!.resourceType.code,
          'resourcePolicy': result.media!.resourcePolicy.code,
          'expiresAt': result.media!.expiresAt?.toIso8601String(),
          'mimeType': result.media!.mimeType,
          'headers': result.media!.headers,
        },
};

Map<String, Object?> _debugSummary(PluginContentSummary result) => <String, Object?>{
  'id': result.id,
  'title': result.title,
  'contentKind': result.contentKind.code,
  'coverOrientation': result.coverOrientation.code,
  'author': result.author,
  'url': result.url?.toString(),
  'coverUrl': result.coverUrl?.toString(),
  'coverBytesLength': result.coverBytes?.length,
  'description': result.description,
  'language': result.language,
  'status': result.status.code,
  'access': result.access.code,
  'wordCount': result.wordCount,
  'chapterCount': result.chapterCount,
  'publishedAt': result.publishedAt?.toIso8601String(),
  'updatedAt': result.updatedAt?.toIso8601String(),
  'latestChapter': result.latestChapter == null
      ? null
      : <String, Object?>{
          'id': result.latestChapter!.id,
          'title': result.latestChapter!.title,
          'url': result.latestChapter!.url?.toString(),
          'updatedAt': result.latestChapter!.updatedAt?.toIso8601String(),
        },
  'categories': result.categories,
  'tags': result.tags,
  'attributes': result.attributes.map(_debugAttribute).toList(growable: false),
};

Map<String, Object?> _debugChapter(PluginChapterSummary chapter) => <String, Object?>{
  'id': chapter.id,
  'title': chapter.title,
  'order': chapter.order,
  'url': chapter.url?.toString(),
  'volumeTitle': chapter.volumeTitle,
  'wordCount': chapter.wordCount,
  'updatedAt': chapter.updatedAt?.toIso8601String(),
  'isLocked': chapter.isLocked,
  'attributes': chapter.attributes.map(_debugAttribute).toList(growable: false),
};

Map<String, Object?> _debugAttribute(PluginContentAttribute attribute) => <String, Object?>{
  'key': attribute.key,
  'label': attribute.label,
  'value': attribute.value,
};
