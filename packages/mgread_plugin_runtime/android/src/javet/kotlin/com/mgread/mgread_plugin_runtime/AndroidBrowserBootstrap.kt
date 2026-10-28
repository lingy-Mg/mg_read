/** Host-authored browser.session.v1 adapter using a callback-resolved Promise. */
package com.mgread.mgread_plugin_runtime

internal fun androidBrowserProviderBootstrap(): String = """
    const browserSession = {
      async request(request) {
        const { signal, ...serializable } = request;
        const payload = JSON.stringify(serializable);
        const {id, promise} = globalThis.__mgreadBrowserRequest(payload);
        const onAbort = () => globalThis.__mgreadBrowserCancel(id);
        request.signal.addEventListener('abort', onAbort, { once: true });
        const browserSessionError = (code) => {
          return {
            __mgreadBrowserSessionError: code,
          };
        };
        try {
          if (request.signal.aborted) { onAbort(); return browserSessionError('cancelled'); }
          const result = JSON.parse(await promise);
          if (request.signal.aborted) return browserSessionError('cancelled');
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
