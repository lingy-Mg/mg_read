/**
 * Android Javet 模块解析器。
 *
 * 职责：
 * - 在提取后的 Runtime 根目录中解析 Runtime 与已安装插件的 ESM 文件。
 * - 通过共享源适配器为 Javet 模块提供标准 `import.meta.url` 语义。
 * - 在进入 JNI 前记录模块与引用者；失败只记录 Java 类型，禁止格式化 Javet 异常。
 *
 * 注意：
 * - 解析范围限制在 Runtime 自有根目录，绝不向 Flutter 暴露路径。
 *
 */
package com.mgread.mgread_plugin_runtime

import android.util.Log
import com.caoccao.javet.interop.V8Runtime
import com.caoccao.javet.interop.callback.IV8ModuleResolver
import com.caoccao.javet.interop.callback.JavetBuiltInModuleResolver
import com.caoccao.javet.values.reference.IV8Module
import org.json.JSONObject
import java.io.File
import java.net.URI

internal class AndroidModuleResolver(
    private val root: File,
) : IV8ModuleResolver {
    private val builtIn = JavetBuiltInModuleResolver()

    override fun resolve(
        runtime: V8Runtime,
        moduleName: String,
        referrer: IV8Module?,
    ): IV8Module? = withAndroidModuleDiagnostics(moduleName, referrer?.resourceName, { Log.i(TAG, it) }) {
        if (moduleName.startsWith("node:")) {
            return@withAndroidModuleDiagnostics builtIn.resolve(runtime, moduleName, referrer)
        }
        val referrerFile = referrer?.resourceName?.let(::File)
        val requestedPath = when {
            moduleName.startsWith("file:") -> File(URI(moduleName))
            moduleName.startsWith("/") -> File(moduleName)
            referrerFile != null -> File(referrerFile.parentFile, moduleName)
            else -> File(root, moduleName)
        }.canonicalFile
        val candidate = resolveFile(requestedPath)
            ?: resolvePackage(moduleName, referrerFile)
            ?: return@withAndroidModuleDiagnostics null
        Log.i(TAG, "android_runtime_module_compile_started module=${androidModuleLogLabel(candidate.path)}")
        runtime.getExecutor(androidModuleSource(candidate))
            .setResourceName(candidate.path)
            .setModule(true)
            .compileV8Module()
    }

    private fun resolvePackage(moduleName: String, referrerFile: File?): File? {
        if (moduleName.startsWith(".") || moduleName.startsWith("/")) return null
        val segments = moduleName.split('/')
        val packageName = if (segments.firstOrNull() == "@" || moduleName.startsWith("@")) {
            if (segments.size < 2) return null
            "${segments[0]}/${segments[1]}"
        } else {
            segments.firstOrNull() ?: return null
        }
        val subpathStart = packageName.count { it == '/' } + 1
        val subpath = segments.drop(subpathStart).joinToString("/")
        var directory = referrerFile?.parentFile
        while (directory != null) {
            val packageRoot = File(directory, "node_modules/$packageName")
            if (packageRoot.isDirectory) {
                val packageJson = File(packageRoot, "package.json")
                val metadata = if (packageJson.isFile) {
                    runCatching { JSONObject(packageJson.readText()) }.getOrNull()
                } else {
                    null
                }
                val declaredEntry = if (subpath.isNotEmpty()) {
                    val exportTarget = metadata
                        ?.optJSONObject("exports")
                        ?.opt("./$subpath")
                        ?.let(::resolveExportTarget)
                    File(packageRoot, exportTarget ?: subpath)
                } else {
                    val moduleEntry = metadata?.optString("module")?.takeIf { it.isNotEmpty() }
                    val mainEntry = metadata?.optString("main")?.takeIf { it.isNotEmpty() }
                    File(packageRoot, moduleEntry ?: mainEntry ?: "index.js")
                }
                resolveFile(declaredEntry)?.let { return it }
                if (subpath.isEmpty()) {
                    resolveFile(File(packageRoot, "index.js"))?.let { return it }
                }
            }
            directory = directory.parentFile
        }
        Log.e(TAG, "android_runtime_module_resolve_missing")
        return null
    }

    private fun resolveExportTarget(value: Any): String? {
        if (value is String) return value
        if (value !is JSONObject) return null
        for (condition in listOf("import", "default", "node")) {
            val nested = value.opt(condition)
            if (nested != null && nested !== JSONObject.NULL) {
                resolveExportTarget(nested)?.let { return it }
            }
        }
        return null
    }

    private fun resolveFile(candidate: File): File? {
        val canonical = candidate.canonicalFile
        if (canonical.isFile) return canonical
        if (canonical.extension.isEmpty()) {
            for (extension in listOf(".js", ".mjs", ".json")) {
                val withExtension = File(canonical.path + extension)
                if (withExtension.isFile) return withExtension.canonicalFile
            }
            val index = File(canonical, "index.js")
            if (index.isFile) return index.canonicalFile
        }
        return null
    }

    private companion object {
        const val TAG = "MgReadAndroidRuntime"
    }
}

/** Never read Throwable.message/toString/stackTrace: Javet may convert V8 error objects there. */
internal fun <T> withAndroidModuleDiagnostics(
    module: String,
    referrer: String?,
    report: (String) -> Unit,
    compile: () -> T,
): T {
    val context = "module=${androidModuleLogLabel(module)} referrer=${androidModuleLogLabel(referrer ?: "<entry>")}"
    report("android_runtime_module_resolve_started $context")
    try {
        val result = compile()
        report("android_runtime_module_resolve_${if (result == null) "missing" else "complete"} $context")
        return result
    } catch (error: Throwable) {
        report("android_runtime_module_resolve_failed $context type=${error.javaClass.simpleName}")
        // Do not carry the V8 exception as a cause into another JNI callback or
        // Android's exception formatter. Native failures still retain the last
        // compile_started marker even if JNI aborts before this catch runs.
        throw AndroidRuntimeError("runtime_module_compile_failed", "Android could not compile a Runtime module.")
    }
}

internal fun androidModuleLogLabel(value: String): String =
    value.take(512).map { if (it < ' ' || it == '\u007f') '?' else it }.joinToString("")
