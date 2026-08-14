import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// The library landing page driven by immutable lifecycle and display state.
class LibraryPage extends ConsumerWidget {
  /// Creates the library landing page.
  ///
  /// [previewData] is used only while the current M2 loader deliberately
  /// returns an empty local projection. The default fixture is visibly
  /// disclosed and is never passed to a repository or reader route.
  const LibraryPage({
    this.previewData,
    this.callbacks = const LibraryHomeCallbacks(),
    this.onDestinationRequested,
    super.key,
  });

  final LibraryHomeViewData? previewData;
  final LibraryHomeCallbacks callbacks;

  /// Lets the app layer own switching among top-level destinations.
  final ValueChanged<AppNavigationDestination>? onDestinationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppThemeModeScope themeModeScope = AppThemeModeScope.of(context);
    final LibraryPageState state = ref.watch(libraryPageControllerProvider);
    final LibraryPageController controller = ref.read(
      libraryPageControllerProvider.notifier,
    );

    if (state.status == LibraryPageStatus.initialLoading) {
      return const _LibraryLoadingState();
    }
    if (state.overview == null) {
      return _LibraryFailureState(
        error: state.error!,
        onRetry: controller.refresh,
      );
    }

    final LibraryHomeViewData data = state.overview!.isEmpty
        ? previewData ?? LibraryHomeFixtures.preview
        : LibraryHomeViewData.fromLocalOverview(state.overview!);
    final ValueChanged<AppNavigationDestination>? destinationRequested =
        onDestinationRequested;
    final LibraryHomeCallbacks resolvedCallbacks = destinationRequested == null
        ? callbacks
        : callbacks.copyWith(
            onNavigationSelected: (AppNavigationDestination destination) {
              callbacks.onNavigationSelected?.call(destination);
              destinationRequested(destination);
            },
          );
    return LibraryHomeShell(
      data: data,
      callbacks: resolvedCallbacks,
      isRefreshing: state.status == LibraryPageStatus.refreshing,
      onRefresh: controller.refresh,
      onToggleTheme: () {
        themeModeScope.onToggleTheme(Theme.of(context).brightness);
      },
      errorNotice: state.hasFailure
          ? _LibraryErrorCard(
              error: state.error!,
              onRetry: controller.refresh,
              hasRetainedData: true,
            )
          : null,
    );
  }
}

class _LibraryLoadingState extends StatelessWidget {
  const _LibraryLoadingState();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Semantics(
            label: AppStrings.libraryLoadingLabel,
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(color: tokens.accent),
                  const SizedBox(height: AppSpacing.regular),
                  Text(
                    AppStrings.libraryLoadingLabel,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryFailureState extends StatelessWidget {
  const _LibraryFailureState({required this.error, required this.onRetry});

  final AppError error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.section),
              child: _LibraryErrorCard(error: error, onRetry: onRetry),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryErrorCard extends StatelessWidget {
  const _LibraryErrorCard({
    required this.error,
    required this.onRetry,
    this.hasRetainedData = false,
  });

  final AppError error;
  final Future<void> Function() onRetry;
  final bool hasRetainedData;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: AppRadii.surface,
          border: Border.all(color: theme.colorScheme.error),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.comfortable),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                AppStrings.errorTitle(error),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              Text(
                AppStrings.errorDescription(error),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              if (hasRetainedData) ...<Widget>[
                const SizedBox(height: AppSpacing.compact),
                Text(
                  AppStrings.libraryRetainedDataDescription,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
              if (error.retryable) ...<Widget>[
                const SizedBox(height: AppSpacing.comfortable),
                FilledButton(
                  onPressed: () {
                    unawaited(onRetry());
                  },
                  child: const Text(AppStrings.retryLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
