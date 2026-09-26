/** Source-owned paging: retain every item of an upstream page before advancing. No IO or shared mutable state. */
export function position(cursor: string | null, target: string) {
  if (cursor === null) return { page: 1, offset: 0 };
  const prefix = target + ':';
  const value = cursor.startsWith(prefix) ? cursor.slice(prefix.length) : '';
  const match = /^(\d+)(?::(\d+))?$/u.exec(value);
  const page = Number(match?.[1]), offset = Number(match?.[2] ?? 0);
  if (!match || !Number.isSafeInteger(page) || page < 1 || page > 10000 || !Number.isSafeInteger(offset) || offset < 0 || offset > 10000) throw new Error('Discovery cursor is invalid.');
  return { page, offset };
}
export function window<T>(all: readonly T[], target: string, page: number, offset: number, size: number, hasNext: boolean) {
  const values = all.slice(offset, offset + size), next = offset + values.length;
  const cursor = next < all.length ? target + ':' + page + ':' + next : hasNext && all.length > 0 && page < 10000 ? target + ':' + (page + 1) + ':0' : null;
  return { values, continuation: cursor === null ? null : { target, cursor } };
}

export type DiscoveryResult = { kind: 'document'; document: { components: object[] } } | { kind: 'append'; collectionId: string; items: object[]; continuation: { target: string; cursor: string } | null };
