/** Binary source ABI v1; host capabilities remain the public Source API. */
import type { MgReadPluginContext, PluginJsonValue } from '@mgread/source-api';
export interface WasmSource {
  activate(context: MgReadPluginContext): Promise<void>;
  deactivate(): Promise<void>;
  discover(request: PluginJsonValue): Promise<PluginJsonValue>;
  search(request: PluginJsonValue): Promise<PluginJsonValue>;
  searchSuggestions(request: PluginJsonValue): Promise<PluginJsonValue>;
  getDetail(request: PluginJsonValue): Promise<PluginJsonValue>;
  getChapters(request: PluginJsonValue): Promise<PluginJsonValue>;
  getContent(request: PluginJsonValue): Promise<PluginJsonValue>;
}
export function createWasmSource(binary: Uint8Array): WasmSource;
