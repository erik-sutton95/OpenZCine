import java.net.URI
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// OpenZCine is intentionally arm64-only until another ABI has both a Swift
// runtime package and on-device verification. Keep the Gradle ABI and the
// Swift target in lockstep (scripts/android-stage-swift-core.sh).
val supportedAndroidAbi = "arm64-v8a"
val swiftCoreJniLibsRoot = layout.buildDirectory.dir("generated/swiftCore/jniLibs")
val swiftCoreArm64Directory = swiftCoreJniLibsRoot.map { it.dir(supportedAndroidAbi) }
val releaseApkDirectory = layout.buildDirectory.dir("outputs/apk/release")
val releaseAabDirectory = layout.buildDirectory.dir("outputs/bundle/release")
val repositoryRoot = rootProject.projectDir.parentFile.parentFile
val stageSwiftCoreScript = repositoryRoot.resolve("scripts/android-stage-swift-core.sh")
val verifyNativeLibrariesScript = repositoryRoot.resolve("scripts/verify-android-native-libs.sh")

// Frame.io uses an Adobe IMS public PKCE client. These values are not a client
// secret, but each Android redirect registration is deployment-specific, so a
// fresh clone is deliberately unconfigured. Resolve explicit Gradle properties
// first, then environment values, then the ignored local properties file.
val frameioLocalProperties =
    Properties().also { properties ->
        val localFile = rootProject.projectDir.resolve("frameio.local.properties")
        if (localFile.isFile) {
            localFile.inputStream().use(properties::load)
        }
    }
fun frameioValue(property: String, environment: String): String =
    (findProperty(property) as? String)
        ?: System.getenv(environment)
        ?: frameioLocalProperties.getProperty(property)
        ?: ""

val frameioClientID = frameioValue("frameio.clientId", "FRAMEIO_CLIENT_ID")
val frameioRedirectURI = frameioValue("frameio.redirectUri", "FRAMEIO_REDIRECT_URI")
val frameioRedirect = runCatching { URI(frameioRedirectURI) }.getOrNull()
val configuredFrameioScheme = frameioRedirect?.scheme?.takeIf { scheme ->
    scheme.matches(Regex("[A-Za-z][A-Za-z0-9+.-]*"))
}
val configuredFrameioHost = frameioRedirect?.host?.takeIf { host -> host.isNotBlank() }
// This intentionally unusable fallback lets Android compile a manifest
// without implying a registered Adobe redirect in unconfigured builds.
val frameioRedirectScheme = configuredFrameioScheme ?: "openzcine-frameio-unconfigured"
val frameioRedirectHost = configuredFrameioHost ?: "unconfigured"
fun quotedBuildConfig(value: String): String =
    "\"" +
        value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r") +
        "\""

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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        manifestPlaceholders["frameioRedirectScheme"] = frameioRedirectScheme
        manifestPlaceholders["frameioRedirectHost"] = frameioRedirectHost
        buildConfigField("String", "FRAMEIO_CLIENT_ID", quotedBuildConfig(frameioClientID))
        buildConfigField("String", "FRAMEIO_REDIRECT_URI", quotedBuildConfig(frameioRedirectURI))
        buildConfigField(
            "String",
            "FRAMEIO_REDIRECT_SCHEME",
            quotedBuildConfig(frameioRedirectScheme),
        )

        ndk {
            abiFilters += supportedAndroidAbi
        }
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

    sourceSets {
        getByName("main").jniLibs.directories.apply {
            clear()
            add(swiftCoreJniLibsRoot.get().asFile.absolutePath)
        }
    }
}

/**
 * Builds the shared Swift core and stages its full runtime closure under
 * Gradle-owned output. `src/main/jniLibs` is deliberately not an input: a
 * clean clone must never package an ignored or stale local .so set.
 */
val stageSwiftCore = tasks.register<Exec>("stageSwiftCore") {
    group = "build"
    description = "Cross-compile and stage the Swift camera core for arm64-v8a."
    workingDir = repositoryRoot
    inputs.files(
        fileTree(repositoryRoot) {
            include("Package.swift", "Package.resolved", "Sources/**")
        },
        stageSwiftCoreScript,
    )
    inputs.property("swiftExecutable", providers.environmentVariable("SWIFT_EXECUTABLE").orElse("auto"))
    inputs.property(
        "swiftAndroidSdk",
        providers.environmentVariable("SWIFT_ANDROID_SDK_ID").orElse("swift-6.3.3-RELEASE_android"),
    )
    outputs.dir(swiftCoreArm64Directory)
    commandLine(
        "bash",
        stageSwiftCoreScript.absolutePath,
        "--output",
        swiftCoreArm64Directory.get().asFile.absolutePath,
    )
}

tasks.named("preBuild").configure {
    dependsOn(stageSwiftCore)
}

// Brand resource tests compare Android derivatives with the canonical iOS
// catalog assets from the repository root, independent of Gradle's test cwd.
tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
    systemProperty("openzcine.repositoryRoot", repositoryRoot.absolutePath)
}

/**
 * Inspects the unsigned release APK and AAB without extracting either archive.
 * Every staged Swift runtime library must be present under the sole supported
 * ABI, so a future packaging regression fails before a Play upload.
 */
val verifyReleaseNativeLibraries = tasks.register<Exec>("verifyReleaseNativeLibraries") {
    group = "verification"
    description = "Verify release APK/AAB include the generated Swift core and runtime closure."
    dependsOn("assembleRelease", "bundleRelease")
    workingDir = repositoryRoot
    inputs.dir(swiftCoreArm64Directory)
    inputs.dir(releaseApkDirectory)
    inputs.dir(releaseAabDirectory)
    commandLine(
        "bash",
        verifyNativeLibrariesScript.absolutePath,
        "--staged-dir",
        swiftCoreArm64Directory.get().asFile.absolutePath,
        "--apk-dir",
        releaseApkDirectory.get().asFile.absolutePath,
        "--aab-dir",
        releaseAabDirectory.get().asFile.absolutePath,
    )
}

dependencies {
    implementation(project(":core-api"))

    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui.compose)
    // Bundled, on-device Latin OCR: the scanner must work without a Play
    // Services model download or sending the camera's Wi-Fi key off-device.
    implementation(libs.mlkit.text.recognition)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.uiautomator)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)

    debugImplementation(libs.compose.ui.test.manifest)
}
