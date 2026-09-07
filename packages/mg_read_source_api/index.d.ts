/**
 * The single source-facing declaration for the MgRead Plugin API v1 context.
 *
 * This package is type-only. Runtime owns the implementation and validation;
 * source packages must import these types instead of redeclaring projections.
 */

export type PluginJsonValue =
  | null
  | boolean
  | number
  | string
  | readonly PluginJsonValue[]
  | { readonly [key: string]: PluginJsonValue };

export type PluginJsonObject = { readonly [key: string]: PluginJsonValue };

export interface PluginWebViewCallOptions {
  readonly timeoutMs?: number;
}

export type PluginWebViewKey =
  | "Enter" | "Tab" | "Escape"
  | "ArrowUp" | "ArrowDown" | "ArrowLeft" | "ArrowRight"
  | "PageUp" | "PageDown" | "Home" | "End"
  | "Backspace" | "Delete";

export interface PluginWebViewFetchRequest {
  readonly url: string;
  readonly method?: string;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string | null;
  readonly responseType?: "text" | "json" | "base64";
  readonly timeoutMs?: number;
}

export interface PluginWebViewFetchResponse {
  readonly body: PluginJsonValue;
  readonly headers: Readonly<Record<string, string>>;
  readonly status: number;
  readonly url: string;
}

export interface PluginWebViewPage {
  navigate(url: string, options?: PluginWebViewCallOptions): Promise<void>;
  executeJavaScript<T extends PluginJsonValue = PluginJsonValue>(
    code: string,
    options?: PluginWebViewCallOptions,
  ): Promise<T>;
  /** Sends one raw CDP command; platform support is documented by Runtime. */
  cdp<T extends PluginJsonValue = PluginJsonValue>(
    method: string,
    params?: PluginJsonObject,
    options?: PluginWebViewCallOptions,
  ): Promise<T>;
  getHtml(options?: PluginWebViewCallOptions): Promise<string>;
  fetch(request: PluginWebViewFetchRequest): Promise<PluginWebViewFetchResponse>;
  click(request: { readonly x: number; readonly y: number; readonly timeoutMs?: number }): Promise<void>;
  inputText(text: string, options?: PluginWebViewCallOptions): Promise<void>;
  key(request: {
    readonly key: PluginWebViewKey;
    readonly modifiers?: readonly ("alt" | "control" | "shift")[];
    readonly timeoutMs?: number;
  }): Promise<void>;
  waitForText(request: {
    readonly text: string;
    readonly scope?: "text" | "html";
    readonly timeoutMs: number;
  }): Promise<{ readonly url: string }>;
  getUrl(options?: PluginWebViewCallOptions): Promise<string>;
  show(options?: PluginWebViewCallOptions): Promise<void>;
  hide(options?: PluginWebViewCallOptions): Promise<void>;
  close(options?: PluginWebViewCallOptions): Promise<void>;
}

export interface PluginWebViewApi {
  open(options?: { readonly visible?: boolean; readonly timeoutMs?: number }): Promise<PluginWebViewPage>;
}

export interface PluginBrowserSessionV1 {
  request(request: unknown): Promise<unknown>;
  requestCoordinates(request: unknown): Promise<unknown>;
  nativeInput(request: unknown): Promise<unknown>;
  controlClick(request: unknown): Promise<unknown>;
}

/** Stable failures that a source may intentionally surface to the host. */
export type PluginPublicErrorCode =
  | "source_access_blocked"
  | "source_media_resolution_failed";

/** Safe source-authored text shown with a stable public error code. */
export interface PluginPublicError {
  readonly annotation?: string;
  readonly code: PluginPublicErrorCode;
  readonly message: string;
}

/**
 * A bounded routing preference for one source-owned HTTP request.
 *
 * `direct` bypasses both the operating-system proxy and the Runtime's
 * configured source HTTP proxy. It never accepts a source-supplied proxy URL.
 */
export interface PluginHttpRequestInit extends RequestInit {
  readonly proxyMode?: "direct";
}

/**
 * A Runtime resource-proxy descriptor. `proxyMode` applies when Runtime
 * retrieves the upstream media bytes, including HLS playlists and segments.
 */
export type PluginResourceProxyRequest = PluginJsonObject & {
  readonly proxyMode?: "direct";
};

export interface MgReadPluginContext {
  readonly app: {
    readonly nodeVersion: string;
    readonly pluginApi: number;
    readonly runtimeVersion: string;
  };
  readonly cacheDir: string;
  readonly dataDir: string;
  readonly errors: {
    raise(error: PluginPublicError): never;
    raise(code: PluginPublicErrorCode): never;
  };
  readonly http: {
    fetch(input: string | URL, init?: PluginHttpRequestInit): Promise<Response>;
  };
  readonly browser: {
    readonly sessionV1: PluginBrowserSessionV1;
  };
  readonly webview: PluginWebViewApi;
  readonly resource: {
    proxy(request: PluginResourceProxyRequest): string;
    proxy(request: PluginJsonObject): string;
  };
  readonly log: {
    debug(event: string): void;
    error(event: string): void;
    info(event: string): void;
    warn(event: string): void;
  };
  readonly plugin: {
    readonly id: string;
    readonly version: string;
  };
}
