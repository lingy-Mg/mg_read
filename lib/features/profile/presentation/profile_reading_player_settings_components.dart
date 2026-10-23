/// 阅读器与播放器设置页的真实可修改控件。
///
/// 本文件承载章节预加载、音频续播、退出行为与迷你播放条应用级设置；书内字体、
/// 主题、排版等偏好仍由阅读器自己的设置面板负责。
part of 'profile_general_setting_page.dart';

class _AudioRememberPositionCard extends StatefulWidget {
  const _AudioRememberPositionCard({required this.value, required this.onChanged});

  final bool value;
  final Future<void> Function(bool) onChanged;

  @override
  State<_AudioRememberPositionCard> createState() => _AudioRememberPositionCardState();
}

class _AudioRememberPositionCardState extends State<_AudioRememberPositionCard> {
  late bool _value = widget.value;
  bool _saving = false;

  @override
  void didUpdateWidget(covariant _AudioRememberPositionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  Future<void> _change(bool value) async {
    final previous = _value;
    setState(() {
      _value = value;
      _saving = true;
    });
    try {
      await widget.onChanged(value);
    } on Object {
      if (mounted) setState(() => _value = previous);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.detailCard,
        side: BorderSide(color: tokens.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        key: const Key('profile-audio-remember-position'),
        title: const Text('记住上次播放位置'),
        subtitle: const Text('书架音频下次从上次章节和时间点继续；关闭后从所选章节开头播放，保留已有记录。'),
        value: _value,
        onChanged: _saving ? null : _change,
      ),
    );
  }
}

class _NovelPreloadChapterCountCard extends StatefulWidget {
  const _NovelPreloadChapterCountCard({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_NovelPreloadChapterCountCard> createState() => _NovelPreloadChapterCountCardState();
}

class _NovelPreloadChapterCountCardState extends State<_NovelPreloadChapterCountCard> {
  late int _value = widget.value;

  @override
  void didUpdateWidget(covariant _NovelPreloadChapterCountCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  void _change(int next) {
    if (next == _value || next < 0 || next > 5) return;
    setState(() => _value = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('novel-preload-chapter-count'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          children: <Widget>[
            Icon(Icons.auto_stories_outlined, color: tokens.accent),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('阅读预加载章节数量', style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    _value == 0 ? '已关闭，翻到下一章时再加载' : '小说与漫画提前加载当前章节之后的 $_value 章',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('novel-preload-count-decrease'),
              tooltip: '减少预加载章节',
              onPressed: _value > 0 ? () => _change(_value - 1) : null,
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
            Semantics(
              label: '当前预加载章节数量',
              value: '$_value 章',
              liveRegion: true,
              child: SizedBox(
                width: 42,
                child: Text(_value == 0 ? '关闭' : '$_value 章', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleSmall),
              ),
            ),
            IconButton(
              key: const Key('novel-preload-count-increase'),
              tooltip: '增加预加载章节',
              onPressed: _value < 5 ? () => _change(_value + 1) : null,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioExitBehaviorCard extends StatefulWidget {
  const _AudioExitBehaviorCard({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_AudioExitBehaviorCard> createState() => _AudioExitBehaviorCardState();
}

class _AudioExitBehaviorCardState extends State<_AudioExitBehaviorCard> {
  late String _value = widget.value;

  @override
  void didUpdateWidget(covariant _AudioExitBehaviorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    const options = <(String, String, String)>[
      ('ask', '每次询问', '返回时选择继续后台播放或停止'),
      ('continue', '继续播放', '返回后自动收起到应用内播放条'),
      ('stop', '停止播放', '返回后立即停止并释放播放器'),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: ClipRRect(
        borderRadius: AppRadii.detailCard,
        child: Column(
          children: <Widget>[
            for (int index = 0; index < options.length; index++) ...<Widget>[
              Semantics(
                selected: _value == options[index].$1,
                button: true,
                child: InkWell(
                  key: Key('audio-exit-behavior-${options[index].$1}'),
                  onTap: () {
                    final value = options[index].$1;
                    setState(() => _value = value);
                    widget.onChanged(value);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.regular),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _value == options[index].$1 ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: _value == options[index].$1 ? tokens.accent : tokens.mutedText,
                        ),
                        const SizedBox(width: AppSpacing.regular),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(options[index].$2, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(options[index].$3, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (index < options.length - 1) Divider(height: 1, color: tokens.divider),
            ],
          ],
        ),
      ),
    );
  }
}

class _AudioMiniPlayerStyleCard extends StatefulWidget {
  const _AudioMiniPlayerStyleCard({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_AudioMiniPlayerStyleCard> createState() => _AudioMiniPlayerStyleCardState();
}

class _AudioMiniPlayerStyleCardState extends State<_AudioMiniPlayerStyleCard> {
  late String _value = widget.value;

  @override
  void didUpdateWidget(covariant _AudioMiniPlayerStyleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    const options = <(String, String, String)>[('bar', '完整播放条', '显示标题、来源和播放控制，适合快速查看当前音频'), ('square', '方块迷你版', '收起为可拖动的小方块，点按方块可回到播放器')];
    return DecoratedBox(
      key: const Key('audio-mini-player-style'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: ClipRRect(
        borderRadius: AppRadii.detailCard,
        child: Column(
          children: <Widget>[
            for (int index = 0; index < options.length; index++) ...<Widget>[
              Semantics(
                selected: _value == options[index].$1,
                button: true,
                child: InkWell(
                  key: Key('audio-mini-player-style-${options[index].$1}'),
                  onTap: () {
                    final value = options[index].$1;
                    setState(() => _value = value);
                    widget.onChanged(value);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.regular),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _value == options[index].$1 ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: _value == options[index].$1 ? tokens.accent : tokens.mutedText,
                        ),
                        const SizedBox(width: AppSpacing.regular),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(options[index].$2, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(options[index].$3, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (index < options.length - 1) Divider(height: 1, color: tokens.divider),
            ],
          ],
        ),
      ),
    );
  }
}
