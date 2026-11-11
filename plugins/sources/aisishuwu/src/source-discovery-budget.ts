/**
 * 爱丽丝发现响应的内联字节预算。
 *
 * 职责：在封面已转换为宿主代理地址后，按最终 UTF-8 JSON 大小逐级压缩展示投影。
 * 注意：不删作品、不改身份/分页/封面，不修改详情缓存；预留 64 KiB 给 Runtime 补充字段。
 */
import { contentLimits } from './content-limits.js';
import { Buffer } from 'node:buffer';
import type { ContentSummary, DiscoverResult, DiscoveryComponent, DiscoveryContentItem } from './mgread-api.js';

export const discoveryPayloadMaximumBytes = contentLimits.inlineBytes - 64 * 1024;

export function discoveryPayloadBytes(result: DiscoverResult): number {
  return Buffer.byteLength(JSON.stringify(result), 'utf8');
}

export function compactDiscoveryResult(result: DiscoverResult): DiscoverResult {
  if (discoveryPayloadBytes(result) <= discoveryPayloadMaximumBytes) return result;
  // Preserve rich rows when possible. Only the response projection is reduced;
  // opening a book still returns its complete cached or freshly loaded detail.
  let projected = result;
  for (const [descriptionLimit, tagLimit, attributeLimit, compactLinks] of [
    [120, 4, 2, false], [80, 2, 1, false], [80, 2, 1, true],
    [40, 2, 1, true], [40, 0, 0, true], [20, 0, 0, true], [8, 0, 0, true], [0, 0, 0, true],
  ] as const) {
    const project = (content: ContentSummary): ContentSummary => Object.freeze({
      ...content,
      description: descriptionLimit === 0 || content.description === null
        ? null
        : Array.from(content.description).slice(0, descriptionLimit).join(''),
      tags: Object.freeze(content.tags.slice(0, tagLimit)),
      attributes: Object.freeze(content.attributes.slice(0, attributeLimit)),
      // Host navigation uses the opaque IDs, so these informational website
      // links can be omitted under pressure without changing any target.
      url: compactLinks ? null : content.url,
      latestChapter: compactLinks && content.latestChapter !== null
        ? Object.freeze({ ...content.latestChapter, url: null })
        : content.latestChapter,
    });
    projected = mapDiscoveryContent(result, project);
    if (discoveryPayloadBytes(projected) <= discoveryPayloadMaximumBytes) return projected;
  }
  throw new Error(`Discovery identity and cover fields exceed the inline payload budget after compacting summaries: ${discoveryPayloadBytes(projected)} bytes exceeds ${discoveryPayloadMaximumBytes} bytes.`);
}

function mapDiscoveryContent(
  result: DiscoverResult,
  project: (content: ContentSummary) => ContentSummary,
): DiscoverResult {
  const mapItems = (items: readonly DiscoveryContentItem[]): readonly DiscoveryContentItem[] =>
    Object.freeze(items.map((item) => Object.freeze({ ...item, content: project(item.content) })));
  const mapComponent = (component: DiscoveryComponent): DiscoveryComponent => {
    switch (component.type) {
      case 'section':
      case 'group':
        return Object.freeze({ ...component, children: Object.freeze(component.children.map(mapComponent)) });
      case 'contentCollection':
        return Object.freeze({ ...component, items: mapItems(component.items) });
      default:
        return component;
    }
  };
  return result.kind === 'append'
    ? Object.freeze({ ...result, items: mapItems(result.items) })
    : Object.freeze({
      ...result,
      document: Object.freeze({ components: Object.freeze(result.document.components.map(mapComponent)) }),
    });
}
