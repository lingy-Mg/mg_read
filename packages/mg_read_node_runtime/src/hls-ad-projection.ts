/**
 * Statistical projection of HLS URI/duration differences against learned content.
 * Five bounded features form a scalar distance histogram. Otsu separation and a
 * source-selected margin above normal variation nominate outliers, never remove
 * them. Sequence enclosure and transport-clock proof remain separate safeguards.
 */
type Input = { readonly url: string; readonly duration: number; readonly family: string };
type Features = { readonly origin: string; readonly directories: readonly string[]; readonly pattern: string; readonly length: number; readonly digits: number };
export type HlsAdProjection = { readonly scores: readonly number[]; readonly histogram: readonly number[]; readonly threshold: number };

export function projectHlsDifferences(segments: readonly Input[], primary: string, contrast: number): HlsAdProjection {
  const features = segments.map(segment => uriFeatures(segment.url));
  const originals = segments.flatMap((segment, index) => segment.family === primary ? [index] : []);
  const reference = features[originals[0]!]!;
  const length = quantile(originals.map(index => features[index]!.length), 0.5);
  const digits = quantile(originals.map(index => features[index]!.digits), 0.5);
  const duration = quantile(originals.map(index => segments[index]!.duration), 0.5);
  const scores = segments.map((segment, index) => {
    const value = features[index]!;
    const path = value.origin !== reference.origin ? 1 : 1 -
      value.directories.filter((part, position) => part === reference.directories[position]).length /
      Math.max(1, value.directories.length, reference.directories.length);
    return Math.min(1, 0.45 * path + 0.25 * patternDistance(value.pattern, reference.pattern) +
      0.1 * Math.abs(value.length - length) / Math.max(1, value.length, length) +
      0.1 * Math.abs(value.digits - digits) +
      0.1 * Math.min(1, Math.abs(Math.log2(segment.duration / duration)) / 3));
  });
  const histogram = Array<number>(32).fill(0);
  for (const score of scores) histogram[Math.min(31, Math.floor(score * 32))]! += 1;
  const threshold = Math.max(otsu(histogram), quantile(originals.map(index => scores[index]!), 0.95) + contrast);
  return { scores, histogram, threshold };
}

function uriFeatures(raw: string): Features {
  const url = new URL(raw), parts = url.pathname.split('/'), stem = parts.pop()!.replace(/\.ts$/u, '');
  const numbered = /^(.*?)(\d{3,24})$/u.exec(stem);
  const pattern = /^[a-f\d]{24,64}$/iu.test(stem) ? `hex:${stem.length}` : numbered === null
    ? `opaque:${stem.length}` : `number:${numbered[1]!.slice(0, 128)}:${numbered[2]!.length}`;
  return { origin: url.origin, directories: parts, pattern, length: stem.length, digits: (stem.match(/\d/gu) ?? []).length / Math.max(1, stem.length) };
}

function patternDistance(left: string, right: string): number {
  if (left === right) return 0;
  const grams = (value: string) => new Set(Array.from({ length: Math.max(0, value.length - 1) }, (_, index) => value.slice(index, index + 2)));
  const first = grams(left), second = grams(right);
  return 1 - 2 * [...first].filter(value => second.has(value)).length / Math.max(1, first.size + second.size);
}

function quantile(values: number[], fraction: number): number {
  values.sort((left, right) => left - right);
  return values[Math.floor((values.length - 1) * fraction)]!;
}

function otsu(histogram: readonly number[]): number {
  const total = histogram.reduce((sum, count) => sum + count, 0);
  const sum = histogram.reduce((value, count, index) => value + count * index, 0);
  let weight = 0, subtotal = 0, maximum = -1, threshold = 0;
  for (let index = 0; index < histogram.length - 1; index += 1) {
    weight += histogram[index]!; subtotal += histogram[index]! * index;
    if (weight === 0 || weight === total) continue;
    const difference = subtotal / weight - (sum - subtotal) / (total - weight);
    const variance = weight * (total - weight) * difference * difference;
    if (variance > maximum) { maximum = variance; threshold = (index + 1) / histogram.length; }
  }
  return threshold;
}
