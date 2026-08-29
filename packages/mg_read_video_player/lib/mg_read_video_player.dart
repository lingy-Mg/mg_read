/// Public API for the independently maintained MgRead video player.
///
/// Responsibilities:
/// - Export the immutable video contracts, controller and embeddable view.
/// - Keep backend implementation details and package-private widgets hidden.
///
/// Notes:
/// - This library never exports MediaKit, reader or host-platform internals.
library;

export 'src/api/contracts.dart'
    show
        VideoDataSource,
        VideoPlaybackBackend,
        VideoPlaybackBackendFactory,
        VideoPlaybackStateStore,
        VideoPlayerObserver;
export 'src/api/controller.dart' show VideoPlayerController;
export 'src/api/models.dart'
    show
        VideoContent,
        VideoEpisode,
        VideoFitMode,
        VideoPlaybackBackendState,
        VideoPlaybackProgress,
        VideoPlayerFailure,
        VideoPlayerFailureKind,
        VideoPlayerSnapshot,
        VideoPlayerStatus;
export 'src/ui/video_player_view.dart' show VideoPlayerView;
