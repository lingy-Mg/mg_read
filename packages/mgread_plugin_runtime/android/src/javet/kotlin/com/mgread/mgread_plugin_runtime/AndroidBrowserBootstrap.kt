/** Host-authored JavaScript adapter from browser.session.v1 to Javet polling. */
package com.mgread.mgread_plugin_runtime

internal fun androidBrowserProviderBootstrap(): String = """
    const browserSession = {
      async request(request) {
        const { signal, ...serializable } = request;
        const payload = JSON.stringify(serializable);
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
          const deadline = Date.now() + request.timeoutMs;
          while (true) {
            if (request.signal.aborted) return browserSessionError('cancelled');
            const result = JSON.parse(globalThis.__mgreadBrowserPoll(id));
            if (result.state === 'error') return browserSessionError(result.code);
            if (result.state === 'done') return result.response;
            if (Date.now() >= deadline) return browserSessionError('timeout');
            await new Promise(resolve => setTimeout(resolve, 25));
          }
        } catch (error) {
          return browserSessionError('plugin_execution_failed');
        } finally {
          request.signal.removeEventListener('abort', onAbort);
        }
      },
    };
""".trimIndent()
