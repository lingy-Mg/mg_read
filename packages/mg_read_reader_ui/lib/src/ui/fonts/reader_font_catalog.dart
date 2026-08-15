import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api/contracts.dart';
import '../../api/models.dart';
import '../reader_theme.dart';
import '../settings/reader_settings_tokens.dart';
import 'reader_font_controller.dart';
import 'reader_font_strings.dart';

class ReaderFontCatalog extends StatefulWidget {
  const ReaderFontCatalog({
    required this.repository,
    required this.palette,
    required this.onSelected,
    this.selectedFontId,
    this.onError,
    super.key,
  });

  final ReaderFontRepository repository;
  final ReaderPalette palette;
  final ReaderFontSelectedCallback onSelected;
  final String? selectedFontId;
  final ValueChanged<Object>? onError;

  @override
  State<ReaderFontCatalog> createState() => _ReaderFontCatalogState();
}

class _ReaderFontCatalogState extends State<ReaderFontCatalog> {
  late ReaderFontCatalogController _controller;
  Object? _reportedFailure;

  @override
  void initState() {
    super.initState();
    _createController();
    unawaited(_controller.loadCatalog());
  }

  @override
  void didUpdateWidget(covariant ReaderFontCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        oldWidget.selectedFontId != widget.selectedFontId ||
        oldWidget.onSelected != widget.onSelected) {
      _controller.dispose();
      _createController();
      unawaited(_controller.loadCatalog());
    }
  }

  void _createController() {
    _controller = ReaderFontCatalogController(
      repository: widget.repository,
      selectedFontId: widget.selectedFontId,
      onSelected: widget.onSelected,
    )..addListener(_handleChange);
  }

  void _handleChange() {
    if (!mounted) return;
    final Object? failure = _controller.snapshot.failure;
    if (failure != null && !identical(failure, _reportedFailure)) {
      _reportedFailure = failure;
      try {
        widget.onError?.call(failure);
      } catch (error, stackTrace) {
        debugPrint(
          'novel_reader_ui font error callback failed: $error\n$stackTrace',
        );
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ReaderFontCatalogSnapshot state = _controller.snapshot;
    if (state.loading && state.fonts.isEmpty) {
      return _FontStatus(
        palette: widget.palette,
        icon: const SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: ReaderFontStrings.loading,
      );
    }
    if (state.failure != null && state.fonts.isEmpty) {
      return _FontStatus(
        palette: widget.palette,
        icon: Icon(Icons.refresh_rounded, color: widget.palette.accent),
        label: ReaderFontStrings.loadFailed,
        actionLabel: ReaderFontStrings.retry,
        onAction: _controller.loadCatalog,
      );
    }
    if (state.fonts.isEmpty) {
      return _FontStatus(
        palette: widget.palette,
        icon: Icon(
          Icons.font_download_outlined,
          color: widget.palette.secondaryText,
        ),
        label: ReaderFontStrings.empty,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: state.fonts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final ReaderFontDescriptor descriptor = state.fonts[index];
        return _ReaderFontMetadataLoader(
          controller: _controller,
          descriptor: descriptor,
          child: _ReaderFontTile(
            descriptor: descriptor,
            palette: widget.palette,
            previewBytes: state.previews[descriptor.id],
            installed: state.installedIds.contains(descriptor.id),
            selected: state.selectedFontId == descriptor.id,
            busy: state.busyIds.contains(descriptor.id),
            anyBusy: state.busyIds.isNotEmpty,
            metadataLoaded: state.metadataLoadedIds.contains(descriptor.id),
            metadataLoading: state.metadataLoadingIds.contains(descriptor.id),
            metadataFailed: state.metadataFailures.containsKey(descriptor.id),
            onInstall: () => unawaited(_controller.install(descriptor)),
            onSelect: () => unawaited(_controller.select(descriptor)),
            onRemove: () => unawaited(_controller.remove(descriptor)),
            onRetryMetadata: () =>
                unawaited(_controller.ensureMetadata(descriptor)),
          ),
        );
      },
    );
  }
}

class _ReaderFontMetadataLoader extends StatefulWidget {
  const _ReaderFontMetadataLoader({
    required this.controller,
    required this.descriptor,
    required this.child,
  });

  final ReaderFontCatalogController controller;
  final ReaderFontDescriptor descriptor;
  final Widget child;

  @override
  State<_ReaderFontMetadataLoader> createState() =>
      _ReaderFontMetadataLoaderState();
}

class _ReaderFontMetadataLoaderState extends State<_ReaderFontMetadataLoader> {
  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant _ReaderFontMetadataLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.descriptor != widget.descriptor) {
      _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.controller.ensureMetadata(widget.descriptor));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ReaderFontTile extends StatelessWidget {
  const _ReaderFontTile({
    required this.descriptor,
    required this.palette,
    required this.previewBytes,
    required this.installed,
    required this.selected,
    required this.busy,
    required this.anyBusy,
    required this.metadataLoaded,
    required this.metadataLoading,
    required this.metadataFailed,
    required this.onInstall,
    required this.onSelect,
    required this.onRemove,
    required this.onRetryMetadata,
  });

  final ReaderFontDescriptor descriptor;
  final ReaderPalette palette;
  final Uint8List? previewBytes;
  final bool installed;
  final bool selected;
  final bool busy;
  final bool anyBusy;
  final bool metadataLoaded;
  final bool metadataLoading;
  final bool metadataFailed;
  final VoidCallback onInstall;
  final VoidCallback onSelect;
  final VoidCallback onRemove;
  final VoidCallback onRetryMetadata;

  @override
  Widget build(BuildContext context) {
    final String metadata = <String>[
      if (descriptor.version?.trim().isNotEmpty == true)
        ReaderFontStrings.version(descriptor.version!.trim()),
      if (descriptor.fileSizeBytes != null && descriptor.fileSizeBytes! >= 0)
        ReaderFontStrings.fileSize(descriptor.fileSizeBytes!),
      descriptor.license?.trim().isNotEmpty == true
          ? descriptor.license!.trim()
          : ReaderFontStrings.licenseUnknown,
    ].join(' · ');
    return Semantics(
      container: true,
      selected: selected,
      child: Material(
        color: selected
            ? ReaderSettingsTokens.selectedControl(palette)
            : ReaderSettingsTokens.mutedControl(palette),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: previewBytes == null
                      ? ColoredBox(
                          color: palette.panel,
                          child: Icon(
                            Icons.text_fields_rounded,
                            color: palette.secondaryText,
                          ),
                        )
                      : Image.memory(
                          previewBytes!,
                          fit: BoxFit.cover,
                          cacheWidth: 128,
                          cacheHeight: 128,
                          filterQuality: FilterQuality.low,
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: palette.panel,
                            child: Icon(
                              Icons.text_fields_rounded,
                              color: palette.secondaryText,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      descriptor.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      descriptor.familyName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      metadata,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _FontActions(
                palette: palette,
                installed: installed,
                selected: selected,
                busy: busy,
                enabled: !anyBusy,
                metadataLoaded: metadataLoaded,
                metadataLoading: metadataLoading,
                metadataFailed: metadataFailed,
                onInstall: onInstall,
                onSelect: onSelect,
                onRemove: onRemove,
                onRetryMetadata: onRetryMetadata,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FontActions extends StatelessWidget {
  const _FontActions({
    required this.palette,
    required this.installed,
    required this.selected,
    required this.busy,
    required this.enabled,
    required this.metadataLoaded,
    required this.metadataLoading,
    required this.metadataFailed,
    required this.onInstall,
    required this.onSelect,
    required this.onRemove,
    required this.onRetryMetadata,
  });

  final ReaderPalette palette;
  final bool installed;
  final bool selected;
  final bool busy;
  final bool enabled;
  final bool metadataLoaded;
  final bool metadataLoading;
  final bool metadataFailed;
  final VoidCallback onInstall;
  final VoidCallback onSelect;
  final VoidCallback onRemove;
  final VoidCallback onRetryMetadata;

  @override
  Widget build(BuildContext context) {
    if (busy || metadataLoading || (!metadataLoaded && !metadataFailed)) {
      return Semantics(
        label: busy ? ReaderFontStrings.downloading : ReaderFontStrings.loading,
        child: const SizedBox.square(
          dimension: ReaderSettingsTokens.touchTarget,
          child: Padding(
            padding: EdgeInsets.all(13),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (metadataFailed) {
      return _action(ReaderFontStrings.retry, onRetryMetadata);
    }
    if (!installed) {
      return _action(ReaderFontStrings.download, enabled ? onInstall : null);
    }
    if (selected) {
      return _action(ReaderFontStrings.inUse, null);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _action(ReaderFontStrings.use, enabled ? onSelect : null),
        IconButton(
          tooltip: ReaderFontStrings.delete,
          onPressed: enabled ? onRemove : null,
          icon: const Icon(Icons.delete_outline_rounded, size: 19),
        ),
      ],
    );
  }

  Widget _action(String label, VoidCallback? onPressed) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: SizedBox(
        height: ReaderSettingsTokens.touchTarget,
        child: TextButton(onPressed: onPressed, child: Text(label)),
      ),
    );
  }
}

class _FontStatus extends StatelessWidget {
  const _FontStatus({
    required this.palette,
    required this.icon,
    required this.label,
    this.actionLabel,
    this.onAction,
  });

  final ReaderPalette palette;
  final Widget icon;
  final String label;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          icon,
          const SizedBox(height: 10),
          Text(label, style: TextStyle(color: palette.secondaryText)),
          if (onAction != null) ...<Widget>[
            const SizedBox(height: 8),
            SizedBox(
              height: ReaderSettingsTokens.touchTarget,
              child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ),
          ],
        ],
      ),
    );
  }
}
