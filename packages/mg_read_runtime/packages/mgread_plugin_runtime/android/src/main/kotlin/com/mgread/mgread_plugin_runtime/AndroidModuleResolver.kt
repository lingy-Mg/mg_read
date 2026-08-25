/**
 * Android Javet 模块解析器。
 *
 * 职责：
 * - 在提取后的 Runtime 根目录中解析 Runtime 与已安装插件的 ESM 文件。
 * - 将 Cheerio 唯一的 CommonJS 叶子适配为 Javet ESM 加载器可执行的模块。
 *
 * 注意：
 * - 解析范围限制在 Runtime 自有根目录，绝不向 Flutter 暴露路径。
 *
 * TODO:
 * - 无。
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
    ): IV8Module? {
        if (moduleName.startsWith("node:")) {
            return builtIn.resolve(runtime, moduleName, referrer)
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
            ?: return null
        return runtime.getExecutor(moduleSource(candidate))
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

    /** boolbase is the lone CommonJS leaf in Cheerio's ESM dependency graph. */
    private fun moduleSource(candidate: File): String {
        if (!candidate.path.replace(File.separatorChar, '/').endsWith("/node_modules/boolbase/index.js")) {
            return candidate.readText()
        }
        return """
            const module = { exports: {} };
            const exports = module.exports;
            ${candidate.readText()}
            export default module.exports;
        """.trimIndent()
    }

    private companion object {
        const val TAG = "MgReadAndroidRuntime"
    }
}
