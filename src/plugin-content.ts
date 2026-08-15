import type { JsonObject } from "./protocol.js";

const MAX_ID_CHARACTERS = 8_192;
const MAX_LABEL_CHARACTERS = 256;
const MAX_TEXT_METADATA_CHARACTERS = 32_768;
const MAX_URL_CHARACTERS = 8_192;
const MAX_CURSOR_CHARACTERS = 2_048;
const MAX_PAGE_SIZE = 50;
const MAX_SEARCH_ITEMS = 50;
const MAX_DISCOVERY_TABS = 16;
const MAX_DISCOVERY_SECTIONS = 20;
const MAX_DISCOVERY_ITEMS = 50;
const MAX_CATEGORIES = 32;
const MAX_TAGS = 64;
const MAX_ATTRIBUTES = 32;
const MAX_CHAPTER_ITEMS = 200;
const MAX_MANGA_PAGES = 500;
const MAX_INLINE_RESULT_BYTES = 56 * 1_024;
const MAX_INLINE_TEXT_BYTES = 48 * 1_024;

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
const discoveryLayouts = new Set<PluginDiscoveryLayout>([
  "featured",
  "carousel",
  "ranking",
  "list",
  "categories",
]);

/** Content kinds shared by package metadata, Plugin API, wire and Flutter. */
export type PluginContentKind = "manga" | "novel";

/** Stable publication state. Unknown is explicit and never encoded as null. */
export type PluginContentStatus =
  | "completed"
  | "hiatus"
  | "ongoing"
  | "unknown";

/** Stable access projection. Unknown is explicit and never encoded as null. */
export type PluginAccessKind = "free" | "mixed" | "paid" | "unknown";

/** Host-supported discovery presentation hint. */
export type PluginDiscoveryLayout =
  | "carousel"
  | "categories"
  | "featured"
  | "list"
  | "ranking";

/** Operation names used by the one Runtime plugin-invocation diagnostic span. */
export type PluginContentOperation =
  | "discover"
  | "getChapters"
  | "getContent"
  | "getDetail"
  | "search";

export interface PluginContentAttribute extends JsonObject {
  readonly key: string;
  readonly label: string;
  readonly value: string;
}

export interface PluginLatestChapter extends JsonObject {
  readonly id: string | null;
  readonly title: string;
  readonly updatedAt: string | null;
  readonly url: string | null;
}

/** Fixed rich summary shared by search, discovery and detail. */
export interface PluginContentSummary extends JsonObject {
  readonly access: PluginAccessKind;
  readonly attributes: readonly PluginContentAttribute[];
  readonly author: string | null;
  readonly categories: readonly string[];
  readonly chapterCount: number | null;
  readonly contentKind: PluginContentKind;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly id: string;
  readonly language: string | null;
  readonly latestChapter: PluginLatestChapter | null;
  readonly publishedAt: string | null;
  readonly status: PluginContentStatus;
  readonly tags: readonly string[];
  readonly title: string;
  readonly updatedAt: string | null;
  readonly url: string | null;
  readonly wordCount: number | null;
}

export interface PluginSearchRequest extends JsonObject {
  readonly cursor: string | null;
  readonly pageSize: number;
  readonly query: string;
}

export interface PluginSearchResult extends JsonObject {
  readonly items: readonly PluginContentSummary[];
  readonly nextCursor: string | null;
  readonly pluginId: string;
  readonly sourceName: string;
  readonly totalCount: number | null;
}

export interface PluginDiscoverRequest extends JsonObject {
  readonly cursor: string | null;
  readonly pageSize: number;
  readonly target: string | null;
}

export interface PluginDiscoveryTab extends JsonObject {
  readonly id: string;
  readonly label: string;
  readonly target: string;
}

export interface PluginDiscoveryMetric extends JsonObject {
  readonly label: string;
  readonly value: string;
}

export interface PluginDiscoveryContentItem extends JsonObject {
  readonly content: PluginContentSummary;
  readonly metric: PluginDiscoveryMetric | null;
  readonly rank: number | null;
  readonly recommendation: string | null;
}

export interface PluginDiscoveryCategory extends JsonObject {
  readonly count: number | null;
  readonly id: string;
  readonly target: string;
  readonly title: string;
  readonly url: string | null;
}

export interface PluginDiscoverySection extends JsonObject {
  readonly categories: readonly PluginDiscoveryCategory[];
  readonly id: string;
  readonly items: readonly PluginDiscoveryContentItem[];
  readonly layout: PluginDiscoveryLayout;
  readonly subtitle: string | null;
  readonly title: string;
}

export interface PluginDiscoverResult extends JsonObject {
  readonly nextCursor: string | null;
  readonly pluginId: string;
  readonly sections: readonly PluginDiscoverySection[];
  readonly selectedTabId: string | null;
  readonly sourceName: string;
  readonly tabs: readonly PluginDiscoveryTab[];
}

export interface PluginContentReferenceRequest extends JsonObject {
  readonly id: string;
}

export interface PluginContentDetail extends PluginContentSummary {
  readonly aliases: readonly string[];
  readonly catalogUrl: string | null;
}

export interface PluginChaptersRequest extends JsonObject {
  readonly cursor: string | null;
  readonly id: string;
  readonly pageSize: number;
}

export interface PluginChapterSummary extends JsonObject {
  readonly attributes: readonly PluginContentAttribute[];
  readonly id: string;
  readonly isLocked: boolean | null;
  readonly order: number;
  readonly title: string;
  readonly updatedAt: string | null;
  readonly url: string | null;
  readonly volumeTitle: string | null;
  readonly wordCount: number | null;
}

export interface PluginChaptersResult extends JsonObject {
  readonly items: readonly PluginChapterSummary[];
  readonly nextCursor: string | null;
  readonly pluginId: string;
  readonly sourceName: string;
  readonly totalCount: number | null;
}

export interface PluginContentRequest extends JsonObject {
  readonly chapterId: string;
  readonly id: string;
}

export interface PluginMangaPage extends JsonObject {
  readonly height: number | null;
  readonly id: string;
  readonly index: number;
  readonly mimeType: string | null;
  readonly url: string;
  readonly width: number | null;
}

export interface PluginChapterContent extends JsonObject {
  readonly chapterId: string;
  readonly contentKind: PluginContentKind;
  readonly pages: readonly PluginMangaPage[];
  readonly pluginId: string;
  readonly sourceName: string;
  readonly text: string | null;
  readonly title: string | null;
  readonly updatedAt: string | null;
}

export interface ParsedPluginRequest<T extends JsonObject> {
  readonly pluginId: string;
  readonly request: T;
}

/** Stable validation failure mapped to plugin_invalid_response/invalid_request. */
export class PluginContentValidationError extends Error {
  constructor() {
    super("The Plugin API content object is invalid.");
    this.name = "PluginContentValidationError";
  }
}

export function parseSearchParams(
  params: JsonObject,
): ParsedPluginRequest<PluginSearchRequest> {
  assertOnlyKeys(params, ["pluginId", "query", "cursor", "pageSize"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      cursor: readNullableCursor(params, "cursor"),
      pageSize: readPageSize(params, "pageSize"),
      query: readRequiredString(params, "query", MAX_TEXT_METADATA_CHARACTERS),
    }),
  });
}

export function parseDiscoverParams(
  params: JsonObject,
): ParsedPluginRequest<PluginDiscoverRequest> {
  assertOnlyKeys(params, ["pluginId", "target", "cursor", "pageSize"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      cursor: readNullableCursor(params, "cursor"),
      pageSize: readPageSize(params, "pageSize"),
      target: readNullableString(params, "target", MAX_ID_CHARACTERS),
    }),
  });
}

export function parseDetailParams(
  params: JsonObject,
): ParsedPluginRequest<PluginContentReferenceRequest> {
  assertOnlyKeys(params, ["pluginId", "id"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      id: readRequiredString(params, "id", MAX_ID_CHARACTERS),
    }),
  });
}

export function parseChaptersParams(
  params: JsonObject,
): ParsedPluginRequest<PluginChaptersRequest> {
  assertOnlyKeys(params, ["pluginId", "id", "cursor", "pageSize"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      cursor: readNullableCursor(params, "cursor"),
      id: readRequiredString(params, "id", MAX_ID_CHARACTERS),
      pageSize: readPageSize(params, "pageSize"),
    }),
  });
}

export function parseContentParams(
  params: JsonObject,
): ParsedPluginRequest<PluginContentRequest> {
  assertOnlyKeys(params, ["pluginId", "id", "chapterId"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      chapterId: readRequiredString(params, "chapterId", MAX_ID_CHARACTERS),
      id: readRequiredString(params, "id", MAX_ID_CHARACTERS),
    }),
  });
}

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

export function validateDiscoverResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginDiscoverResult {
  const raw = readRecord(value);
  const tabs = Object.freeze(
    readArray(raw, "tabs", MAX_DISCOVERY_TABS).map(validateDiscoveryTab),
  );
  assertUnique(tabs.map((tab) => tab.id));
  const selectedTabId = readNullableString(
    raw,
    "selectedTabId",
    MAX_ID_CHARACTERS,
  );
  if (
    (tabs.length === 0 && selectedTabId !== null) ||
    (selectedTabId !== null && !tabs.some((tab) => tab.id === selectedTabId))
  ) {
    fail();
  }
  const sections = Object.freeze(
    readArray(raw, "sections", MAX_DISCOVERY_SECTIONS).map(
      validateDiscoverySection,
    ),
  );
  assertUnique(sections.map((section) => section.id));
  const result = Object.freeze({
    nextCursor: readNullableCursor(raw, "nextCursor"),
    pluginId,
    sections,
    selectedTabId,
    sourceName,
    tabs,
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
  assertInlineBudget(result);
  return result;
}

export function validateChaptersResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginChaptersResult {
  const raw = readRecord(value);
  const items = Object.freeze(
    readArray(raw, "items", MAX_CHAPTER_ITEMS).map(validateChapterSummary),
  );
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

function validateContentSummary(value: unknown): PluginContentSummary {
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

function validateDiscoveryTab(value: unknown): PluginDiscoveryTab {
  const raw = readRecord(value);
  return Object.freeze({
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    label: readRequiredString(raw, "label", MAX_LABEL_CHARACTERS),
    target: readRequiredString(raw, "target", MAX_ID_CHARACTERS),
  });
}

function validateDiscoverySection(value: unknown): PluginDiscoverySection {
  const raw = readRecord(value);
  const layout = readEnum(raw, "layout", discoveryLayouts);
  const items = Object.freeze(
    readArray(raw, "items", MAX_DISCOVERY_ITEMS).map(
      validateDiscoveryContentItem,
    ),
  );
  const categories = Object.freeze(
    readArray(raw, "categories", MAX_CATEGORIES).map(
      validateDiscoveryCategory,
    ),
  );
  assertUnique(items.map((item) => item.content.id));
  assertUnique(categories.map((category) => category.id));
  if (
    (layout === "categories" && items.length !== 0) ||
    (layout !== "categories" && categories.length !== 0)
  ) {
    fail();
  }
  return Object.freeze({
    categories,
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    items,
    layout,
    subtitle: readNullableString(raw, "subtitle", MAX_LABEL_CHARACTERS),
    title: readRequiredString(raw, "title", MAX_LABEL_CHARACTERS),
  });
}

function validateDiscoveryContentItem(
  value: unknown,
): PluginDiscoveryContentItem {
  const raw = readRecord(value);
  return Object.freeze({
    content: validateContentSummary(readOwn(raw, "content")),
    metric: readNullableObject(raw, "metric", validateDiscoveryMetric),
    rank: readNullablePositiveInteger(raw, "rank"),
    recommendation: readNullableString(
      raw,
      "recommendation",
      MAX_TEXT_METADATA_CHARACTERS,
    ),
  });
}

function validateDiscoveryMetric(value: unknown): PluginDiscoveryMetric {
  const raw = readRecord(value);
  return Object.freeze({
    label: readRequiredString(raw, "label", MAX_LABEL_CHARACTERS),
    value: readRequiredString(raw, "value", MAX_LABEL_CHARACTERS),
  });
}

function validateDiscoveryCategory(value: unknown): PluginDiscoveryCategory {
  const raw = readRecord(value);
  return Object.freeze({
    count: readNullableCount(raw, "count"),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    target: readRequiredString(raw, "target", MAX_ID_CHARACTERS),
    title: readRequiredString(raw, "title", MAX_LABEL_CHARACTERS),
    url: readNullableUrl(raw, "url"),
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
  return Object.freeze({
    height: readNullablePositiveInteger(raw, "height"),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    index: readNonNegativeInteger(raw, "index"),
    mimeType,
    url: readRequiredUrl(raw, "url"),
    width: readNullablePositiveInteger(raw, "width"),
  });
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

function readArray(
  raw: Record<string, unknown>,
  key: string,
  maximumItems: number,
): readonly unknown[] {
  const value = readOwn(raw, key);
  if (!Array.isArray(value) || value.length > maximumItems) fail();
  return value;
}

function readRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) fail();
  return value as Record<string, unknown>;
}

function readOwn(raw: Record<string, unknown>, key: string): unknown {
  if (!Object.hasOwn(raw, key)) fail();
  return raw[key];
}

function readRequiredString(
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

function readNullableString(
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

function readPluginId(raw: Record<string, unknown>, key: string): string {
  const value = readRequiredString(raw, key, 256);
  if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)+$/.test(value)) fail();
  return value;
}

function readPageSize(raw: Record<string, unknown>, key: string): number {
  const value = readNonNegativeInteger(raw, key);
  if (value < 1 || value > MAX_PAGE_SIZE) fail();
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

function readNullableCount(
  raw: Record<string, unknown>,
  key: string,
): number | null {
  const value = readOwn(raw, key);
  if (value === null) return null;
  if (!Number.isSafeInteger(value) || (value as number) < 0) fail();
  return value as number;
}

function readNullablePositiveInteger(
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

function readEnum<T extends string>(
  raw: Record<string, unknown>,
  key: string,
  allowed: ReadonlySet<T>,
): T {
  const value = readOwn(raw, key);
  if (typeof value !== "string" || !allowed.has(value as T)) fail();
  return value as T;
}

function readNullableCursor(
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

function readNullableUrl(
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

function readNullableObject<T>(
  raw: Record<string, unknown>,
  key: string,
  decode: (value: unknown) => T,
): T | null {
  const value = readOwn(raw, key);
  return value === null ? null : decode(value);
}

function assertOnlyKeys(raw: JsonObject, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed);
  if (Object.keys(raw).some((key) => !allowedSet.has(key))) fail();
}

function assertUnique(values: readonly string[]): void {
  if (new Set(values).size !== values.length) fail();
}

function assertInlineBudget(value: JsonObject): void {
  if (Buffer.byteLength(JSON.stringify(value), "utf8") > MAX_INLINE_RESULT_BYTES) {
    fail();
  }
}

function fail(): never {
  throw new PluginContentValidationError();
}
