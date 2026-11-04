import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_discovery_startup.dart';
import 'package:mg_read/features/tv_companion/presentation/video_play_on_tv_action.dart';

void main() {
  test('starts UDP discovery before ensuring peer services on first visit', () async {
    final events = <String>[];

    final started = await startCompanionDiscovery(
      discover: () async => events.add('discover'),
      ensurePeerServices: () async => events.add('ensurePeerServices'),
      isMounted: () => true,
      stopDiscovery: () async => events.add('stopDiscovery'),
      onDiscoveryStarted: () => events.add('discoveryStarted'),
    );

    expect(started, isTrue);
    expect(events, ['discover', 'discoveryStarted', 'ensurePeerServices']);
  });

  test('balances discovery if the page is disposed during startup', () async {
    final events = <String>[];

    final started = await startCompanionDiscovery(
      discover: () async => events.add('discover'),
      ensurePeerServices: () async => events.add('ensurePeerServices'),
      isMounted: () => false,
      stopDiscovery: () async => events.add('stopDiscovery'),
      onDiscoveryStarted: () => events.add('discoveryStarted'),
    );

    expect(started, isFalse);
    expect(events, ['discover', 'stopDiscovery']);
  });

  test('replaying the same TV episode reuses TV progress', () {
    const phone = CompanionContentRef(
      pluginId: 'source',
      contentId: 'show',
      title: 'Show',
      groupId: 'season-1',
      episodeId: 'episode-2',
      positionMs: 42000,
    );
    const tv = CompanionContentRef(
      pluginId: 'source',
      contentId: 'show',
      title: 'Show',
      groupId: 'season-1',
      episodeId: 'episode-2',
      positionMs: 81000,
    );

    final result = companionHandoffContentForTarget(phoneContent: phone, tvContent: tv, tvStateFresh: true);

    expect(result.useTvProgress, isTrue);
    expect(result.positionMs, phone.positionMs);
  });

  test('new episode and stale TV state keep current phone progress', () {
    const phone = CompanionContentRef(
      pluginId: 'source',
      contentId: 'show',
      title: 'Show',
      groupId: 'season-1',
      episodeId: 'episode-2',
      positionMs: 42000,
    );
    const otherEpisode = CompanionContentRef(
      pluginId: 'source',
      contentId: 'show',
      title: 'Show',
      groupId: 'season-1',
      episodeId: 'episode-1',
      positionMs: 81000,
    );

    expect(companionHandoffContentForTarget(phoneContent: phone, tvContent: otherEpisode, tvStateFresh: true), same(phone));
    expect(companionHandoffContentForTarget(phoneContent: phone, tvContent: phone, tvStateFresh: false), same(phone));
  });
}
