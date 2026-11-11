/// Local-book commit, replacement and anchor migration. The maintenance barrier
/// serializes this cut-over with local progress writes and file reclamation.
part of 'content_library.dart';

extension LocalDocumentImports on ContentLibrary {
  Future<List<String>> previewLocalImport(String id) async {
    final stage = await _localFiles.staging(id);
    final manifest = await _readLocalDraft(stage);
    final document = ParsedLocalDocument.fromJson(Map<String, Object?>.from(manifest['document']! as Map));
    final samples = <String>[];
    for (final index in <int>{0, document.chapters.length ~/ 2, document.chapters.length - 1}) {
      if (index < 0) continue;
      final body = await _readStagedJson(stage, document.chapters[index].contentFile);
      final text = _localBlocksText(body['blocks']);
      samples.add(text.length > 1800 ? text.substring(0, 1800) : text);
    }
    return samples;
  }

  Future<List<int>?> previewLocalImportCover(String id) async {
    final stage = await _localFiles.staging(id);
    final manifest = await _readLocalDraft(stage);
    final document = ParsedLocalDocument.fromJson(Map<String, Object?>.from(manifest['document']! as Map));
    final cover = document.resources.where((resource) => resource.id == document.coverResourceId).firstOrNull;
    if (cover == null || cover.bytes > ContentLimits.coverBytes) return null;
    return _localStageFile(stage, cover.file).readAsBytes();
  }

  Future<LocalImportSnapshot> commitLocalImport(
    String id, {
    String? title,
    String? author,
    String? documentId,
    LibraryProgress? progress,
    List<LibraryBookmarkEntry>? bookmarks,
    bool useSenderMetadata = false,
    List<int>? coverBytes,
    String coverMimeType = 'image/png',
  }) async {
    if (_closing || _localImports.containsKey(id)) throw const LocalDocumentException('task_busy');
    final record = await _localJob(id);
    if (record['status'] == 'succeeded') return LocalImportSnapshot.fromJson(record);
    if (record['status'] == 'cancelled') throw const LocalDocumentException('cancelled');
    final incomingProgress = progress;
    final incomingBookmarks = bookmarks;
    if (documentId != null && !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(documentId)) {
      throw const LocalDocumentException('invalid_document_id');
    }
    final op = _LocalImportOperation();
    _localImports[id] = op;
    try {
      final alreadyCommitted = await _persistence.metadataRecords.contentLibrary.localItemByGeneration(id);
      if (alreadyCommitted != null) {
        record.addAll({'status': 'succeeded', 'itemId': alreadyCommitted.itemId, 'errorCode': null, 'errorDetail': null});
        await _saveLocalJob(record);
        return LocalImportSnapshot.fromJson(record);
      }
      final stage = await _localFiles.staging(id);
      if (record['rawSha256'] case final String hash) await _localFiles.restoreDraft(id, hash);
      final manifest = await _readLocalDraft(stage);
      final document = ParsedLocalDocument.fromJson(Map<String, Object?>.from(manifest['document']! as Map));
      final chosenTitle = (title ?? record['title'] as String? ?? document.title).trim();
      if (chosenTitle.isEmpty || chosenTitle.length > 1024) throw const LocalDocumentException('invalid_title');
      if (author != null && author.length > 1024) throw const LocalDocumentException('invalid_author');
      record['status'] = 'validating';
      await _saveLocalJob(record);
      await _validateLocalDraft(stage, document, op.cancellation);
      final item = await _withStorageMaintenance(() async {
        op.cancellation.check();
        final cover = coverBytes == null ? null : await _prepareLocalCover(_localFiles, coverBytes);
        final hash = record['rawSha256']! as String;
        final replacement = record['replaceItemId'] as String?;
        final duplicate = replacement == null ? await _persistence.metadataRecords.contentLibrary.localItemByHash(hash) : null;
        if (duplicate != null) {
          final existingSession = await openLocalDocumentSession(LibraryItemId(duplicate.itemId));
          try {
            final state = await _transferLocalLocations(
              stage,
              existingSession!._document,
              duplicate.itemId,
              incomingProgress,
              incomingBookmarks,
              session: existingSession,
            );
            await _persistence.metadataRecords.transaction(() async {
              await _persistence.metadataRecords.contentLibrary.reactivateLocalItem(duplicate.itemId, maximumShelfItems);
              if (state.progress != null) await _persistence.metadataRecords.contentLibrary.saveProgress(duplicate.itemId, state.progress!);
              if (state.bookmarks != null) {
                await _persistence.metadataRecords.contentLibrary.replaceLocalBookmarks(duplicate.itemId, state.bookmarks!);
              }
              if (useSenderMetadata) {
                final incomingDetails = Map<String, Object?>.from(jsonDecode(duplicate.values['details_json']! as String) as Map);
                final local = Map<String, Object?>.from(incomingDetails['local'] as Map);
                if (documentId != null && documentId != duplicate.values['local_document_id']) {
                  local['documentAliases'] = <String>{
                    documentId,
                    ...List<String>.from(local['documentAliases'] as List? ?? const []),
                  }.take(100).toList();
                }
                local.remove('coverHash');
                local.remove('coverMimeType');
                if (cover != null) local.addAll(cover);
                incomingDetails['local'] = local;
                await _persistence.metadataRecords.contentLibrary.updateLocalDetails(
                  duplicate.itemId,
                  (await getLibraryItem(LibraryItemId(duplicate.itemId)))!.revision,
                  chosenTitle,
                  author ?? document.author,
                  jsonEncode(incomingDetails),
                );
              }
            });
            return (await getLibraryItem(LibraryItemId(duplicate.itemId)))!;
          } finally {
            await existingSession?.close();
          }
        }
        final target = replacement == null ? null : await _persistence.metadataRecords.contentLibrary.readItem(replacement);
        if (replacement != null && (target == null || target.values['item_revision'] != record['expectedRevision'])) {
          throw const LocalDocumentException('revision_conflict');
        }
        final itemId = target?.itemId ?? _id();
        final localContentKind = switch (document.readingKind) {
          LocalDocumentReadingKind.comic => ContentKind.manga,
          LocalDocumentReadingKind.text => ContentKind.novel,
          null => target == null ? ContentKind.novel : ContentKind.values.byName(target.values['content_kind']! as String),
        };
        final chosenDocumentId = target?.values['local_document_id'] as String? ?? documentId ?? _id();
        Map<String, Object?>? migratedProgress;
        List<Map<String, Object?>>? migratedBookmarks;
        final warnings = document.warnings.take(100).toList();
        final oldDetails = target == null
            ? <String, Object?>{}
            : Map<String, Object?>.from(jsonDecode(target.values['details_json']! as String) as Map);
        if (target != null) {
          final progress = await loadProgress(LibraryItemId(itemId));
          final previousItemKind = ContentKind.values.byName(target.values['content_kind']! as String);
          final bookmarks = await loadBookmarks(LibraryItemId(itemId), previousItemKind);
          final oldSession = await openLocalDocumentSession(LibraryItemId(itemId));
          try {
            if (localContentKind == ContentKind.manga && progress is LibraryMangaReadingProgress) {
              final mapped = await _mapLocalMangaAnchor(
                stage,
                document,
                oldSession,
                progress.chapterId,
                progress.imageId,
                progress.imageFraction,
                progress.bookFraction,
              );
              migratedProgress = _progressValues(
                LibraryMangaReadingProgress(
                  itemId: LibraryItemId(itemId),
                  chapterId: mapped.chapterId,
                  imageId: mapped.imageId,
                  imageFraction: progress.imageFraction,
                  chapterIndex: mapped.index,
                  bookFraction: progress.bookFraction,
                  updatedAtUtc: progress.updatedAtUtc,
                  readingSeconds: progress.readingSeconds,
                ),
              );
              if (!mapped.exact) warnings.add('reading_position_approximate');
            } else if (localContentKind == ContentKind.novel && progress is LibraryReadingProgress) {
              final mapped = await _mapLocalAnchor(
                stage,
                document,
                oldSession,
                progress.chapterId,
                progress.paragraphId,
                progress.characterOffset,
                progress.bookFraction,
                '',
                newHash: hash,
                cancel: op.cancellation,
              );
              migratedProgress = _progressValues(
                LibraryReadingProgress(
                  itemId: LibraryItemId(itemId),
                  chapterId: mapped.chapterId,
                  paragraphId: mapped.paragraphId,
                  characterOffset: mapped.offset,
                  chapterIndex: mapped.index,
                  chapterFraction: 0,
                  bookFraction: progress.bookFraction,
                  updatedAtUtc: progress.updatedAtUtc,
                  totalReadingSeconds: progress.totalReadingSeconds,
                ),
              );
              if (!mapped.exact) warnings.add('reading_position_approximate');
            }
            migratedBookmarks = [];
            for (final bookmark in bookmarks) {
              if (localContentKind == ContentKind.manga && bookmark is LibraryMangaBookmark) {
                final mapped = await _mapLocalMangaAnchor(
                  stage,
                  document,
                  oldSession,
                  bookmark.chapterId,
                  bookmark.imageId,
                  bookmark.imageFraction,
                  0,
                );
                if (!mapped.exact && warnings.length < 100) warnings.add('bookmark_approximate:${bookmark.id}');
                migratedBookmarks.add(
                  _bookmarkValues(
                    LibraryMangaBookmark(
                      id: bookmark.id,
                      itemId: LibraryItemId(itemId),
                      chapterId: mapped.chapterId,
                      imageId: mapped.imageId,
                      imageFraction: bookmark.imageFraction,
                      createdAtUtc: bookmark.createdAtUtc,
                    ),
                  ),
                );
                continue;
              }
              if (localContentKind != ContentKind.novel || bookmark is! LibraryBookmark) continue;
              final mapped = await _mapLocalAnchor(
                stage,
                document,
                oldSession,
                bookmark.chapterId,
                bookmark.paragraphId,
                bookmark.characterOffset,
                0,
                bookmark.excerpt,
                newHash: hash,
                cancel: op.cancellation,
              );
              if (!mapped.exact && warnings.length < 100) warnings.add('bookmark_approximate:${bookmark.id}');
              migratedBookmarks.add(
                _bookmarkValues(
                  LibraryBookmark(
                    id: bookmark.id,
                    itemId: LibraryItemId(itemId),
                    chapterId: mapped.chapterId,
                    paragraphId: mapped.paragraphId,
                    characterOffset: mapped.offset,
                    chapterTitle: document.chapters[mapped.index].title,
                    excerpt: bookmark.excerpt,
                    createdAtUtc: bookmark.createdAtUtc,
                  ),
                ),
              );
            }
            manifest['previousLocations'] = {
              'progress': progress == null ? null : _progressValues(progress),
              'bookmarks': [for (final bookmark in bookmarks) _bookmarkValues(bookmark)],
            };
          } finally {
            await oldSession?.close();
          }
        }
        if (incomingProgress != null || incomingBookmarks != null) {
          final imported = await _transferLocalLocations(stage, document, itemId, incomingProgress, incomingBookmarks);
          migratedProgress = imported.progress ?? migratedProgress;
          migratedBookmarks = imported.bookmarks ?? migratedBookmarks;
        }
        if (record['restoreLocationsFromGeneration'] case final String previousGeneration) {
          final checkpoint = await _localFiles.readGeneration(previousGeneration);
          if (checkpoint['previousLocations'] case final Map locations) {
            if (locations['progress'] case final Map values) migratedProgress = Map<String, Object?>.from(values);
            if (locations['bookmarks'] case final List values) {
              migratedBookmarks = [for (final value in values) Map<String, Object?>.from(value as Map)];
            }
          }
        }
        final previous = target == null
            ? null
            : {'generation': target.values['active_generation'], 'rawSha256': target.values['raw_sha256']};
        final details = <String, Object?>{
          ...oldDetails,
          'wordCount': document.wordCount,
          'language': document.language,
          'description': document.description,
          'chapterCount': document.logicalChapterCount,
          'statusLabel': '本地',
          'local': {
            ...Map<String, Object?>.from(oldDetails['local'] as Map? ?? const {}),
            ...?cover,
            'generation': id,
            'rawSha256': hash,
            'format': document.format.name,
            'readingKind': document.readingKind?.name,
            'logicalChapterStarts': _localLogicalChapterStartIndexes(document),
            'originalBytes': record['totalBytes'],
            'options': record['options'],
            'warnings': warnings,
            'previous': previous,
          },
        };
        manifest['documentId'] = chosenDocumentId;
        manifest['warnings'] = warnings;
        await _writeLocalJson('${stage.path}/parsed/manifest.json', manifest);
        op.cancellation.check();
        record['status'] = 'committing';
        await _saveLocalJob(record);
        await _localFiles.publish(taskId: id, generation: id, hash: hash);
        final committed = await _persistence.metadataRecords.contentLibrary.commitLocalDocument(
          itemId: itemId,
          documentId: chosenDocumentId,
          title: chosenTitle,
          author: author ?? record['author'] as String? ?? document.author,
          contentKind: localContentKind.code,
          format: document.format.name,
          rawSha256: hash,
          generation: id,
          detailsJson: jsonEncode(details),
          chapters: [
            for (final chapter in document.chapters)
              LocalCatalogWrite(
                id: _id(),
                key: chapter.id,
                title: chapter.title,
                index: chapter.index,
                reference: 'local:$id:${chapter.contentFile}',
                wordCount: chapter.wordCount,
              ),
          ],
          expectedRevision: record['expectedRevision'] as int?,
          maximumActiveItems: maximumShelfItems,
          progress: migratedProgress,
          bookmarks: migratedBookmarks,
        );
        await _persistence.metadataRecords.contentLibrary.retireLocalGenerations(itemId, id, previous?['generation'] as String?);
        return _storedItem(committed.item);
      });
      record.addAll({'status': 'succeeded', 'itemId': item.id.value, 'title': item.title, 'errorCode': null, 'errorDetail': null});
      await _saveLocalJob(record);
      await _localFiles.removeStaging(id);
    } on Object catch (error) {
      await _failLocalJob(record, error);
    } finally {
      _localImports.remove(id);
      op.done.complete();
    }
    return LocalImportSnapshot.fromJson(record);
  }

  Future<LocalImportSnapshot> reparseLocalDocument(LibraryItemId id, LocalDocumentParseOptions options) async {
    final session = await openLocalDocumentSession(id);
    if (session == null) throw const LocalDocumentException('item_missing');
    try {
      return await prepareLocalImport(
        LocalImportInput(
          fileName: '${session.item.title}.${session.format.name}',
          bytes: await _localFiles.originalLength(session.rawSha256),
          openRead: () => _localFiles.openOriginal(session.rawSha256),
        ),
        options: options,
        replaceItemId: id,
      );
    } finally {
      await session.close();
    }
  }

  Future<void> updateLocalDocumentMetadata(LibraryItemId id, {required String title, String? author}) => _withStorageMaintenance(() async {
    if (title.trim().isEmpty || title.length > 1024 || (author?.length ?? 0) > 1024) throw const LocalDocumentException('invalid_metadata');
    final row = await _persistence.metadataRecords.contentLibrary.readItem(id.value);
    if (row == null || row.values['origin_kind'] != 'local') throw const LocalDocumentException('item_missing');
    await _persistence.metadataRecords.contentLibrary.updateLocalDetails(
      id.value,
      row.values['item_revision']! as int,
      title.trim(),
      author,
      row.values['details_json']! as String,
    );
  });
}

List<int> _localLogicalChapterStartIndexes(ParsedLocalDocument document) {
  final chapterIndexes = <String, int>{for (final chapter in document.chapters) chapter.id: chapter.index};
  final rawStarts = document.attributes['logicalChapterStarts'];
  if (rawStarts is List) {
    final indexes = <int>[];
    for (final id in rawStarts.whereType<String>()) {
      final index = chapterIndexes[id];
      if (index != null && (indexes.isEmpty || index > indexes.last)) indexes.add(index);
    }
    if (indexes.isNotEmpty) return indexes;
  }
  final seen = <String>{};
  return <int>[
    for (final chapter in document.chapters)
      if (seen.add(chapter.href ?? chapter.id)) chapter.index,
  ];
}

Future<Map<String, Object?>> _readLocalDraft(Directory stage) async {
  final file = File('${stage.path}/parsed/manifest.json');
  if (!await file.exists()) throw const LocalDocumentException('preview_required');
  if (await file.length() > ContentLimits.epubContainerBytes) throw const LocalDocumentException('manifest_too_large');
  return Isolate.run(() => Map<String, Object?>.from(jsonDecode(file.readAsStringSync()) as Map));
}

File _localStageFile(Directory stage, String relative) {
  if (relative.isEmpty ||
      relative.startsWith('/') ||
      relative.contains('\\') ||
      relative.contains(':') ||
      relative.split('/').any((part) => part == '..' || part == '.' || part.isEmpty)) {
    throw const LocalDocumentException('invalid_resource_path');
  }
  return File('${stage.path}/parsed/$relative');
}

Future<Map<String, Object?>> _readStagedJson(Directory stage, String relative) async {
  final file = _localStageFile(stage, relative);
  if (await file.length() > 4 * 1024 * 1024) throw const LocalDocumentException('chapter_too_large');
  return Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map);
}

Future<void> _validateLocalDraft(Directory stage, ParsedLocalDocument document, LocalDocumentCancellation cancel) async {
  final keys = <String>{};
  for (final chapter in document.chapters) {
    cancel.check();
    if (chapter.index != keys.length || !keys.add(chapter.id)) throw const LocalDocumentException('invalid_catalog');
    final file = _localStageFile(stage, chapter.contentFile);
    if (!await file.exists() || await file.length() > 4 * 1024 * 1024) throw const LocalDocumentException('invalid_chapter');
  }
  for (final resource in document.resources) {
    cancel.check();
    final file = _localStageFile(stage, resource.file);
    if (!await file.exists() || await file.length() != resource.bytes) throw const LocalDocumentException('invalid_resource');
  }
}

String _localBlocksText(Object? value) {
  if (value is! List) return '';
  final text = StringBuffer();
  for (final block in value) {
    if (block is! Map) continue;
    if (block['text'] is String) {
      text.writeln(block['text']);
    } else if (block['spans'] is List) {
      for (final span in block['spans'] as List) {
        if (span is Map && span['text'] is String) text.write(span['text']);
      }
      text.writeln();
    }
    if (block['children'] is List) text.write(_localBlocksText(block['children']));
  }
  return text.toString();
}

Future<void> _writeLocalJson(String filePath, Map<String, Object?> document) => Isolate.run(() {
  File(filePath).writeAsStringSync(jsonEncode(document), flush: true);
});

Future<({Map<String, Object?>? progress, List<Map<String, Object?>>? bookmarks})> _transferLocalLocations(
  Directory stage,
  ParsedLocalDocument document,
  String itemId,
  LibraryProgress? progress,
  List<LibraryBookmarkEntry>? bookmarks, {
  LocalDocumentReadingSession? session,
}) async {
  if ((bookmarks?.length ?? 0) > 10000) throw const LocalDocumentException('too_many_bookmarks');
  Map<String, Object?>? progressValues;
  if (progress is LibraryReadingProgress) {
    if (document.readingKind != LocalDocumentReadingKind.text) throw const LocalDocumentException('reading_kind_mismatch');
    final anchor = await _mapLocalAnchor(
      stage,
      document,
      null,
      progress.chapterId,
      progress.paragraphId,
      progress.characterOffset,
      progress.bookFraction,
      '',
      targetSession: session,
    );
    progressValues = _progressValues(
      LibraryReadingProgress(
        itemId: LibraryItemId(itemId),
        chapterId: anchor.chapterId,
        paragraphId: anchor.paragraphId,
        characterOffset: anchor.offset,
        chapterIndex: anchor.index,
        chapterFraction: progress.chapterFraction,
        bookFraction: progress.bookFraction,
        updatedAtUtc: progress.updatedAtUtc,
        totalReadingSeconds: progress.totalReadingSeconds,
      ),
    );
  } else if (progress is LibraryMangaReadingProgress) {
    if (document.readingKind != LocalDocumentReadingKind.comic) throw const LocalDocumentException('reading_kind_mismatch');
    final anchor = await _mapLocalMangaAnchor(
      stage,
      document,
      session,
      progress.chapterId,
      progress.imageId,
      progress.imageFraction,
      progress.bookFraction,
      chapterIndex: progress.chapterIndex,
    );
    progressValues = _progressValues(
      LibraryMangaReadingProgress(
        itemId: LibraryItemId(itemId),
        chapterId: anchor.chapterId,
        imageId: anchor.imageId,
        imageFraction: progress.imageFraction,
        chapterIndex: anchor.index,
        bookFraction: progress.bookFraction,
        updatedAtUtc: progress.updatedAtUtc,
        readingSeconds: progress.readingSeconds,
      ),
    );
  } else if (progress != null) {
    throw const LocalDocumentException('unsupported_local_progress');
  }
  List<Map<String, Object?>>? bookmarkValues;
  if (bookmarks != null) {
    bookmarkValues = [];
    for (final bookmark in bookmarks) {
      if (bookmark is LibraryMangaBookmark) {
        if (document.readingKind != LocalDocumentReadingKind.comic) throw const LocalDocumentException('reading_kind_mismatch');
        final sourceChapterIndex = session?.chapterById(bookmark.chapterId)?.index;
        final anchor = await _mapLocalMangaAnchor(
          stage,
          document,
          session,
          bookmark.chapterId,
          bookmark.imageId,
          bookmark.imageFraction,
          0,
          chapterIndex: sourceChapterIndex,
        );
        bookmarkValues.add(
          _bookmarkValues(
            LibraryMangaBookmark(
              id: bookmark.id,
              itemId: LibraryItemId(itemId),
              chapterId: anchor.chapterId,
              imageId: anchor.imageId,
              imageFraction: bookmark.imageFraction,
              createdAtUtc: bookmark.createdAtUtc,
            ),
          ),
        );
        continue;
      }
      if (bookmark is! LibraryBookmark || document.readingKind != LocalDocumentReadingKind.text) {
        throw const LocalDocumentException('reading_kind_mismatch');
      }
      final anchor = await _mapLocalAnchor(
        stage,
        document,
        null,
        bookmark.chapterId,
        bookmark.paragraphId,
        bookmark.characterOffset,
        0,
        bookmark.excerpt,
        targetSession: session,
      );
      bookmarkValues.add(
        _bookmarkValues(
          LibraryBookmark(
            id: bookmark.id,
            itemId: LibraryItemId(itemId),
            chapterId: anchor.chapterId,
            paragraphId: anchor.paragraphId,
            characterOffset: anchor.offset,
            chapterTitle: document.chapters[anchor.index].title,
            excerpt: bookmark.excerpt,
            createdAtUtc: bookmark.createdAtUtc,
          ),
        ),
      );
    }
  }
  return (progress: progressValues, bookmarks: bookmarkValues);
}

Future<({String chapterId, String imageId, int index, bool exact})> _mapLocalMangaAnchor(
  Directory stage,
  ParsedLocalDocument document,
  LocalDocumentReadingSession? sourceSession,
  String sourceChapterId,
  String sourceImageId,
  double imageFraction,
  double bookFraction, {
  int? chapterIndex,
}) async {
  if (!imageFraction.isFinite || imageFraction < 0 || imageFraction > 1 || !bookFraction.isFinite || bookFraction < 0 || bookFraction > 1) {
    throw const LocalDocumentException('invalid_manga_position');
  }
  final sourceChapter = sourceSession?.chapterById(sourceChapterId);
  final sourceIndex = chapterIndex ?? sourceChapter?.index ?? (bookFraction * document.chapters.length).floor();
  int? sourceImageIndex;
  if (sourceSession != null && sourceChapter != null) {
    sourceImageIndex = _localImageBlocks(
      (await sourceSession.readChapter(sourceChapterId))['blocks'],
    ).indexWhere((block) => block['id'] == sourceImageId);
    if (sourceImageIndex == -1) sourceImageIndex = null;
  }

  var targetIndex = document.chapters.indexWhere((chapter) => chapter.id == sourceChapterId);
  if (targetIndex < 0) targetIndex = sourceIndex.clamp(0, document.chapters.length - 1);
  var targetChapter = document.chapters[targetIndex];
  var targetImages = await _localMangaImages(stage, document, targetChapter, null);
  final exactImage = targetImages.where((block) => block['id'] == sourceImageId).firstOrNull;
  if (exactImage != null) {
    return (chapterId: targetChapter.id, imageId: exactImage['id']! as String, index: targetIndex, exact: true);
  }

  sourceImageIndex ??= 0;
  if (targetImages.isEmpty) {
    for (var offset = 1; offset < document.chapters.length; offset++) {
      final candidateIndex = (targetIndex + offset).clamp(0, document.chapters.length - 1);
      if (candidateIndex == targetIndex) continue;
      final candidate = document.chapters[candidateIndex];
      final images = await _localMangaImages(stage, document, candidate, null);
      if (images.isNotEmpty) {
        targetIndex = candidateIndex;
        targetChapter = candidate;
        targetImages = images;
        break;
      }
    }
  }
  if (targetImages.isEmpty) throw const LocalDocumentException('manga_image_anchor_missing');
  final fallback = targetImages[sourceImageIndex.clamp(0, targetImages.length - 1)];
  return (chapterId: targetChapter.id, imageId: fallback['id']! as String, index: targetIndex, exact: false);
}

Future<List<Map<String, Object?>>> _localMangaImages(
  Directory stage,
  ParsedLocalDocument document,
  LocalDocumentChapter chapter,
  LocalDocumentReadingSession? session,
) async {
  final body = session == null ? await _readStagedJson(stage, chapter.contentFile) : await session.readChapter(chapter.id);
  return _localImageBlocks(body['blocks']);
}

List<Map<String, Object?>> _localImageBlocks(Object? blocks) {
  if (blocks is! List) return const <Map<String, Object?>>[];
  final images = <Map<String, Object?>>[];
  void visit(Object? value) {
    if (value is! List) return;
    for (final block in value) {
      if (block is! Map) continue;
      final map = Map<String, Object?>.from(block);
      if (map['type'] == 'image' && map['id'] is String && (map['id']! as String).isNotEmpty) images.add(map);
      visit(map['children']);
    }
  }

  visit(blocks);
  return images;
}
