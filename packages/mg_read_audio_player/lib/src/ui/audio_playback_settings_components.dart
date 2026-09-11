/// Visual building blocks for the cohesive playback-adjustment sheet.
///
/// Responsibilities:
/// - Render the session summary, distinct control cards and completion action.
/// - Provide accessible, animated rate, volume and sleep-timer controls.
///
/// This part contains no media state or controller calls.
part of 'audio_playback_settings_sheet.dart';

abstract final class _SettingsTokens {
  static const neutralControl = AudioPlayerColors.control;
  static const selected = AudioPlayerColors.accentGlass;
  static const cardRadius = 22.0;
}

final class _SettingsHandle extends StatelessWidget {
  const _SettingsHandle();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 38,
      height: 4,
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      decoration: BoxDecoration(
        color: AudioPlayerColors.track,
        borderRadius: BorderRadius.circular(99),
      ),
    ),
  );
}

final class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 2, 14, 4),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '音乐播放设置',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AudioPlayerColors.ink,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '防止自动锁屏会保存，其余仅作用于当前会话',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AudioPlayerColors.muted),
              ),
            ],
          ),
        ),
        IconButton.filledTonal(
          key: const Key('audio-settings-close'),
          tooltip: '关闭音乐播放设置',
          onPressed: onClose,
          style: IconButton.styleFrom(
            backgroundColor: _SettingsTokens.neutralControl,
            foregroundColor: AudioPlayerColors.ink,
          ),
          icon: const Icon(Icons.close_rounded, size: 21),
        ),
      ],
    ),
  );
}

final class _SessionSummary extends StatelessWidget {
  const _SessionSummary({
    required this.rate,
    required this.volume,
    required this.timer,
    required this.disableAnimations,
  });

  final double rate;
  final double volume;
  final Duration? timer;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final items = <(String, String)>[
      ('${formatAudioRate(rate)}x', '播放速度'),
      (formatAudioVolume(volume), '播放音量'),
      (timer == null ? '未定时' : '${timer!.inMinutes} 分钟', '定时停止'),
    ];
    return Semantics(
      container: true,
      label: '当前播放调节摘要',
      child: AudioGlassPanel(
        key: const Key('audio-settings-summary'),
        borderRadius: BorderRadius.circular(18),
        tone: AudioGlassTone.accent,
        shadow: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: <Widget>[
              for (var index = 0; index < items.length; index++) ...<Widget>[
                if (index > 0)
                  const SizedBox(
                    height: 28,
                    child: VerticalDivider(
                      width: 1,
                      color: AudioPlayerColors.track,
                    ),
                  ),
                Expanded(
                  child: _SummaryItem(
                    value: items[index].$1,
                    label: items[index].$2,
                    disableAnimations: disableAnimations,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.value,
    required this.label,
    required this.disableAnimations,
  });

  final String value;
  final String label;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      AnimatedSwitcher(
        duration: disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 180),
        child: Text(
          value,
          key: ValueKey(value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AudioPlayerColors.accentPressed,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(height: 1),
      Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: AudioPlayerColors.muted),
      ),
    ],
  );
}

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.child,
    super.key,
  });

  final IconData icon;
  final String title;
  final String value;
  final Widget child;

  @override
  Widget build(BuildContext context) => AudioGlassPanel(
    borderRadius: BorderRadius.circular(_SettingsTokens.cardRadius),
    blur: 16,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _SettingsIcon(icon: icon),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AudioPlayerColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: _SettingsTokens.neutralControl,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  child: Text(
                    value,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: AudioPlayerColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

final class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 36,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: AudioPlayerColors.accentSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 19, color: AudioPlayerColors.accentPressed),
    ),
  );
}

final class _KeepScreenOnControl extends StatelessWidget {
  const _KeepScreenOnControl({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: Text(
          '保持屏幕开启，无操作时允许系统自动调暗；手动锁屏后仍会继续后台播放。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AudioPlayerColors.muted,
            height: 1.35,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Switch(
        key: const Key('audio-keep-screen-on-switch'),
        value: enabled,
        onChanged: onChanged,
      ),
    ],
  );
}

final class _RateTrack extends StatelessWidget {
  const _RateTrack({
    required this.rates,
    required this.selectedRate,
    required this.disableAnimations,
    required this.onSelected,
  });

  final List<double> rates;
  final double selectedRate;
  final bool disableAnimations;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Stack(
      alignment: Alignment.topCenter,
      children: <Widget>[
        Positioned(
          top: 10,
          left: 17,
          right: 17,
          child: Container(height: 2, color: AudioPlayerColors.track),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final rate in rates)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: (selectedRate - rate).abs() < 0.01,
                  label: '${formatAudioRate(rate)} 倍速',
                  child: InkResponse(
                    key: Key('audio-rate-${(rate * 100).round()}'),
                    onTap: () => onSelected(rate),
                    radius: 22,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        AnimatedContainer(
                          duration: disableAnimations
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          width: (selectedRate - rate).abs() < 0.01 ? 20 : 14,
                          height: (selectedRate - rate).abs() < 0.01 ? 20 : 14,
                          decoration: BoxDecoration(
                            color: (selectedRate - rate).abs() < 0.01
                                ? AudioPlayerColors.accent
                                : AudioPlayerColors.control,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (selectedRate - rate).abs() < 0.01
                                  ? AudioPlayerColors.accent
                                  : AudioPlayerColors.subtle,
                              width: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            formatAudioRate(rate),
                            maxLines: 1,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: (selectedRate - rate).abs() < 0.01
                                      ? AudioPlayerColors.accentPressed
                                      : AudioPlayerColors.muted,
                                  fontWeight: (selectedRate - rate).abs() < 0.01
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

final class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.volume,
    required this.onToggleMute,
    required this.onChanged,
  });

  final double volume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      IconButton.filledTonal(
        key: const Key('audio-volume-mute'),
        tooltip: volume > 0 ? '静音' : '恢复音量',
        onPressed: onToggleMute,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AudioPlayerMetrics.minimumTapTarget),
          backgroundColor: _SettingsTokens.neutralControl,
          foregroundColor: AudioPlayerColors.ink,
        ),
        icon: Icon(
          volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          size: 21,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          children: <Widget>[
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AudioPlayerColors.accent,
                inactiveTrackColor: AudioPlayerColors.track,
                thumbColor: AudioPlayerColors.accent,
                overlayColor: AudioPlayerColors.accentSoft,
                trackHeight: 5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                key: const Key('audio-volume-slider'),
                value: volume,
                semanticFormatterCallback: formatAudioVolume,
                onChanged: onChanged,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text('0', style: _scaleLabelStyle(context)),
                  Text('100', style: _scaleLabelStyle(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  TextStyle? _scaleLabelStyle(BuildContext context) => Theme.of(
    context,
  ).textTheme.labelSmall?.copyWith(color: AudioPlayerColors.subtle);
}

final class _TimerSelector extends StatelessWidget {
  const _TimerSelector({
    required this.timers,
    required this.selectedTimer,
    required this.disableAnimations,
    required this.onSelected,
  });

  final List<Duration?> timers;
  final Duration? selectedTimer;
  final bool disableAnimations;
  final ValueChanged<Duration?> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = 7.0;
      final width = (constraints.maxWidth - spacing * 3) / 4;
      return Wrap(
        spacing: spacing,
        runSpacing: 7,
        children: <Widget>[
          for (final timer in timers)
            SizedBox(
              width: width,
              height: 38,
              child: _TimerOption(
                key: Key(
                  timer == null
                      ? 'audio-timer-off'
                      : 'audio-timer-${timer.inMinutes}',
                ),
                label: timer == null ? '关闭' : '${timer.inMinutes} 分钟',
                selected: selectedTimer == timer,
                disableAnimations: disableAnimations,
                onTap: () => onSelected(timer),
              ),
            ),
        ],
      );
    },
  );
}

final class _TimerOption extends StatelessWidget {
  const _TimerOption({
    required this.label,
    required this.selected,
    required this.disableAnimations,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final bool disableAnimations;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '定时停止 $label',
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? _SettingsTokens.selected
                : _SettingsTokens.neutralControl,
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(color: AudioPlayerColors.accent, width: 1.2)
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected
                  ? AudioPlayerColors.accentPressed
                  : AudioPlayerColors.ink,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}

final class _SettingsFooter extends StatelessWidget {
  const _SettingsFooter({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AudioPlayerColors.glassStrong,
      border: Border(top: BorderSide(color: AudioPlayerColors.divider)),
    ),
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          key: const Key('audio-settings-done'),
          onPressed: onDone,
          style: FilledButton.styleFrom(
            backgroundColor: AudioPlayerColors.accent,
            foregroundColor: AudioPlayerColors.backgroundBottom,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          child: const Text('完成'),
        ),
      ),
    ),
  );
}
