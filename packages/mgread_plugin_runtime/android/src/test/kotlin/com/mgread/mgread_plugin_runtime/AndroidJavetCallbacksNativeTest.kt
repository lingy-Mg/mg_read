package com.mgread.mgread_plugin_runtime

import com.caoccao.javet.enums.V8AwaitMode
import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.V8Host
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8ValueFunction
import com.caoccao.javet.values.reference.V8Module
import java.net.Socket
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Optional actual desktop Javet check. The local Gradle init script supplies
 * the exact 6.0.1 native JAR; normal Android unit tests need no desktop library.
 * TCP only substitutes for Android's wake pipe in this non-device test.
 */
class AndroidJavetCallbacksNativeTest {
    @Test fun realNodeLoopWakesAndFastReplyOvertakesPendingIo() {
        assumeTrue(System.getProperty("mgread.javet.nativeTest") == "true")
        val port = AtomicInteger()
        val bound = CountDownLatch(1)
        val finished = CountDownLatch(4)
        val closed = CountDownLatch(1)
        val failure = AtomicReference<String>()
        val connection = AtomicReference<Socket>()
        val results = Collections.synchronizedList(mutableListOf<String>())
        val loop = AndroidRuntimeEventLoop { failure.set("event-loop"); bound.countDown(); finished.countDown() }
        var vm: NodeRuntime? = null
        var observer: AndroidJavetCallbacks? = null
        var readyFunction: V8ValueFunction? = null
        var module: V8Module? = null
        loop.post {
            try {
                val runtime = V8Host.getNodeInstance().createV8Runtime<NodeRuntime>()
                vm = runtime
                observer = AndroidJavetCallbacks(runtime, loop::post)
                val context = JavetCallbackContext("__testPort", JavetCallbackType.DirectCallNoThisAndNoResult,
                    object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                        override fun call(vararg values: V8Value) { port.set(values[0].toString().toInt()); bound.countDown() }
                    })
                readyFunction = runtime.createV8ValueFunction(context)
                runtime.getGlobalObject().set("__testPort", readyFunction)
                runtime.getExecutor("""
                    globalThis.peers=[];
                    globalThis.server=require('node:net').createServer(socket => {
                      peers.push(socket); socket.on('data', () => {}); socket.write('R');
                    }).listen(0,'127.0.0.1',()=>__testPort(server.address().port));
                """.trimIndent()).executeVoid()
                loop.setDriver({ block ->
                    runtime.await(V8AwaitMode.RunNoWait)
                    if (block && !loop.hasCommands()) runtime.await(V8AwaitMode.RunOnce)
                }, { connection.get()?.getOutputStream()?.write(1) })
            } catch (error: Throwable) { failure.set(error.javaClass.simpleName); bound.countDown() }
        }
        try {
            assertTrue(bound.await(10, TimeUnit.SECONDS))
            assertNull(failure.get())
            val socket = Socket("127.0.0.1", port.get())
            connection.set(socket)
            socket.soTimeout = 5000
            assertEquals('R'.code, socket.getInputStream().read())
            loop.post {
                try {
                    observer!!.observe(vm!!.getExecutor("new Promise(resolve => setTimeout(() => resolve('slow'), 250))").execute<V8Value>()) { ok, result ->
                        if (!ok) failure.set("slow-rejected")
                        results += result.orEmpty(); finished.countDown()
                    }
                } catch (error: Throwable) { failure.set(error.javaClass.simpleName); finished.countDown() }
            }
            loop.post {
                try {
                    observer!!.observe(vm!!.getExecutor("Promise.resolve('fast')").execute<V8Value>()) { ok, result ->
                        if (!ok) failure.set("fast-rejected")
                        results += result.orEmpty(); finished.countDown()
                    }
                    observer!!.observe(vm!!.getExecutor("Promise.reject(new Error('private exception'))").execute<V8Value>()) { ok, result ->
                        if (ok || result != null) failure.set("rejection-not-sanitized")
                        finished.countDown()
                    }
                    val forgotten = observer!!.observe(vm!!.getExecutor("Promise.resolve('expired')").execute<V8Value>()) { _, _ ->
                        failure.set("expired-callback-delivered")
                    }
                    observer!!.forget(forgotten)
                    val compiled = vm!!.getExecutor("await new Promise(resolve=>setTimeout(resolve,10)); export const value='module';")
                        .setResourceName("async-host-module.mjs").setModule(true).compileV8Module()
                    module = compiled
                    check(compiled.instantiate())
                    vm!!.createV8ValueObject().use { loaded ->
                        compiled.namespace.use { loaded.set("namespace", it) }
                        compiled.evaluate<V8Value>().use { loaded.set("evaluation", it) }
                        vm!!.getGlobalObject().set("loaded", loaded)
                    }
                    observer!!.observe(vm!!.getExecutor("(async()=>{ await loaded.evaluation; return loaded.namespace.value; })()").execute<V8Value>()) { ok, result ->
                        if (!ok || result != "module") failure.set("async-module-evaluation-failed")
                        finished.countDown()
                    }
                } catch (error: Throwable) { failure.set(error.javaClass.simpleName); finished.countDown() }
            }
            assertTrue(finished.await(10, TimeUnit.SECONDS))
            assertNull(failure.get())
            assertEquals(listOf("fast", "slow"), results.toList())
        } finally {
            loop.post {
                try {
                    loop.setDriver(null)
                    observer?.close()
                    vm?.getExecutor("peers.forEach(socket=>socket.destroy()); server.close();")?.executeVoid()
                    readyFunction?.close()
                    module?.close()
                    vm?.setStopping(true)
                    vm?.close()
                } catch (error: Throwable) { failure.set(error.javaClass.simpleName) }
                finally { loop.shutdown(); closed.countDown() }
            }
            assertTrue(closed.await(10, TimeUnit.SECONDS))
            connection.get()?.close()
        }
        assertNull(failure.get())
    }
}
