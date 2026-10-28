/** VM-local Core bootstrap. Core is published before activation so failed starts can be stopped. */
package com.mgread.mgread_plugin_runtime

import java.io.File
import org.json.JSONObject

internal fun androidJavetCoreBootstrap(dataRoot: File, pluginImportInbox: File): String {
        val browserProvider = androidBrowserProviderBootstrap()
        return """
            (async () => {
              const { DesktopRuntime, PluginBrowserSessionError } = globalThis.__mgreadDesktopRuntime;
              $browserProvider
              globalThis.__mgreadStartCoreJson = async () => {
                const core = new DesktopRuntime({
                  browserSession,
                  dataRoot: ${JSONObject.quote(dataRoot.path)},
                  pluginImportInboxRoot: ${JSONObject.quote(pluginImportInbox.path)},
                  embedded: true,
                  // The inspector is available in release builds too, but
                  // DesktopRuntime keeps its listener disabled by default
                  // until the user explicitly enables the Runtime setting.
                  debugHttpAllowed: true,
                  onProgress: (progress) => {
                    try {
                      globalThis.__mgreadReportProgress(JSON.stringify(progress));
                    } catch (_) {
                      // Progress is observational and must not change Runtime results.
                    }
                  },
                });
                globalThis.__mgreadCore = core;
                await core.start();
                const hello = await core.invokeEmbedded('runtime.hello', {});
                if (!hello.ok) throw new Error('runtime_hello_failed');
                return JSON.stringify({ ok: true });
              };
              const embeddedInvocations = new Map();
              globalThis.__mgreadInvokeJson = async (requestId, method, paramsJson, deadline) => {
                const cancellation = new AbortController();
                embeddedInvocations.set(requestId, cancellation);
                try {
                  return JSON.stringify(await globalThis.__mgreadCore.invokeEmbedded(method, JSON.parse(paramsJson), deadline, cancellation.signal));
                } catch (_) {
                  return JSON.stringify({ ok: false, error: { code: 'internal', message: 'Android Runtime invocation failed.' } });
                } finally {
                  embeddedInvocations.delete(requestId);
                }
              };
              globalThis.__mgreadCancelJson = (requestId) => {
                const cancellation = embeddedInvocations.get(requestId);
                if (!cancellation) return false;
                cancellation.abort();
                return true;
              };
              globalThis.__mgreadStopJson = async () => {
                const core = globalThis.__mgreadCore;
                if (core) await core.stop();
                globalThis.__mgreadCore = undefined;
                return JSON.stringify({ ok: true });
              };
              return globalThis.__mgreadStartCoreJson();
            })()
        """.trimIndent()
}
