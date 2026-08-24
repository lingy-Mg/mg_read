export function nonBlank(value: string | undefined): string | null {
  const normalized = value?.replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  return normalized === undefined || normalized.length === 0 ? null : normalized;
}
