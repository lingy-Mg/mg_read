/// Deterministic metadata gateway for the native two-endpoint acceptance.
/// Episode resources point to the Windows coordinator's real Range MP4 server.
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

const companionQaPluginId = 'companion-qa';
const companionQaContentId = 'sintel-native-acceptance';
const companionQaGroupId = 'qa';
const companionQaFirstEpisodeId = 'sample';
const companionQaNextEpisodeId = 'next';
const companionQaUnavailableEpisodeId = 'unavailable';

final class CompanionQaGateway implements SourceContentGateway {
  CompanionQaGateway(this.mediaUri);
  final Uri mediaUri;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [
    PluginSourceDescriptor(
      id: companionQaPluginId,
      displayName: 'Companion QA metadata fixture',
      contentKinds: const [PluginContentKind.video],
      pluginVersion: 'qa-1',
    ),
  ];

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: 'Companion QA metadata fixture',
    summary: PluginContentSummary(
      id: companionQaContentId,
      title: 'Sintel companion acceptance',
      contentKind: PluginContentKind.video,
      author: null,
      url: null,
      coverUrl: null,
      description: 'Local test metadata; playback uses the Windows Range HTTP endpoint.',
      language: 'en',
      status: PluginContentStatus.ongoing,
      access: PluginAccessKind.free,
      wordCount: null,
      chapterCount: 3,
      publishedAt: null,
      updatedAt: null,
      latestChapter: null,
      categories: const ['acceptance'],
      tags: const [],
      attributes: const [],
    ),
    aliases: const [],
    catalogUrl: null,
  );

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    final episodes = [
      for (final entry in const [
        (companionQaFirstEpisodeId, 'Sintel sample'),
        (companionQaNextEpisodeId, 'Sintel next selection'),
        (companionQaUnavailableEpisodeId, 'Unavailable resource'),
      ])
        PluginChapterSummary(
          id: entry.$1,
          title: entry.$2,
          order: switch (entry.$1) {
            companionQaFirstEpisodeId => 0,
            companionQaNextEpisodeId => 1,
            _ => 2,
          },
          url: null,
          volumeTitle: null,
          wordCount: null,
          updatedAt: null,
          isLocked: false,
          attributes: const [],
        ),
    ];
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: 'Companion QA metadata fixture',
      items: episodes,
      groups: [PluginMediaGroup(id: companionQaGroupId, title: 'QA', order: 0, episodes: episodes)],
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    final uri = chapterId == companionQaUnavailableEpisodeId ? mediaUri.replace(path: '${mediaUri.path}.missing') : mediaUri;
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: 'Companion QA metadata fixture',
      contentKind: PluginContentKind.video,
      chapterId: chapterId,
      title: chapterId,
      updatedAt: null,
      text: null,
      pages: const [],
      media: PluginMediaResource(
        url: uri,
        resourceType: PluginMediaResourceType.video,
        resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
        expiresAt: null,
        mimeType: 'video/mp4',
        headers: const {},
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
