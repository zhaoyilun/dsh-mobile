import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release 签名只从 android/key.properties 读取;该文件与 keystore 已被
// .gitignore 排除。Release 构建不再回退到公开的 Android debug key。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "dev.zhaoyilun.dsh_mobile"
    compileSdk = flutter.compileSdkVersion
    // 固定到当前插件共同要求的 NDK 27;flutter.ndkVersion 仍是 26.3,
    // 继续使用会在每次构建时产生 NDK 版本不一致警告。
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
        applicationId = "dev.zhaoyilun.dsh_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 23:兼容 flutter_secure_storage 最新要求,且高于
        // webview_flutter 的 21 与 flutter 默认 minSdkVersion。
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 不使用 debug key。缺失 android/key.properties 时,release
            // 构建会在下面的 taskGraph 检查中给出明确错误。
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

gradle.taskGraph.whenReady {
    if (gradle.taskGraph.hasTask(":app:assembleRelease") &&
        !keystorePropertiesFile.exists()
    ) {
        throw GradleException(
            "release signing requires android/key.properties; " +
                "see android/key.properties.example",
        )
    }
}

flutter {
    source = "../.."
}
