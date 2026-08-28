/** Host-authored JavaScript adapter from browser.session.v1 to Javet polling. */
package com.mgread.mgread_plugin_runtime

internal fun androidBrowserProviderBootstrap(): String = """
    const browserSession = {
      request(request) {
        const payload = JSON.stringify({
          version: request.version,
          pluginId: request.pluginId,
          sessionKey: request.sessionKey,
          url: request.url,
          method: request.method,
          headers: request.headers,
          body: request.body,
          interaction: request.interaction,
          presentation: request.presentation,
          transport: request.transport,
          timeoutMs: request.timeoutMs,
          maxResponseBytes: request.maxResponseBytes,
        });
        const id = globalThis.__mgreadBrowserStart(payload);
        return new Promise((resolve, reject) => {
          let settled = false;
          const cleanup = () => request.signal.removeEventListener('abort', abort);
          const fail = (code) => {
            if (settled) return;
            settled = true;
            cleanup();
            reject(new PluginBrowserSessionError(code));
          };
          const abort = () => {
            globalThis.__mgreadBrowserCancel(id);
            fail('cancelled');
          };
          request.signal.addEventListener('abort', abort, { once: true });
          try {
            // Keep polling in this Javet call rather than depending on the
            // embedded Node timer queue. The host wait is bounded and the
            // Android main thread remains free for WebView callbacks.
            while (!settled) {
              if (request.signal.aborted) { abort(); break; }
              const result = JSON.parse(globalThis.__mgreadBrowserPollWait(id, 250));
              if (result.state === 'pending') continue;
              if (result.state === 'error') { fail(result.code); break; }
              settled = true;
              cleanup();
              resolve(result.response);
            }
          } catch (_) {
            fail('plugin_execution_failed');
          }
        });
      },
    };
""".trimIndent()
