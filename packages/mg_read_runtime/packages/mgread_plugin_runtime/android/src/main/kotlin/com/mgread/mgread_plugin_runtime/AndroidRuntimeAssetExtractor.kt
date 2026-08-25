/**
 * Android Runtime asset extractor.
 *
 * 职责：
 * - 将不可变的内置 Runtime 镜像到带版本标记的私有目录。
 * - 向 Runtime Host 报告有界的提取进度。
 *
 * 注意：
 * - 只管理 Runtime 资产，不读取或管理用户 Runtime 数据。
 *
 * TODO:
 * - 无。
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import java.io.File
import java.io.FileOutputStream

internal class AndroidRuntimeAssetExtractor(
    private val context: Context,
    private val assetRoot: String,
    private val onProgress: (AndroidRuntimeProgress) -> Unit,
) {
    fun ensure(root: File) {
        val bundledVersion = context.assets.open("$assetRoot/runtime-version.txt")
            .bufferedReader()
            .use { it.readText().trim() }
        check(bundledVersion.isNotEmpty()) { "Android Runtime asset version is missing." }
        val marker = File(root, ".runtime-asset-version")
        if (marker.isFile && marker.readText().trim() == bundledVersion) {
            Log.i(TAG, "android_runtime_assets_reused")
            onProgress(AndroidRuntimeProgress(1, "assets_reused", 1))
            return
        }

        Log.i(TAG, "android_runtime_assets_replace_start")
        if (root.exists() && !root.deleteRecursively()) {
            throw IllegalStateException("Android Runtime asset directory cannot be replaced.")
        }
        check(root.mkdirs() || root.isDirectory) { "Android Runtime asset directory is unavailable." }
        val totalBytes = measureAssetBytes(assetRoot)
        var copiedBytes = 0L
        onProgress(AndroidRuntimeProgress(0, "assets_copying", totalBytes))
        copyAssets(assetRoot, root) { copied ->
            copiedBytes += copied
            onProgress(AndroidRuntimeProgress(copiedBytes, "assets_copying", totalBytes))
        }
        val temporaryMarker = File(root, ".runtime-asset-version.next")
        temporaryMarker.writeText("$bundledVersion\n")
        check(temporaryMarker.renameTo(marker)) { "Android Runtime asset version cannot be committed." }
        Log.i(TAG, "android_runtime_assets_replace_complete")
        onProgress(AndroidRuntimeProgress(totalBytes, "assets_copied", totalBytes))
    }

    private fun copyAssets(
        assetPath: String,
        target: File,
        progress: ((Long) -> Unit)? = null,
    ) {
        val manager: AssetManager = context.assets
        val children = manager.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            manager.open(assetPath).use { input ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        progress?.invoke(read.toLong())
                    }
                }
            }
            return
        }
        target.mkdirs()
        for (child in children) {
            copyAssets("$assetPath/$child", File(target, child), progress)
        }
    }

    private fun measureAssetBytes(assetPath: String): Long {
        val manager: AssetManager = context.assets
        val children = manager.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            return manager.open(assetPath).use { it.available().toLong() }
        }
        return children.sumOf { child -> measureAssetBytes("$assetPath/$child") }
    }

    private companion object {
        const val TAG = "MgReadAndroidRuntime"
    }
}
