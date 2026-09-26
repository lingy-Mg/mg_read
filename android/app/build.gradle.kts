import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val isReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
val isNativeRuntimeBuild = (findProperty("dart-defines") as? String)
    ?.split(',')
    ?.any { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) ==
                "MGREAD_NATIVE_RUNTIME=true"
        }.getOrDefault(false)
    } == true
val isAndroidNodeProcessBuild = (findProperty("dart-defines") as? String)
    ?.split(',')
    ?.any { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) ==
                "MGREAD_ANDROID_NODE_PROCESS=true"
        }.getOrDefault(false)
    } == true
val isNodeOnlyRuntimeBuild = (findProperty("dart-defines") as? String)
    ?.split(',')
    ?.any { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) ==
                "MGREAD_NODE_ONLY=true"
        }.getOrDefault(false)
    } == true

check(!(isNativeRuntimeBuild && isAndroidNodeProcessBuild)) {
    "MGREAD_NATIVE_RUNTIME and MGREAD_ANDROID_NODE_PROCESS select incompatible Android Runtime backends."
}
check(!(isNativeRuntimeBuild && isNodeOnlyRuntimeBuild)) {
    "Native-only and Node-only Android Runtime builds cannot be selected together."
}

val androidApplicationIdSuffix = (findProperty("dart-defines") as? String)
    ?.split(',')
    ?.mapNotNull { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
    }
    ?.firstOrNull { it.startsWith("MGREAD_APPLICATION_ID_SUFFIX=") }
    ?.substringAfter('=')
    ?.takeIf { it.matches(Regex("[A-Za-z][A-Za-z0-9_]*")) }

val androidApplicationId = buildString {
    append("com.mgread.mg_read")
    if (androidApplicationIdSuffix != null) {
        append('.')
        append(androidApplicationIdSuffix)
    }
}

android {
    namespace = "com.mgread.mg_read"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // CI may append a unique install suffix so automated builds can coexist.
        applicationId = androidApplicationId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The Runtime Android library exposes dedicated and combined variants.
        // Normal builds include both engines.
        missingDimensionStrategy(
            "mgreadRuntimeBackend",
            if (isNativeRuntimeBuild) "nativeRuntime" else if (isNodeOnlyRuntimeBuild) "javet" else "hybrid",
        )

        // The combined production runtime ships both Android ABIs so Javet and
        // Rust sources can run together on x86_64 emulators and arm64 devices.
        ndk {
            abiFilters.add("arm64-v8a")
            if (isNativeRuntimeBuild || !isNodeOnlyRuntimeBuild) abiFilters.add("x86_64")
        }
    }

    // The Vulkan validation layer is useful for engine debugging but is not
    // required by the application itself.
    packaging {
        jniLibs {
            // Compress native libraries to reduce direct APK download size.
            // Android extracts them during installation.
            useLegacyPackaging = true
            excludes += buildSet {
                add("**/armeabi-v7a/**")
                add("**/x86/**")
                if ((isReleaseBuild && isNodeOnlyRuntimeBuild) || isAndroidNodeProcessBuild) add("**/x86_64/**")
                if (!isAndroidNodeProcessBuild) {
                    add("**/libnode.so")
                    add("**/libmgread_node_bridge.so")
                }
                if (isNativeRuntimeBuild) {
                    add("**/libnode.so")
                    add("**/libmgread_node_bridge.so")
                    add("**/libjavet*.so")
                }
                add("**/libVkLayer_khronos_validation.so")
            }
        }
    }

    buildTypes {
        debug {
            // Keep the x86_64 emulator available to exercise both source engines.
            ndk {
                abiFilters.add("x86_64")
            }
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// The Runtime facade declares desktop assets for Windows builds. Flutter's
// asset bundle is shared across platforms, so remove the Windows-only subtree
// while copying Flutter assets into Android variants.
tasks.withType<org.gradle.api.tasks.Copy>().configureEach {
    if (name.startsWith("copyFlutterAssets")) {
        exclude(
            "flutter_assets/packages/mgread_plugin_runtime/assets/runtime/windows-x64/**",
        )
        if (isNativeRuntimeBuild) {
            exclude("flutter_assets/packages/mgread_plugin_runtime/assets/runtime/**")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Flutter writes one shared registrant into src/main for every build mode.
// A concurrent debug/integration command can therefore leave the dev-only
// integration_test plugin in that file after the release plugin list was
// prepared. Release does not carry integration_test on its Java classpath, so
// sanitize only that generated block immediately before release compilation.
val integrationTestRegistrantBlock = Regex(
    """(?m)^    try \{\R      flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\R    \} catch \(Exception e\) \{\R      Log\.e\(TAG, "Error registering plugin integration_test, dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin", e\);\R    \}\R""",
)

tasks.matching { it.name == "compileReleaseJavaWithJavac" }.configureEach {
    doFirst {
        val registrant = layout.projectDirectory
            .file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            .asFile
        if (!registrant.isFile) return@doFirst

        val generatedSource = registrant.readText()
        if ("dev.flutter.plugins.integration_test.IntegrationTestPlugin" !in generatedSource) {
            return@doFirst
        }
        val releaseSource = generatedSource.replace(integrationTestRegistrantBlock, "")
        check(releaseSource != generatedSource) {
            "Flutter generated an unsupported integration_test registration shape for release."
        }
        registrant.writeText(releaseSource)
        logger.lifecycle("Removed dev-only integration_test from the release plugin registrant.")
    }
}
