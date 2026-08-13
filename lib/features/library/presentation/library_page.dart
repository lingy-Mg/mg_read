import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// The local-library landing page driven by an immutable lifecycle state.
class LibraryPage extends ConsumerWidget {
  /// Creates the library landing page.
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryPageState state = ref.watch(libraryPageControllerProvider);
    final LibraryPageController controller = ref.read(
      libraryPageControllerProvider.notifier,
    );

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.libraryTitle)),
      body: switch (state.status) {
        LibraryPageStatus.initialLoading => const _LibraryLoadingState(),
        _ when state.overview != null => _LibraryContent(
          state: state,
          overview: state.overview!,
          onRefresh: controller.refresh,
        ),
        _ => _LibraryFailureState(
          error: state.error!,
          onRetry: controller.refresh,
        ),
      },
    );
  }
}

class _LibraryLoadingState extends StatelessWidget {
  const _LibraryLoadingState();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Semantics(
          label: AppStrings.libraryLoadingLabel,
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class _LibraryContent extends StatelessWidget {
  const _LibraryContent({
    required this.state,
    required this.overview,
    required this.onRefresh,
  });

  final LibraryPageState state;
  final LibraryOverview overview;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: ListView(
              key: const Key('library-content'),
              padding: const EdgeInsets.all(24),
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                if (state.status == LibraryPageStatus.refreshing) ...<Widget>[
                  Semantics(
                    label: AppStrings.libraryRefreshingLabel,
                    child: LinearProgressIndicator(),
                  ),
                  const SizedBox(height: 16),
                ],
                if (state.hasFailure) ...<Widget>[
                  _LibraryErrorCard(
                    error: state.error!,
                    onRetry: onRefresh,
                    hasRetainedData: true,
                  ),
                  const SizedBox(height: 16),
                ],
                if (overview.isEmpty)
                  const _LibraryEmptyState()
                else
                  ...overview.items.map(
                    (LibraryItemSummary item) => _LibraryItemTile(item: item),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      label: AppStrings.libraryIconLabel,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.auto_stories_outlined,
                color: theme.colorScheme.primary,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                AppStrings.libraryEmptyTitle,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.libraryEmptyDescription,
                style: theme.textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryItemTile extends StatelessWidget {
  const _LibraryItemTile({required this.item});

  final LibraryItemSummary item;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(item.title),
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
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _LibraryErrorCard(error: error, onRetry: onRetry),
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
      child: Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                AppStrings.errorTitle(error),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                AppStrings.errorDescription(error),
                style: theme.textTheme.bodyMedium,
              ),
              if (hasRetainedData) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  AppStrings.libraryRetainedDataDescription,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (error.retryable) ...<Widget>[
                const SizedBox(height: 16),
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
