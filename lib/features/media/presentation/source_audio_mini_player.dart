/// App-global mini-player visuals; playback and artwork I/O stay host-owned.
/// The square reserves separate status/action lanes with 44px touch targets.
/// The bar measures its two text lines to preserve system text scaling.
/// Center the animation inside its badge so tight parent constraints cannot
/// stretch its bars; its ticker follows playback and is disposed with the UI.
part of 'source_audio_playback_host.dart';

Widget _buildSourceAudioMiniArtwork(BuildContext context, AudioTrack track, SourceAudioPlaybackRequest request) {
  return KeyedSubtree(key: const Key('source-audio-mini-cover'), child: _sourceAudioArtwork(context, track, request));
}

double _sourceAudioMiniBarHeight(BuildContext context) {
  final theme = Theme.of(context);
  double lineHeight(TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: '音频', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  final textHeight = lineHeight(theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)) + lineHeight(theme.textTheme.bodySmall);
  return math.max(kMinInteractiveDimension, textHeight) + AppSpacing.compact * 2;
}

Widget _buildSourceAudioMiniBar(
  BuildContext context,
  AudioPlayerSnapshot snapshot,
  AudioTrack? track,
  AudioPlayerFailure? failure,
  AppThemeTokens tokens,
  Color foreground,
  ThemeData theme, {
  required AudioPlayerController controller,
  required VoidCallback onStop,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.regular, AppSpacing.compact, AppSpacing.unit, AppSpacing.compact),
    child: Row(
      children: <Widget>[
        _buildSourceAudioPlaybackIndicator(context, snapshot, failure, tokens),
        const SizedBox(width: AppSpacing.regular),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                track?.title ?? '正在准备音频',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(color: foreground, fontWeight: FontWeight.w600),
              ),
              Text(
                failure == null ? track?.collectionTitle ?? '点按返回播放器' : '${failure.message} · ${failure.location} · ${failure.code}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: failure == null ? tokens.mutedText : tokens.warning),
              ),
            ],
          ),
        ),
        _buildSourceAudioToggle(snapshot, foreground, controller),
        _buildSourceAudioStop(tokens, onStop),
      ],
    ),
  );
}

Widget _buildSourceAudioMiniSquare(
  BuildContext context,
  AudioPlayerSnapshot snapshot,
  AudioPlayerFailure? failure,
  AppThemeTokens tokens,
  Color foreground, {
  required AudioPlayerController controller,
  required VoidCallback onStop,
}) {
  return Padding(
    padding: const EdgeInsets.all(4),
    child: Row(
      children: <Widget>[
        _buildSourceAudioPlaybackIndicator(context, snapshot, failure, tokens, square: true),
        const SizedBox(width: 4),
        Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            _buildSourceAudioStop(tokens, onStop, compact: true),
            _buildSourceAudioToggle(snapshot, foreground, controller, compact: true),
          ],
        ),
      ],
    ),
  );
}

Widget _buildSourceAudioPlaybackIndicator(
  BuildContext context,
  AudioPlayerSnapshot snapshot,
  AudioPlayerFailure? failure,
  AppThemeTokens tokens, {
  bool square = false,
}) {
  final message = failure == null
      ? (snapshot.buffering || snapshot.resourceLoading
            ? '音频正在缓冲'
            : snapshot.playing
            ? '音频正在后台播放'
            : '音频已暂停')
      : '${failure.message}\n发生位置：${failure.location}\n诊断编号：${failure.code}'
            '${failure.debugDetail == null ? '' : '\n技术原因：${failure.debugDetail}'}';
  return DecoratedBox(
    key: const Key('source-audio-mini-status'),
    decoration: BoxDecoration(
      color: tokens.accentSoft.withValues(alpha: 0.60),
      borderRadius: square ? BorderRadius.circular(22) : AppRadii.discoveryTile,
      border: Border.all(color: tokens.accent.withValues(alpha: 0.18)),
    ),
    child: SizedBox.square(
      dimension: 44,
      child: Tooltip(
        message: message,
        child: Center(
          child: failure == null
              ? _SourceAudioPlayingIndicator(
                  playing: snapshot.playing,
                  buffering: snapshot.buffering || snapshot.resourceLoading,
                  disableAnimations: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
                  color: tokens.accent,
                )
              : Icon(Icons.error_outline_rounded, color: tokens.warning),
        ),
      ),
    ),
  );
}

Widget _buildSourceAudioToggle(AudioPlayerSnapshot snapshot, Color foreground, AudioPlayerController controller, {bool compact = false}) {
  return IconButton(
    key: const Key('source-audio-mini-toggle'),
    tooltip: snapshot.playing ? '暂停' : '播放',
    constraints: compact ? const BoxConstraints.tightFor(width: 44, height: 44) : null,
    style: compact ? IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.standard) : null,
    padding: compact ? EdgeInsets.zero : null,
    onPressed: () => unawaited(controller.toggle()),
    color: foreground,
    icon: Icon(snapshot.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: compact ? 20 : null),
  );
}

Widget _buildSourceAudioStop(AppThemeTokens tokens, VoidCallback onStop, {bool compact = false}) {
  return IconButton(
    key: const Key('source-audio-mini-stop'),
    tooltip: '停止并关闭',
    constraints: compact ? const BoxConstraints.tightFor(width: 44, height: 44) : null,
    style: compact ? IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.standard) : null,
    padding: compact ? EdgeInsets.zero : null,
    onPressed: onStop,
    color: tokens.mutedText,
    icon: Icon(Icons.close_rounded, size: compact ? 20 : null),
  );
}

/// Same playback-driven three-bar motion used by the audio player's top bar.
/// It lives in the host as a private boundary-safe counterpart for the
/// app-global overlay, whose compact square must not expose package internals.
final class _SourceAudioPlayingIndicator extends StatefulWidget {
  const _SourceAudioPlayingIndicator({
    required this.playing,
    required this.buffering,
    required this.disableAnimations,
    required this.color,
  });

  final bool playing;
  final bool buffering;
  final bool disableAnimations;
  final Color color;

  @override
  State<_SourceAudioPlayingIndicator> createState() => _SourceAudioPlayingIndicatorState();
}

final class _SourceAudioPlayingIndicatorState extends State<_SourceAudioPlayingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: AppMotion.playingIndicatorCycle);

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _SourceAudioPlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.buffering != widget.buffering ||
        oldWidget.disableAnimations != widget.disableAnimations) {
      _syncTicker();
    }
  }

  void _syncTicker() {
    if (!widget.disableAnimations && (widget.playing || widget.buffering)) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        key: const Key('source-audio-mini-playing-indicator'),
        width: 22,
        height: 22,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List<Widget>.generate(3, (index) {
                final phase = widget.buffering
                    ? _controller.value * math.pi * 2 - index * 1.1
                    : _controller.value * math.pi * 2 + index * 1.72;
                final amount = !widget.disableAnimations && (widget.playing || widget.buffering) ? 0.5 + 0.5 * math.sin(phase) : 0.0;
                return Container(
                  key: Key('source-audio-mini-playing-indicator-bar-$index'),
                  width: 4,
                  height: 5 + amount * (index == 1 ? 13 : 9),
                  decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(3)),
                );
              }),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
