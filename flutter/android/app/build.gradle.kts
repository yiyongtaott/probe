import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.probe_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.probe_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 22
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Flutter 把每个 --dart-define=K=V 以 base64(UTF-8) 形式随 "dart-defines" 属性传入 Gradle。
        // 原生端（如 ProbeDeviceState 的息屏上报 backstop）需要与 Dart 上报同一 device id，
        // 这里解码 device=xxx 生成 BuildConfig.DEVICE_ID（无定义时默认 "phone"，行为与旧版一致）。
        val dartDefines = (project.findProperty("dart-defines") as? String)
            ?.split(",")
            ?.mapNotNull { entry ->
                runCatching { String(Base64.getDecoder().decode(entry), Charsets.UTF_8) }.getOrNull()
            }
            .orEmpty()
        val nativeDeviceId = dartDefines
            .firstOrNull { it.startsWith("device=") }
            ?.substringAfter("device=")
            ?: "phone"
        buildConfigField("String", "DEVICE_ID", "\"${nativeDeviceId.replace("\\", "\\\\").replace("\"", "\\\"")}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
