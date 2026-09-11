import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mgread.mg_read"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The Android runtime and production devices are arm64-v8a only.
        // Keeping this in defaultConfig applies it to both debug and release.
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    // The Vulkan validation layer is useful for engine debugging but is not
    // required by the application itself.
    packaging {
        jniLibs {
            // Compress native libraries to reduce direct APK download size.
            // Android extracts them during installation.
            useLegacyPackaging = true
            excludes += setOf(
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
                "**/libVkLayer_khronos_validation.so",
            )
        }
    }

    val releaseSigningPropertiesFile = rootProject.file("key.properties")
    val releaseSigningProperties = Properties()
    val releaseSigningConfig = if (releaseSigningPropertiesFile.isFile) {
        releaseSigningPropertiesFile.inputStream().use(releaseSigningProperties::load)
        fun requiredReleaseSigningProperty(name: String): String =
            releaseSigningProperties.getProperty(name)?.takeIf(String::isNotBlank)
                ?: error("Release signing property '$name' is missing in key.properties.")

        signingConfigs.create("release") {
            keyAlias = requiredReleaseSigningProperty("keyAlias")
            keyPassword = requiredReleaseSigningProperty("keyPassword")
            storeFile = file(requiredReleaseSigningProperty("storeFile"))
            storePassword = requiredReleaseSigningProperty("storePassword")
        }
    } else {
        null
    }

    if (
        releaseSigningConfig == null &&
        gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
    ) {
        error("Release builds require the ignored android/key.properties signing configuration.")
    }

    buildTypes {
        release {
            signingConfig = releaseSigningConfig ?: signingConfigs.getByName("debug")
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
