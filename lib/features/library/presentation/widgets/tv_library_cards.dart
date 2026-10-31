/// TV hero and landscape cards reuse app cover decoding and privacy rules.
/// Display only real source metadata; focus and commands are explicit inputs.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/tv_library_data.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'library_book_cover.dart';

class TvLibraryCover extends StatelessWidget {
  const TvLibraryCover({required this.entry, required this.width, required this.height, super.key});
  final TvLibraryEntry entry;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => LibraryBookCover(
    title: entry.book.title,
    variant: entry.book.coverVariant,
    width: width,
    height: height,
    contentKind: entry.book.contentKind,
    coverBytes: entry.book.coverBytes,
    coverRequest: entry.book.coverRequest,
    assetPath: entry.book.coverAssetPath,
    isBlurred: entry.book.isCoverBlurred,
    fit: BoxFit.cover,
  );
}

class TvLibraryHero extends StatelessWidget {
  const TvLibraryHero({required this.entry, required this.onPlay, required this.onDetail, super.key});
  final TvLibraryEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 700;
        return ClipRRect(
          borderRadius: AppRadii.detailCard,
          child: Stack(
            children: [
              if (wide)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TvLibraryCover(entry: entry, width: constraints.maxWidth * .62, height: 340),
                  ),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        tokens.pageBackground,
                        tokens.pageBackground.withValues(alpha: .93),
                        tokens.pageBackground.withValues(alpha: .12),
                      ],
                      stops: const [0, .38, 1],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(wide ? 32 : 16),
                child: SizedBox(
                  width: wide ? constraints.maxWidth * .6 : constraints.maxWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.hasHistory ? '继续观看' : '我的影视', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      Text(
                        entry.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineLarge?.copyWith(fontSize: wide ? 40 : 28, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        [entry.kindLabel, ?entry.summary?.sourceName, entry.progressLabel].join(' · '),
                        style: theme.textTheme.titleMedium?.copyWith(color: tokens.mutedText),
                      ),
                      if (entry.summary?.description case final description?) ...[
                        const SizedBox(height: 12),
                        Text(description, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
                      ],
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 16,
                        runSpacing: 12,
                        children: [
                          TvFocusable(
                            key: const Key('tv-continue'),
                            autofocus: true,
                            selected: true,
                            onPressed: onPlay,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_arrow_rounded, size: 30),
                                const SizedBox(width: 8),
                                Text(entry.hasHistory ? '继续播放' : '立即播放', style: theme.textTheme.titleLarge),
                              ],
                            ),
                          ),
                          TvFocusable(
                            key: const Key('tv-hero-detail'),
                            onPressed: onDetail,
                            child: Text('查看详情', style: theme.textTheme.titleLarge),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class TvLibraryCard extends StatelessWidget {
  const TvLibraryCard({required this.entry, required this.width, required this.onOpen, required this.onMore, super.key});
  final TvLibraryEntry entry;
  final double width;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvFocusable(
          key: Key('tv-card-${entry.book.id}'),
          label: entry.book.title,
          onPressed: onOpen,
          onMore: onMore,
          padding: const EdgeInsets.all(3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: AppRadii.detailControl,
                child: TvLibraryCover(entry: entry, width: width - 12, height: (width - 12) * 9 / 16),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text('${entry.kindLabel} · ${entry.progressLabel}', style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        TvFocusable(
          key: Key('tv-more-${entry.book.id}'),
          onPressed: onMore,
          child: const Text('更多', textAlign: TextAlign.center),
        ),
      ],
    ),
  );
}
