/// TV settings dashboard with a persistent category rail and real setting links.
/// Selection and scroll belong to this view; mutations and routing use callbacks.
/// Outgoing category panels never retain focus during their fade transition.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_video_settings.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class TvProfilePage extends StatefulWidget {
  const TvProfilePage({
    required this.appVersion,
    required this.onDestinationRequested,
    required this.onSettingRequested,
    required this.onAboutRequested,
    super.key,
  });

  final String appVersion;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<ProfileSettingsItemViewData> onSettingRequested;
  final ValueChanged<ProfileSettingsItemViewData> onAboutRequested;

  @override
  State<TvProfilePage> createState() => _TvProfilePageState();
}

class _TvProfilePageState extends State<TvProfilePage> {
  int _section = 0;
  final _panelFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  static const _sections = [
    ('播放', Icons.play_circle_outline_rounded),
    ('外观', Icons.palette_outlined),
    ('数据源', Icons.extension_outlined),
    ('工具', Icons.build_outlined),
    ('关于', Icons.info_outline_rounded),
  ];

  @override
  void dispose() {
    _panelFocus.dispose();
    super.dispose();
  }

  KeyEventResult _enterPanel(FocusNode _, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final controls = _panelFocus.traversalDescendants.where((node) => node is! FocusScopeNode);
      if (controls.isNotEmpty) requestTvFocus(controls.first);
    }
    return KeyEventResult.handled;
  }

  Widget _link(ProfileSettingsItemViewData item, {bool about = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TvFocusable(
      key: ValueKey('tv-setting-${item.id}'),
      onPressed: () => about ? widget.onAboutRequested(item) : widget.onSettingRequested(item),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(item.description, style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    ),
  );

  List<Widget> _panel() {
    final items = ProfileFixtures.preview.settings;
    List<Widget> links(Set<String> ids) => items.where((item) => ids.contains(item.id)).map(_link).toList();
    return switch (_section) {
      0 => [
        const ProfileVideoSettings(),
        const SizedBox(height: 24),
        ...links({'reading-settings'}),
      ],
      1 => [
        ...links({'theme-appearance'}),
        TvFocusable(
          key: const Key('tv-settings-exit-mode'),
          onPressed: () => TvModeScope.maybeOf(context)?.onChanged(false),
          child: const Text('切换到普通模式'),
        ),
      ],
      2 => links({'source-management', 'network-proxy', 'downloads-cache'}),
      3 => [
        ...links({'import-export', 'data-backup'}),
        if (Platform.isAndroid && !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME'))
          _link(
            const ProfileSettingsItemViewData(
              id: 'node-runtime',
              title: 'Node.js 运行时',
              description: '选择运行时，重启后生效',
              icon: ProfileSettingsIcon.sources,
            ),
          ),
        for (final item in ProfileFixtures.preview.about.where((item) => item.id == 'diagnostics')) _link(item, about: true),
      ],
      _ => [
        for (final item in ProfileFixtures.preview.withAppVersion(widget.appVersion).about.where((item) => item.id != 'diagnostics'))
          _link(item, about: true),
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220);
    return TvFocusRegion(
      child: Scaffold(
        key: const Key('tv-settings-page'),
        appBar: AppBottomNavigation(selected: AppNavigationDestination.profile, onSelected: widget.onDestinationRequested),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('设置', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text('方向键选择 · OK 确认 · 返回键返回', style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText)),
                const SizedBox(height: 20),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: MediaQuery.sizeOf(context).width < 800 ? 152 : 210,
                        child: Focus(
                          canRequestFocus: false,
                          onKeyEvent: _enterPanel,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < _sections.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: TvFocusable(
                                      key: ValueKey('tv-settings-section-$i'),
                                      autofocus: i == 0,
                                      selected: _section == i,
                                      activateOnFocus: true,
                                      onPressed: () {
                                        if (_section != i) setState(() => _section = i);
                                      },
                                      child: Row(
                                        children: [
                                          Icon(_sections[i].$2),
                                          const SizedBox(width: 12),
                                          Expanded(child: Text(_sections[i].$1, style: theme.textTheme.titleLarge)),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 28),
                      Expanded(
                        child: Focus(
                          focusNode: _panelFocus,
                          child: AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: Curves.easeOutCubic,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.topLeft,
                              children: [
                                for (final child in previous) ExcludeFocus(child: IgnorePointer(child: child)),
                                ?current,
                              ],
                            ),
                            child: ListView(
                              key: ValueKey('tv-settings-panel-$_section'),
                              padding: const EdgeInsets.fromLTRB(8, 8, 12, 24),
                              children: (ModalRoute.of(context)?.isCurrent ?? true) ? _panel() : const [],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
