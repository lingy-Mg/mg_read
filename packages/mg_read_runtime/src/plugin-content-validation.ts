/**
 * Flat Plugin API result validation and shared bounded value decoders.
 * Recursive discovery-tree validation is kept in plugin-content-discovery.ts.
 */

import type { JsonObject } from "./protocol.js";
import {
  MAX_ATTRIBUTES,
  MAX_CATEGORIES,
  MAX_CHAPTER_ITEMS,
  MAX_CURSOR_CHARACTERS,
  MAX_ID_CHARACTERS,
  MAX_INLINE_CHAPTER_CATALOG_BYTES,
  MAX_INLINE_RESULT_BYTES,
  MAX_INLINE_TEXT_BYTES,
  MAX_INLINE_MANGA_MANIFEST_BYTES,
  MAX_LABEL_CHARACTERS,
  MAX_MANGA_PAGES,
  MAX_SEARCH_ITEMS,
  MAX_SEARCH_SUGGESTIONS,
  MAX_TAGS,
  MAX_TEXT_METADATA_CHARACTERS,
  MAX_URL_CHARACTERS,
  PluginContentValidationError,
  type PluginAccessKind,
  type PluginChapterContent,
  type PluginChapterSummary,
  type PluginChaptersResult,
  type PluginContentAttribute,
  type PluginContentDetail,
  type PluginContentKind,
  type PluginContentStatus,
  type PluginLatestChapter,
  type PluginMangaPage,
  type PluginSearchResult,
  type PluginSearchSuggestionsResult,
} from "./plugin-content-types.js";

const contentKinds = new Set<PluginContentKind>(["novel", "manga"]);
const contentStatuses = new Set<PluginContentStatus>([
  "ongoing",
  "completed",
  "hiatus",
  "unknown",
]);
const accessKinds = new Set<PluginAccessKind>([
  "free",
  "paid",
  "mixed",
  "unknown",
]);

export function validateSearchResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginSearchResult {
  const raw = readRecord(value);
  const rawItems = readArray(raw, "items", MAX_SEARCH_ITEMS);
  const items = Object.freeze(rawItems.map(validateContentSummary));
  assertUnique(items.map((item) => item.id));
  const result = Object.freeze({
    items,
    nextCursor: readNullableCursor(raw, "nextCursor"),
    pluginId,
    sourceName,
    totalCount: readNullableCount(raw, "totalCount"),
  });
  assertInlineBudget(result);
  return result;
}

export function validateSearchSuggestionsResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginSearchSuggestionsResult {
  const raw = readRecord(value);
  const items = Object.freeze(
    readArray(raw, "items", MAX_SEARCH_SUGGESTIONS).map((item) => {
      const suggestion = readRecord(item);
      return Object.freeze({
        metric: readNullableString(suggestion, "metric", MAX_LABEL_CHARACTERS),
        query: readRequiredString(suggestion, "query", MAX_TEXT_METADATA_CHARACTERS),
      });
    }),
  );
  assertUnique(items.map((item) => item.query));
  const result = Object.freeze({
    items,
    nextCursor: readNullableCursor(raw, "nextCursor"),
    pluginId,
    sourceName,
  });
  assertInlineBudget(result);
  return result;
}

export function validateDetailResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginContentDetail & { readonly pluginId: string; readonly sourceName: string } {
  const raw = readRecord(value);
  const summary = validateContentSummary(raw);
  const result = Object.freeze({
    ...summary,
    aliases: readStringArray(raw, "aliases", MAX_TAGS, MAX_LABEL_CHARACTERS),
    catalogUrl: readNullableUrl(raw, "catalogUrl"),
    pluginId,
    sourceName,
  });
  assertInlineBudget(result, contentKind === "manga" ? MAX_INLINE_MANGA_MANIFEST_BYTES : MAX_INLINE_RESULT_BYTES);
  return result;
}

export function validateChaptersResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginChaptersResult {
  const raw = readRecord(value);
  assertOnlyKeys(raw, ["items"]);
  const items = Object.freeze(
    readArray(raw, "items", MAX_CHAPTER_ITEMS).map(validateChapterSummary),
  );
  assertUnique(items.map((item) => item.id));
  const result = Object.freeze({ items, pluginId, sourceName });
  assertInlineBudget(result, MAX_INLINE_CHAPTER_CATALOG_BYTES);
  return result;
}

export function validateContentResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginChapterContent {
  const raw = readRecord(value);
  const contentKind = readEnum(raw, "contentKind", contentKinds);
  const text = readNullableText(raw, "text");
  const pages = Object.freeze(
    readArray(raw, "pages", MAX_MANGA_PAGES).map(validateMangaPage),
  );
  if (
    (contentKind === "novel" && (text === null || pages.length !== 0)) ||
    (contentKind === "manga" && (text !== null || pages.length === 0))
  ) {
    fail();
  }
  assertUnique(pages.map((page) => page.id));
  for (const [index, page] of pages.entries()) {
    if (page.index !== index) fail();
  }
  const result = Object.freeze({
    chapterId: readRequiredString(raw, "chapterId", MAX_ID_CHARACTERS),
    contentKind,
    pages,
    pluginId,
    sourceName,
    text,
    title: readNullableString(raw, "title", MAX_LABEL_CHARACTERS),
    updatedAt: readNullableTimestamp(raw, "updatedAt"),
  });
  assertInlineBudget(result);
  return result;
}

export function pluginContentResultCount(value: JsonObject): number {
  const items = value.items;
  if (Array.isArray(items)) return items.length;
  const sections = value.sections;
  if (Array.isArray(sections)) return sections.length;
  const pages = value.pages;
  if (Array.isArray(pages)) return pages.length;
  return 1;
}

export function validateContentSummary(value: unknown) {
  const raw = readRecord(value);
  return Object.freeze({
    access: readEnum(raw, "access", accessKinds),
    attributes: readAttributes(raw, "attributes"),
    author: readNullableString(raw, "author", MAX_LABEL_CHARACTERS),
    categories: readStringArray(
      raw,
      "categories",
      MAX_CATEGORIES,
      MAX_LABEL_CHARACTERS,
    ),
    chapterCount: readNullableCount(raw, "chapterCount"),
    contentKind: readEnum(raw, "contentKind", contentKinds),
    coverUrl: readNullableUrl(raw, "coverUrl"),
    description: readNullableString(
      raw,
      "description",
      MAX_TEXT_METADATA_CHARACTERS,
    ),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    language: readNullableString(raw, "language", 64),
    latestChapter: readLatestChapter(raw, "latestChapter"),
    publishedAt: readNullableTimestamp(raw, "publishedAt"),
    status: readEnum(raw, "status", contentStatuses),
    tags: readStringArray(raw, "tags", MAX_TAGS, MAX_LABEL_CHARACTERS),
    title: readRequiredString(raw, "title", MAX_LABEL_CHARACTERS),
    updatedAt: readNullableTimestamp(raw, "updatedAt"),
    url: readNullableUrl(raw, "url"),
    wordCount: readNullableCount(raw, "wordCount"),
  });
}

function validateChapterSummary(value: unknown): PluginChapterSummary {
  const raw = readRecord(value);
  return Object.freeze({
    attributes: readAttributes(raw, "attributes"),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    isLocked: readNullableBoolean(raw, "isLocked"),
    order: readNonNegativeInteger(raw, "order"),
    title: readRequiredString(raw, "title", MAX_LABEL_CHARACTERS),
    updatedAt: readNullableTimestamp(raw, "updatedAt"),
    url: readNullableUrl(raw, "url"),
    volumeTitle: readNullableString(raw, "volumeTitle", MAX_LABEL_CHARACTERS),
    wordCount: readNullableCount(raw, "wordCount"),
  });
}

function validateMangaPage(value: unknown): PluginMangaPage {
  const raw = readRecord(value);
  const mimeType = readNullableString(raw, "mimeType", 128);
  if (mimeType !== null && !/^[a-z0-9][a-z0-9!#$&^_.+-]+\/[a-z0-9][a-z0-9!#$&^_.+-]+$/i.test(mimeType)) {
    fail();
  }
  const resourcePolicy = readOptionalEnum(raw, "resourcePolicy", new Set(["sessionOnly", "refreshable", "durable"] as const), "sessionOnly");
  const expiresAt = readOptionalTimestamp(raw, "expiresAt");
  if ((resourcePolicy === "refreshable") !== (expiresAt !== null)) fail();
  return Object.freeze({
    expiresAt,
    height: readNullablePositiveInteger(raw, "height"),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    index: readNonNegativeInteger(raw, "index"),
    mimeType,
    url: readRequiredUrl(raw, "url"),
    resourcePolicy,
    width: readNullablePositiveInteger(raw, "width"),
  });
}

function readOptionalEnum<const T extends string>(raw: Record<string, unknown>, key: string, values: ReadonlySet<T>, fallback: T): T {
  if (!Object.hasOwn(raw, key)) return fallback;
  const value = raw[key];
  if (typeof value !== "string" || !values.has(value as T)) fail();
  return value as T;
}

function readOptionalTimestamp(raw: Record<string, unknown>, key: string): string | null {
  if (!Object.hasOwn(raw, key)) return null;
  return readNullableTimestamp(raw, key);
}

function readLatestChapter(
  raw: Record<string, unknown>,
  key: string,
): PluginLatestChapter | null {
  return readNullableObject(raw, key, (value) => {
    const chapter = readRecord(value);
    return Object.freeze({
      id: readNullableString(chapter, "id", MAX_ID_CHARACTERS),
      title: readRequiredString(chapter, "title", MAX_LABEL_CHARACTERS),
      updatedAt: readNullableTimestamp(chapter, "updatedAt"),
      url: readNullableUrl(chapter, "url"),
    });
  });
}

function readAttributes(
  raw: Record<string, unknown>,
  key: string,
): readonly PluginContentAttribute[] {
  const attributes = readArray(raw, key, MAX_ATTRIBUTES).map((value) => {
    const attribute = readRecord(value);
    const attributeKey = readRequiredString(attribute, "key", 64);
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(attributeKey)) fail();
    return Object.freeze({
      key: attributeKey,
      label: readRequiredString(attribute, "label", MAX_LABEL_CHARACTERS),
      value: readRequiredString(
        attribute,
        "value",
        MAX_TEXT_METADATA_CHARACTERS,
      ),
    });
  });
  assertUnique(attributes.map((attribute) => attribute.key));
  return Object.freeze(attributes);
}

function readStringArray(
  raw: Record<string, unknown>,
  key: string,
  maximumItems: number,
  maximumCharacters: number,
): readonly string[] {
  const values = readArray(raw, key, maximumItems).map((value) =>
    readStandaloneString(value, maximumCharacters),
  );
  assertUnique(values);
  return Object.freeze(values);
}

export function readArray(
  raw: Record<string, unknown>,
  key: string,
  maximumItems: number,
): readonly unknown[] {
  const value = readOwn(raw, key);
  if (!Array.isArray(value) || value.length > maximumItems) fail();
  return value;
}

export function readRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) fail();
  return value as Record<string, unknown>;
}

export function readOwn(raw: Record<string, unknown>, key: string): unknown {
  if (!Object.hasOwn(raw, key)) fail();
  return raw[key];
}

export function readRequiredString(
  raw: Record<string, unknown>,
  key: string,
  maximumCharacters: number,
): string {
  return readStandaloneString(readOwn(raw, key), maximumCharacters);
}

function readStandaloneString(value: unknown, maximumCharacters: number): string {
  if (
    typeof value !== "string" ||
    value.length > maximumCharacters ||
    value.trim().length === 0
  ) {
    fail();
  }
  return value;
}

export function readNullableString(
  raw: Record<string, unknown>,
  key: string,
  maximumCharacters: number,
): string | null {
  const value = readOwn(raw, key);
  return value === null ? null : readStandaloneString(value, maximumCharacters);
}

function readNullableText(raw: Record<string, unknown>, key: string): string | null {
  const value = readOwn(raw, key);
  if (value === null) return null;
  if (
    typeof value !== "string" ||
    Buffer.byteLength(value, "utf8") > MAX_INLINE_TEXT_BYTES
  ) {
    fail();
  }
  return value;
}

function readNonNegativeInteger(
  raw: Record<string, unknown>,
  key: string,
): number {
  const value = readOwn(raw, key);
  if (!Number.isSafeInteger(value) || (value as number) < 0) fail();
  return value as number;
}

export function readNullableCount(
  raw: Record<string, unknown>,
  key: string,
): number | null {
  const value = readOwn(raw, key);
  if (value === null) return null;
  if (!Number.isSafeInteger(value) || (value as number) < 0) fail();
  return value as number;
}

export function readNullablePositiveInteger(
  raw: Record<string, unknown>,
  key: string,
): number | null {
  const value = readNullableCount(raw, key);
  if (value !== null && value < 1) fail();
  return value;
}

function readNullableBoolean(
  raw: Record<string, unknown>,
  key: string,
): boolean | null {
  const value = readOwn(raw, key);
  if (value !== null && typeof value !== "boolean") fail();
  return value as boolean | null;
}

export function readEnum<T extends string>(
  raw: Record<string, unknown>,
  key: string,
  allowed: ReadonlySet<T>,
): T {
  const value = readOwn(raw, key);
  if (typeof value !== "string" || !allowed.has(value as T)) fail();
  return value as T;
}

export function readOptionalNullableEnum<T extends string>(
  raw: Record<string, unknown>,
  key: string,
  allowed: ReadonlySet<T>,
): T | null {
  const value = raw[key];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !allowed.has(value as T)) fail();
  return value as T;
}

export function readNullableCursor(
  raw: Record<string, unknown>,
  key: string,
): string | null {
  return readNullableString(raw, key, MAX_CURSOR_CHARACTERS);
}

function readRequiredUrl(raw: Record<string, unknown>, key: string): string {
  const value = readRequiredString(raw, key, MAX_URL_CHARACTERS);
  validateUrl(value);
  return value;
}

export function readNullableUrl(
  raw: Record<string, unknown>,
  key: string,
): string | null {
  const value = readNullableString(raw, key, MAX_URL_CHARACTERS);
  if (value !== null) validateUrl(value);
  return value;
}

function validateUrl(value: string): void {
  try {
    const url = new URL(value);
    if (
      (url.protocol !== "http:" && url.protocol !== "https:") ||
      url.username.length !== 0 ||
      url.password.length !== 0
    ) {
      fail();
    }
  } catch (error) {
    if (error instanceof PluginContentValidationError) throw error;
    fail();
  }
}

function readNullableTimestamp(
  raw: Record<string, unknown>,
  key: string,
): string | null {
  const value = readNullableString(raw, key, 64);
  if (value === null) return null;
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    ) ||
    Number.isNaN(Date.parse(value))
  ) {
    fail();
  }
  return value;
}

export function readNullableObject<T>(
  raw: Record<string, unknown>,
  key: string,
  decode: (value: unknown) => T,
): T | null {
  const value = readOwn(raw, key);
  return value === null ? null : decode(value);
}

function assertOnlyKeys(
  raw: Readonly<Record<string, unknown>>,
  allowed: readonly string[],
): void {
  const allowedSet = new Set(allowed);
  if (Object.keys(raw).some((key) => !allowedSet.has(key))) fail();
}

export function assertUnique(values: readonly string[]): void {
  if (new Set(values).size !== values.length) fail();
}

export function assertInlineBudget(
  value: JsonObject,
  maximumBytes = MAX_INLINE_RESULT_BYTES,
): void {
  if (Buffer.byteLength(JSON.stringify(value), "utf8") > maximumBytes) fail();
}

export function fail(): never {
  throw new PluginContentValidationError();
}
