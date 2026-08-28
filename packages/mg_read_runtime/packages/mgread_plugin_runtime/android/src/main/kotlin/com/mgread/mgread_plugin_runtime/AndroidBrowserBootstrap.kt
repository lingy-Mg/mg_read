/** Host-authored JavaScript adapter from browser.session.v1 to Javet polling. */
package com.mgread.mgread_plugin_runtime

internal fun androidBrowserProviderBootstrap(): String = """
    const browserSession = {
      async request(request) {
        const payload = JSON.stringify({
          operation: request.operation ?? 'request',
          action: request.action,
          version: request.version,
          pluginId: request.pluginId,
          sessionKey: request.sessionKey,
          url: request.url,
          selector: request.selector,
          text: request.text,
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
        const onAbort = () => globalThis.__mgreadBrowserCancel(id);
        request.signal.addEventListener('abort', onAbort, { once: true });
        const browserSessionError = (code) => {
          return {
            __mgreadBrowserSessionError: code,
          };
        };
        try {
          if (request.signal.aborted) return browserSessionError('cancelled');
          // Wait in the private host bridge rather than depending on the
          // embedded Node timer queue. The Android main thread remains free
          // for WebView callbacks and the wait is bounded by the request.
          const result = JSON.parse(globalThis.__mgreadBrowserPollWait(id, request.timeoutMs));
          if (result.state === 'pending') return browserSessionError('timeout');
          if (result.state === 'error') return browserSessionError(result.code);
          return result.response;
        } catch (error) {
          return browserSessionError('plugin_execution_failed');
        } finally {
          request.signal.removeEventListener('abort', onAbort);
        }
      },
    };
""".trimIndent()
