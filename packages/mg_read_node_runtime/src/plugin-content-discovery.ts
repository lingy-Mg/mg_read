/**
 * Recursive discovery document and append-result validation.
 * The traversal owns depth, component-count and unique-id enforcement.
 */

import {
  MAX_CATEGORIES,
  MAX_CURSOR_CHARACTERS,
  MAX_DISCOVERY_COMPONENTS,
  MAX_DISCOVERY_DEPTH,
  MAX_DISCOVERY_ITEMS,
  MAX_DISCOVERY_TABS,
  MAX_ID_CHARACTERS,
  MAX_LABEL_CHARACTERS,
  MAX_TEXT_METADATA_CHARACTERS,
  type PluginDiscoverResult,
  type PluginDiscoveryCategory,
  type PluginDiscoveryCategoryLayout,
  type PluginDiscoveryComponent,
  type PluginDiscoveryContentItem,
  type PluginDiscoveryContentLayout,
  type PluginDiscoveryContinuation,
  type PluginDiscoveryDocument,
  type PluginDiscoveryGroupLayout,
  type PluginDiscoveryIcon,
  type PluginDiscoveryMetric,
  type PluginDiscoveryTab,
} from "./plugin-content-types.js";
import {
  assertInlineBudget,
  assertUnique,
  fail,
  readArray,
  readEnum,
  readNullableCount,
  readNullableObject,
  readNullablePositiveInteger,
  readNullableString,
  readNullableUrl,
  readOptionalNullableEnum,
  readOwn,
  readRecord,
  readRequiredString,
  validateContentSummary,
} from "./plugin-content-validation.js";

const discoveryContentLayouts = new Set<PluginDiscoveryContentLayout>([
  "featured",
  "carousel",
  "coverGrid",
  "shelf",
  "compact",
  "ranking",
  "list",
]);
const discoveryCategoryLayouts = new Set<PluginDiscoveryCategoryLayout>([
  "grid",
  "chips",
  "list",
]);
const discoveryGroupLayouts = new Set<PluginDiscoveryGroupLayout>([
  "vertical",
  "horizontal",
  "grid",
]);
const discoveryIcons = new Set<PluginDiscoveryIcon>([
  "allTimeRanking", "audio", "book", "books", "category", "classic",
  "completed", "dailyRanking", "explore", "fanFiction", "fantasy",
  "free", "game", "globe", "history", "horror", "hot", "lightNovel",
  "manga", "military", "monthlyRanking", "mystery", "newRelease",
  "ongoing", "other", "ranking", "recommendation", "romance", "rural",
  "school", "scienceFiction", "sports", "star", "system", "timeTravel",
  "trending", "urban", "video", "weeklyRanking", "wuxia",
]);

export function validateDiscoverResult(
  pluginId: string,
  sourceName: string,
  value: unknown,
): PluginDiscoverResult {
  const raw = readRecord(value);
  const kind = readRequiredString(raw, "kind", MAX_LABEL_CHARACTERS);
  const result = kind === "document"
    ? Object.freeze({
        document: validateDiscoveryDocument(readOwn(raw, "document")),
        kind: "document" as const,
        pluginId,
        sourceName,
      })
    : kind === "append"
    ? Object.freeze({
        collectionId: readRequiredString(raw, "collectionId", MAX_ID_CHARACTERS),
        continuation: readNullableObject(
          raw,
          "continuation",
          validateDiscoveryContinuation,
        ),
        items: Object.freeze(
          readArray(raw, "items", MAX_DISCOVERY_ITEMS).map(
            validateDiscoveryContentItem,
          ),
        ),
        kind: "append" as const,
        pluginId,
        sourceName,
      })
    : fail('Discovery response field "kind" must be "document" or "append".');
  if (result.kind === "append") {
    assertUnique(result.items.map((item) => item.content.id));
  }
  assertInlineBudget(result);
  return result;
}

function validateDiscoveryTab(value: unknown): PluginDiscoveryTab {
  const raw = readRecord(value);
  return Object.freeze({
    icon: readOptionalNullableEnum(raw, "icon", discoveryIcons),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    label: readRequiredString(raw, "label", MAX_LABEL_CHARACTERS),
    target: readRequiredString(raw, "target", MAX_ID_CHARACTERS),
  });
}

function validateDiscoveryDocument(value: unknown): PluginDiscoveryDocument {
  const raw = readRecord(value);
  const state = { count: 0, ids: new Set<string>() };
  const components = Object.freeze(
    readArray(raw, "components", MAX_DISCOVERY_COMPONENTS).map((component, index) =>
      validateDiscoveryComponent(component, state, 1, index === 0),
    ),
  );
  const tabs = components.filter((component) => component.type === "tabs");
  if (tabs.length > 1 || (tabs.length === 1 && components[0]?.type !== "tabs")) {
    fail('Discovery document may contain at most one tabs component, and it must be the first root component.');
  }
  return Object.freeze({ components });
}

function validateDiscoveryComponent(
  value: unknown,
  state: { count: number; ids: Set<string> },
  depth: number,
  isFirstRootComponent: boolean,
): PluginDiscoveryComponent {
  if (depth > MAX_DISCOVERY_DEPTH) fail(`Discovery component depth ${depth} exceeds the limit of ${MAX_DISCOVERY_DEPTH}.`);
  if (++state.count > MAX_DISCOVERY_COMPONENTS) {
    fail(`Discovery document contains more than ${MAX_DISCOVERY_COMPONENTS} components.`);
  }
  const raw = readRecord(value);
  const id = readRequiredString(raw, "id", MAX_ID_CHARACTERS);
  if (state.ids.has(id)) fail('Discovery component validation found a duplicate component id.');
  state.ids.add(id);
  const type = readRequiredString(raw, "type", MAX_LABEL_CHARACTERS);
  switch (type) {
    case "tabs": {
      if (!isFirstRootComponent || depth !== 1) fail('Discovery tabs must be the first root component.');
      const tabs = Object.freeze(
        readArray(raw, "tabs", MAX_DISCOVERY_TABS).map(validateDiscoveryTab),
      );
      assertUnique(tabs.map((tab) => tab.id));
      const selectedTabId = readNullableString(raw, "selectedTabId", MAX_ID_CHARACTERS);
      if (
        (tabs.length === 0 && selectedTabId !== null) ||
        (selectedTabId !== null && !tabs.some((tab) => tab.id === selectedTabId))
      ) fail('Discovery field "selectedTabId" must identify one of the declared tabs.');
      return Object.freeze({ id, selectedTabId, tabs, type });
    }
    case "section":
      return Object.freeze({
        children: validateDiscoveryChildren(raw, state, depth),
        icon: readOptionalNullableEnum(raw, "icon", discoveryIcons),
        id,
        subtitle: readNullableString(raw, "subtitle", MAX_LABEL_CHARACTERS),
        title: readRequiredString(raw, "title", MAX_LABEL_CHARACTERS),
        type,
      });
    case "group":
      return Object.freeze({
        children: validateDiscoveryChildren(raw, state, depth),
        id,
        layout: readEnum(raw, "layout", discoveryGroupLayouts),
        type,
      });
    case "contentCollection": {
      const items = Object.freeze(
        readArray(raw, "items", MAX_DISCOVERY_ITEMS).map(
          validateDiscoveryContentItem,
        ),
      );
      assertUnique(items.map((item) => item.content.id));
      return Object.freeze({
        continuation: readNullableObject(
          raw,
          "continuation",
          validateDiscoveryContinuation,
        ),
        id,
        items,
        layout: readEnum(raw, "layout", discoveryContentLayouts),
        type,
      });
    }
    case "categoryCollection": {
      const categories = Object.freeze(
        readArray(raw, "categories", MAX_CATEGORIES).map(
          validateDiscoveryCategory,
        ),
      );
      assertUnique(categories.map((category) => category.id));
      return Object.freeze({
        categories,
        id,
        layout: readEnum(raw, "layout", discoveryCategoryLayouts),
        type,
      });
    }
    case "text":
      return Object.freeze({
        id,
        text: readRequiredString(raw, "text", MAX_TEXT_METADATA_CHARACTERS),
        type,
      });
    case "divider":
      return Object.freeze({ id, type });
    default:
      return fail('Discovery component field "type" is not one of the supported component kinds.');
  }
}

function validateDiscoveryChildren(
  raw: Record<string, unknown>,
  state: { count: number; ids: Set<string> },
  depth: number,
): readonly PluginDiscoveryComponent[] {
  return Object.freeze(
    readArray(raw, "children", MAX_DISCOVERY_COMPONENTS).map((child) =>
      validateDiscoveryComponent(child, state, depth + 1, false),
    ),
  );
}

function validateDiscoveryContinuation(
  value: unknown,
): PluginDiscoveryContinuation {
  const raw = readRecord(value);
  return Object.freeze({
    cursor: readRequiredString(raw, "cursor", MAX_CURSOR_CHARACTERS),
    target: readRequiredString(raw, "target", MAX_ID_CHARACTERS),
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
    icon: readOptionalNullableEnum(raw, "icon", discoveryIcons),
    id: readRequiredString(raw, "id", MAX_ID_CHARACTERS),
    target: readRequiredString(raw, "target", MAX_ID_CHARACTERS),
    title: readRequiredString(raw, "title", MAX_LABEL_CHARACTERS),
    url: readNullableUrl(raw, "url"),
  });
}
