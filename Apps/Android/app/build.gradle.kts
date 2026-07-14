plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// Single version source: gradle.properties (mirrors ios/Config/Version.xcconfig).
// CI overrides the code per build with `-PversionCode=<n>`; the name changes only
// through a reviewed edit to gradle.properties. See docs/android-distribution.md.
val resolvedVersionCode: Int =
    (findProperty("versionCode") ?: property("openzcine.versionCode")).toString().toInt()
val resolvedVersionName: String = property("openzcine.versionName").toString()

// Release signing comes STRICTLY from environment variables so no keystore or
// password can ever land in the repo. When they are unset, release builds stay
// buildable but UNSIGNED (structure checks, `bundleRelease` locally); CI decodes
// the keystore secret and exports these before building.
val keystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")

android {
    namespace = "com.opencapture.openzcine"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.opencapture.openzcine"
        // 29 (Android 10): first release with WifiNetworkSpecifier, which the
        // camera-AP Wi-Fi join flow needs; anything older cannot pair anyway.
        minSdk = 29
        targetSdk = 36
        versionCode = resolvedVersionCode
        versionName = resolvedVersionName
    }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Null (unsigned) when ANDROID_KEYSTORE_PATH is unset; never blocks debug.
            signingConfig = signingConfigs.findByName("release")
        }
    }

    buildFeatures {
        compose = true
        // BuildConfig.DEBUG gates the feed pacing logs and the Swift-core smoke check.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

dependencies {
    implementation(project(":core-api"))

    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui.compose)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
