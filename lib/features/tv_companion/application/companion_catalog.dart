/// Bounded TV-side browsing over existing source and ContentLibrary ports.
/// Search never drives a TV route or interrupts the current playback.
part of 'companion_controller.dart';

extension CompanionCatalog on CompanionController {
  Future<Map<String, Object?>> _searchCatalog(String peerId, Map<String, Object?> args) async {
    final query = companionText(args, 'query', max: 512).trim();
    if (query.runes.length > 256) throw const CompanionFailure('query_too_long');
    final pluginId = args['pluginId'] as String?;
    final cursor = args['cursor'] as String?;
    var session = _searchSessions[peerId];
    if (cursor != null) {
      if (session == null ||
          session.token != cursor ||
          session.query != query ||
          session.pluginId != pluginId ||
          _clock.elapsedMilliseconds - session.lastUsedMs > 120000) {
        throw const CompanionFailure('search_session_expired');
      }
    } else {
      _searchCancellations.remove(peerId)?.cancel();
      final sources = (await ref.read(sourceContentGatewayProvider).listSources())
          .where((source) => source.contentKinds.contains(PluginContentKind.video) && (pluginId == null || source.id == pluginId))
          .toList();
      if (sources.isEmpty) throw const CompanionFailure('source_unavailable');
      if (sources.length > 128) throw const CompanionFailure('too_many_sources');
      session = _TvSearchSession(query, pluginId, sources, _clock.elapsedMilliseconds);
      _searchSessions[peerId] = session;
    }
    final current = session;
    final cancellation = PluginInvocationCancellation();
    _searchCancellations.remove(peerId)?.cancel();
    _searchCancellations[peerId] = cancellation;
    try {
      var unseen =
          current.result
              ?.sortedItems(SearchResultSortOrder.relevance)
              .where((item) => item.content.contentKind == PluginContentKind.video && !current.shown.contains(item.key))
              .toList() ??
          <AggregatedSearchItem>[];
      if (current.result == null || (unseen.isEmpty && current.result!.hasMore && current.totalHits < 2000)) {
        current.result = await BatchSearchCoordinator(
          ref.read(sourceContentGatewayProvider),
        ).run(query: query, sources: current.sources, cancellation: cancellation, previous: current.result);
        if (cancellation.isCancelled) throw const CompanionFailure('search_cancelled');
        unseen = current.result!
            .sortedItems(SearchResultSortOrder.relevance)
            .where((item) => item.content.contentKind == PluginContentKind.video && !current.shown.contains(item.key))
            .toList();
      }
      final items = <Map<String, Object?>>[];
      var bytes = 0;
      for (final item in unseen) {
        final row = {
          ..._catalogItem(item.primary.source, item.content),
          'resultKey': item.key,
          'variantCount': item.variants.length,
          'variants': [for (final variant in item.variants.take(8)) _catalogItem(variant.source, variant.content)],
        };
        final size = utf8.encode(jsonEncode(row)).length;
        if (bytes + size > 48 * 1024 || items.length >= 20) break;
        items.add(row);
        bytes += size;
        current.shown.add(item.key);
      }
      if (items.isEmpty && unseen.isNotEmpty) throw const CompanionFailure('response_too_large');
      final canMore = unseen.length > items.length || (current.result!.hasMore && current.totalHits < 2000);
      current.token = companionToken();
      current.lastUsedMs = _clock.elapsedMilliseconds;
      return {
        'items': items,
        'cursor': canMore ? current.token : null,
        'hasMore': canMore,
        'windowFull': current.totalHits >= 2000,
        'failures': [
          for (final source in current.result!.failedSources.take(16)) {'pluginId': source.source.id, 'label': source.source.displayName},
        ],
      };
    } finally {
      if (identical(_searchCancellations[peerId], cancellation)) _searchCancellations.remove(peerId);
    }
  }

  Future<Map<String, Object?>> _catalogRequest(String peerId, String method, Map<String, Object?> args) async {
    final gateway = ref.read(sourceContentGatewayProvider);
    if (method == 'sources') {
      final sources = (await gateway.listSources()).where((source) => source.contentKinds.contains(PluginContentKind.video));
      return {
        'sources': [
          for (final source in sources.take(128)) {'id': source.id, 'label': source.displayName, 'version': source.pluginVersion},
        ],
      };
    }
    if (method == 'search') return _searchCatalog(peerId, args);
    if (method == 'variants') {
      final session = _searchSessions[peerId];
      final key = companionText(args, 'resultKey');
      final item = session?.result?.items.where((item) => item.key == key).firstOrNull;
      if (item == null) throw const CompanionFailure('search_session_expired');
      final offset = args['offset'] ?? 0;
      if (offset is! int || offset < 0) throw const CompanionFailure('invalid_page');
      final variants = item.variants.skip(offset).take(20).map((hit) => _catalogItem(hit.source, hit.content)).toList();
      return _boundedRows('items', variants, offset: offset, total: item.variants.length);
    }
    if (method == 'detail' || method == 'catalog' || method == 'episodes') {
      final pluginId = companionText(args, 'pluginId');
      final contentId = companionText(args, 'contentId');
      final sources = await gateway.listSources();
      if (!sources.any((source) => source.id == pluginId && source.contentKinds.contains(PluginContentKind.video))) {
        throw const CompanionFailure('source_unavailable');
      }
      if (method == 'detail') {
        final detail = await gateway.getDetail(pluginId: pluginId, id: contentId);
        if (detail.summary.contentKind != PluginContentKind.video) throw const CompanionFailure('content_kind_unsupported');
        return {
          'title': detail.summary.title,
          'description': (detail.summary.description ?? '').substring(0, (detail.summary.description ?? '').length.clamp(0, 3000)),
          'pluginId': pluginId,
          'contentId': contentId,
        };
      }
      var catalog = await gateway.getChapters(pluginId: pluginId, id: contentId);
      var groups = catalog.groups;
      if (groups.isEmpty) groups = [PluginMediaGroup(id: 'default', title: '默认分组', order: 0, episodes: catalog.items)];
      if (method == 'catalog') {
        final offset = args['offset'] ?? 0;
        if (offset is! int || offset < 0 || offset > 5000) throw const CompanionFailure('invalid_page');
        return _boundedRows(
          'groups',
          [
            for (final group in groups.skip(offset).take(50))
              {'id': group.id, 'title': group.title, 'deferred': group.deferred, 'count': group.episodes.length},
          ],
          offset: offset,
          total: groups.length,
        );
      }
      final groupId = companionText(args, 'groupId');
      var group = groups.where((group) => group.id == groupId).firstOrNull;
      if (group?.deferred == true) {
        if (gateway is! SourceChapterGroupGateway) throw const CompanionFailure('group_unavailable');
        catalog = await (gateway as SourceChapterGroupGateway).getChapterGroup(pluginId: pluginId, id: contentId, groupId: groupId);
        group = catalog.groups.where((group) => group.id == groupId && !group.deferred).firstOrNull;
      }
      if (group == null) throw const CompanionFailure('group_unavailable');
      final offset = args['offset'] ?? 0;
      if (offset is! int || offset < 0 || offset > 5000) throw const CompanionFailure('invalid_page');
      final episodes = group.episodes.where((episode) => episode.isLocked != true).toList();
      return {
        'groupId': groupId,
        ..._boundedRows(
          'items',
          [
            for (final episode in episodes.skip(offset).take(50)) {'id': episode.id, 'title': episode.title},
          ],
          offset: offset,
          total: episodes.length,
        ),
      };
    }
    if (method == 'favorites' || method == 'history') {
      if (!(await _repository.policy(peerId)).browseLibrary) throw const CompanionFailure('library_permission_required');
      final getLibrary = ref.read(companionLibraryProvider);
      if (getLibrary == null) throw const CompanionFailure('library_unavailable');
      final library = await getLibrary();
      final offset = args['offset'] ?? 0;
      if (offset is! int || offset < 0 || offset > 500) throw const CompanionFailure('invalid_page');
      if (method == 'history') {
        final entries = await library.listVideoHistory(limit: 500);
        return {
          ..._boundedRows(
            'entries',
            [for (final entry in entries.skip(offset).take(20)) entry.checkpoint.toJson()],
            offset: offset,
            total: entries.length,
          ),
        };
      }
      final page = await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount, visibility: LibraryVisibility.normal));
      final videos = page.items.where((item) => item.kind == ContentKind.video).toList();
      return {
        ..._boundedRows(
          'items',
          [
            for (final item in videos.skip(offset).take(20))
              {
                'pluginId': item.source.pluginId,
                'contentId': item.source.remoteContentId,
                'title': item.title,
                'sourceName': item.sourceName ?? item.source.pluginId,
                'pluginVersion': item.source.pluginVersion,
              },
          ],
          offset: offset,
          total: videos.length,
        ),
      };
    }
    if (method == 'commandStatus') {
      final receipt = _engine.receiptFor(peerId, companionText(args, 'commandId', max: 128));
      return {'receipt': receipt?.toJson()};
    }
    if (method == 'requestControl') {
      // This only surfaces the request on the TV. It never grants control.
      pendingControlRequests.add(peerId);
      _notify();
      return {'requested': true};
    }
    throw const CompanionFailure('request_unsupported');
  }

  Map<String, Object?> _catalogItem(PluginSourceDescriptor source, PluginContentSummary content) => {
    'pluginId': source.id,
    'pluginVersion': source.pluginVersion,
    'sourceName': source.displayName,
    'contentId': content.id,
    'title': content.title,
  };
  Map<String, Object?> _boundedRows(String key, List<Map<String, Object?>> rows, {required int offset, required int total}) {
    final selected = <Map<String, Object?>>[];
    var bytes = 0;
    for (final row in rows) {
      final size = utf8.encode(jsonEncode(row)).length;
      if (bytes + size > 48 * 1024) break;
      selected.add(row);
      bytes += size;
    }
    if (selected.isEmpty && rows.isNotEmpty) throw const CompanionFailure('response_too_large');
    return {key: selected, 'nextOffset': offset + selected.length < total ? offset + selected.length : null};
  }
}

final class _TvSearchSession {
  _TvSearchSession(this.query, this.pluginId, this.sources, this.lastUsedMs);
  final String query;
  final String? pluginId;
  final List<PluginSourceDescriptor> sources;
  AggregatedSearchResult? result;
  final Set<String> shown = {};
  String? token;
  int lastUsedMs;
  int get totalHits => result?.sourceStates.fold<int>(0, (sum, state) => sum + state.hits.length) ?? 0;
}
