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
          const poll = () => {
            if (settled) return;
            if (request.signal.aborted) { abort(); return; }
            try {
              const result = JSON.parse(globalThis.__mgreadBrowserPoll(id));
              if (result.state === 'pending') { setTimeout(poll, 25); return; }
              if (result.state === 'error') { fail(result.code); return; }
              settled = true;
              cleanup();
              resolve(result.response);
            } catch (_) {
              fail('plugin_execution_failed');
            }
          };
          request.signal.addEventListener('abort', abort, { once: true });
          poll();
        });
      },
    };
""".trimIndent()
