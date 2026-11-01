/// Remote-operated update choice with fixed actions and scrollable release notes.
/// Focus and scrolling belong to this dialog; downloading and routing stay with
/// the caller. The initial focus is Later, so OK never starts an unattended install.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_traversal.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class GitHubApkUpdateTvPrompt extends StatefulWidget {
  const GitHubApkUpdateTvPrompt({
    required this.notes,
    required this.onOpenRelease,
    required this.onLater,
    required this.onInstall,
    super.key,
  });
  final String notes;
  final VoidCallback onOpenRelease;
  final VoidCallback onLater;
  final VoidCallback onInstall;

  @override
  State<GitHubApkUpdateTvPrompt> createState() => _GitHubApkUpdateTvPromptState();
}

class _GitHubApkUpdateTvPromptState extends State<GitHubApkUpdateTvPrompt> {
  final _scroll = ScrollController();
  final _laterFocus = FocusNode(debugLabel: 'update-dialog-later');
  final _policy = ReadingOrderTraversalPolicy(requestFocusCallback: requestTvFocus);
  bool _notesFocused = false;

  @override
  void dispose() {
    _scroll.dispose();
    _laterFocus.dispose();
    super.dispose();
  }

  KeyEventResult _scrollNotes(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft || event.logicalKey == LogicalKeyboardKey.arrowRight) {
      requestTvFocus(_laterFocus);
      return KeyEventResult.handled;
    }
    if (!_scroll.hasClients) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.pageDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.pageUp;
    if (!up && !down) return KeyEventResult.ignored;
    final position = _scroll.position;
    final next = (position.pixels + (down ? 1 : -1) * position.viewportDimension * .75).clamp(0.0, position.maxScrollExtent);
    if ((next - position.pixels).abs() < 1) return KeyEventResult.ignored;
    _scroll.animateTo(
      next,
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return FocusTraversalGroup(
      policy: _policy,
      child: Dialog(
        key: const Key('github-apk-update-prompt'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: SizedBox(
          width: 960,
          height: (MediaQuery.sizeOf(context).height * .82).clamp(240, 760),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('发现新版本', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                Expanded(
                  child: Focus(
                    onFocusChange: (value) => setState(() => _notesFocused = value),
                    onKeyEvent: _scrollNotes,
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: tokens.pageBackground,
                        borderRadius: AppRadii.detailControl,
                        border: Border.all(color: _notesFocused ? tokens.accent : tokens.divider, width: 2),
                      ),
                      child: SingleChildScrollView(
                        key: const Key('github-apk-update-notes-scroll'),
                        controller: _scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('更新内容 · 上下键滚动', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 8),
                            Text(
                              widget.notes,
                              key: const Key('github-apk-update-release-notes'),
                              style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TvFocusable(
                      key: const Key('github-apk-update-release-link'),
                      label: '在 GitHub 查看此版本',
                      onPressed: widget.onOpenRelease,
                      child: const Text('版本页面'),
                    ),
                    TvFocusable(
                      key: const Key('github-apk-update-later'),
                      focusNode: _laterFocus,
                      autofocus: true,
                      onPressed: widget.onLater,
                      child: const Text('稍后'),
                    ),
                    TvFocusable(key: const Key('github-apk-update-install'), onPressed: widget.onInstall, child: const Text('下载安装')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
