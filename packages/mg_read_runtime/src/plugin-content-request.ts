/**
 * Strict request parsing for Plugin API content operations.
 * Parsing retains the existing key whitelist, bounds and frozen request objects.
 */

import type { JsonObject } from "./protocol.js";
import {
  MAX_CURSOR_CHARACTERS,
  MAX_ID_CHARACTERS,
  MAX_PAGE_SIZE,
  MAX_TEXT_METADATA_CHARACTERS,
  PluginContentValidationError,
  type ParsedPluginRequest,
  type PluginChaptersRequest,
  type PluginContentReferenceRequest,
  type PluginContentRequest,
  type PluginDiscoverRequest,
  type PluginSearchRequest,
  type PluginSearchSuggestionsRequest,
} from "./plugin-content-types.js";

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

export function parseSearchSuggestionsParams(
  params: JsonObject,
): ParsedPluginRequest<PluginSearchSuggestionsRequest> {
  assertOnlyKeys(params, ["pluginId", "cursor", "pageSize"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      cursor: readNullableCursor(params, "cursor"),
      pageSize: readPageSize(params, "pageSize"),
    }),
  });
}

export function parseDiscoverParams(
  params: JsonObject,
): ParsedPluginRequest<PluginDiscoverRequest> {
  assertOnlyKeys(params, ["pluginId", "target", "cursor", "collectionId", "pageSize"]);
  const cursor = readNullableCursor(params, "cursor");
  const collectionId = readNullableString(
    params,
    "collectionId",
    MAX_ID_CHARACTERS,
  );
  if ((cursor === null) !== (collectionId === null)) fail();
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      collectionId,
      cursor,
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
  assertOnlyKeys(params, ["pluginId", "id"]);
  return Object.freeze({
    pluginId: readPluginId(params, "pluginId"),
    request: Object.freeze({
      id: readRequiredString(params, "id", MAX_ID_CHARACTERS),
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

function readNullableCursor(
  raw: Record<string, unknown>,
  key: string,
): string | null {
  return readNullableString(raw, key, MAX_CURSOR_CHARACTERS);
}

function assertOnlyKeys(
  raw: Readonly<Record<string, unknown>>,
  allowed: readonly string[],
): void {
  const allowedSet = new Set(allowed);
  if (Object.keys(raw).some((key) => !allowedSet.has(key))) fail();
}

function fail(): never {
  throw new PluginContentValidationError();
}
