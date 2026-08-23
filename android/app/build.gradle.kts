plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
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

    buildTypes {
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
