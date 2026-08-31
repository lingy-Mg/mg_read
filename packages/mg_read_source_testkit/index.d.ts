/** 数据源测试库公开类型；实现仅依赖 Plugin API v1 的测试侧投影。 */
export declare const standardSourceExports: readonly string[];

export declare class SourceTestFailure extends Error {
  readonly code: string;
  readonly stage: string;
  readonly summary: Readonly<Record<string, unknown>>;
  constructor(code: string, stage: string, summary?: Record<string, unknown>);
  toJSON(): Readonly<Record<string, unknown>>;
}

export interface SourcePlugin {
  activate(context: Record<string, unknown>): Promise<void>;
  discover(request: Record<string, unknown>): Promise<unknown>;
  search(request: Record<string, unknown>): Promise<unknown>;
  searchSuggestions?(request: Record<string, unknown>): Promise<unknown>;
  getDetail(request: { readonly id: string }): Promise<unknown>;
  getChapters(request: { readonly id: string }): Promise<unknown>;
  getContent(request: { readonly id: string; readonly chapterId: string }): Promise<unknown>;
}

export declare function loadSourcePackage(packageJsonUrl: URL): Promise<Record<string, unknown>>;

export declare function assertStandardSourceContract(options: {
  readonly plugin: Record<string, unknown>;
  readonly packageJson: Record<string, unknown>;
  readonly pluginId: string;
  readonly optionalExports?: readonly string[];
  readonly packageMode?: string;
  readonly icon?: string;
}): Readonly<Record<string, unknown>>;

export declare function createSourceTestHarness(options: {
  readonly plugin: SourcePlugin;
  readonly pluginId: string;
  readonly version: string;
  readonly fetch?: typeof globalThis.fetch;
  readonly prefix?: string;
  readonly runtimeVersion?: string;
  readonly resourceProxy?: (
    request: Readonly<Record<string, unknown>>,
    index: number,
  ) => string;
}): Promise<Readonly<{
  root: string;
  context: Readonly<Record<string, unknown>>;
  resourceRequests: Readonly<Record<string, unknown>>[];
  logEvents: Readonly<Record<string, unknown>>[];
  cleanup(): Promise<void>;
  summary(): Readonly<Record<string, number>>;
}>>;

export declare function assertInlineJsonSize(
  value: unknown,
  options: { readonly maximumBytes: number; readonly stage?: string },
): number;

export declare function probeReachableResource(options: {
  readonly requests: readonly Readonly<Record<string, unknown>>[];
  readonly fetch?: typeof globalThis.fetch;
  readonly expectedKind?: string;
  readonly expectedContentType?: RegExp;
  readonly maximumAttempts?: number;
}): Promise<Readonly<Record<string, unknown>>>;

export declare function collectDiscoveryContent(result: unknown): readonly unknown[];

export declare function collectDiscoveryTargets(result: unknown): readonly string[];

export declare function runReadingSourceFlow(options: {
  readonly plugin: SourcePlugin;
  readonly contentId?: string | null;
  readonly discoverRequest?: Record<string, unknown> | null;
  readonly searchRequest?: Record<string, unknown> | null;
  readonly suggestionsRequest?: Record<string, unknown> | null;
}): Promise<Readonly<{
  detail: unknown;
  chapters: unknown;
  content: unknown;
  contents: readonly unknown[];
  summary: Readonly<Record<string, unknown>>;
}>>;

export interface SourceTestCliOptions {
  readonly all: boolean;
  readonly source: string | null;
  readonly repositoryRoot: string;
  readonly reportPath: string | null;
  readonly skipBuild: boolean;
}

export declare function parseSourceTestArguments(
  arguments_: readonly string[],
  options?: { readonly cwd?: string },
): Readonly<SourceTestCliOptions>;

export declare function discoverSourceProjects(
  repositoryRoot: string,
): Promise<readonly Readonly<Record<string, unknown>>[]>;

export declare function runSourceProjects(
  options: Readonly<SourceTestCliOptions>,
): Promise<Readonly<Record<string, unknown>>>;
