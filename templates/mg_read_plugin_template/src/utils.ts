export function requireActivated<T>(value: T | undefined): T {
  if (value === undefined) {
    throw new Error('Plugin has not been activated by MgRead Runtime.');
  }
  return value;
}

export function stableExampleId(value: string): string {
  return `example:${encodeURIComponent(value)}`;
}
