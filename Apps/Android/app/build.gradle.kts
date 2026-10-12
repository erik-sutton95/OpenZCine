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
// Local-only demo clips (gitignored `samples/`). Staged into debug assets so
// `zc.demo.feed` can play real footage without committing media.
val samplesDirectory = repositoryRoot.resolve("samples")
// Concrete path (not a Provider) so the Android SourceSet API accepts it as a
// generated assets root without android.sourceset.disallowProvider overrides.
val stagedDemoAssetsDirectory =
    layout.buildDirectory.get().asFile.resolve("generated/demoAssets")

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
    compileSdk = libs.versions.androidCompileSdk.get().toInt()

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
        // Empty unless a build supplies one (below); without a DSN no report can be sent.
        buildConfigField("String", "SENTRY_DSN_ANDROID", "\"\"")
        buildConfigField("String", "SOURCE_REVISION", "\"unknown\"")
        // Play CI sets it before bundleRelease and uploads the R8 mapping under the same UUID
        // (OpenCine scripts/sentry); the adapter's manifest binds it to io.sentry.proguard-uuid.
        manifestPlaceholders["sentryProguardUuid"] = System.getenv("SENTRY_PROGUARD_UUID").orEmpty()

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
        // Debug-only: generated assets under build/generated/demoAssets/demo/
        // (copied from repo-root samples/ when present).
        getByName("debug").assets.srcDir(stagedDemoAssetsDirectory)
    }
}

/**
 * Copies gitignored checkout samples into the debug asset tree when present.
 * Missing or empty samples/ is fine — the demo harness falls back to colour
 * bars. Never stages into src/ so media cannot be committed by accident.
 */
val stageDebugDemoSamples =
    tasks.register<Copy>("stageDebugDemoSamples") {
        group = "build"
        description = "Stage local samples video clips into debug demo assets when present."
        val samplesRoot = samplesDirectory
        val destDir = File(stagedDemoAssetsDirectory, "demo")
        from(samplesRoot) {
            include("*.mp4", "*.MP4", "*.mov", "*.MOV", "*.m4v", "*.M4V")
        }
        into(destDir)
        onlyIf {
            samplesRoot.isDirectory &&
                samplesRoot.listFiles()?.any { file ->
                    file.isFile &&
                        file.extension.lowercase() in setOf("mp4", "mov", "m4v")
                } == true
        }
        // Always re-check samples/ so a newly dropped clip is picked up.
        outputs.upToDateWhen { false }
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
        // The root Package.swift takes these from the sibling OpenCine checkout: OpenCineMedia
        // (and OpenCineCore, which it depends on), OpenCineFrameIO (the Frame.io facade),
        // OpenCineNikon (PTP wire, properties, session policy; OpenZCineCore re-exports it),
        // OpenCineNikonAndroid (the PTP-IP / USB session layer and NikonNative's JNI exports)
        // and OpenCineJNISupport (+ the OpenCineJNI header), so a package edit must restage the core.
        fileTree(repositoryRoot.resolve("../OpenCine")) {
            include(
                "Package.swift",
                "Sources/OpenCineMedia/**",
                "Sources/OpenCineCore/**",
                "Sources/OpenCineFrameIO/**",
                "Sources/OpenCineNikon/**",
                "Sources/OpenCineNikonAndroid/**",
                "Sources/OpenCineJNISupport/**",
                "Sources/OpenCineJNI/**",
                "scripts/android-stage-swift-core.sh",
            )
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
    // Stage local demo clips before any debug asset/lint task reads the
    // generated assets directory (implicit-dependency hygiene).
    dependsOn(stageDebugDemoSamples)
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
    // OpenCine common camera contracts (CORE-02 candidate, composite build; see settings).
    implementation(libs.opencine.core)
    // Shared Compose monitor UI and the multicam engine from the same OpenCine build.
    implementation(libs.opencine.monitor.ui)
    implementation(libs.opencine.multicam)
    // The Nikon session (PTP-IP / USB PTP over the Swift layer), its contract and NikonNative.
    implementation(libs.opencine.nikon)
    // The shared cameras page, connection model and saved-camera document (SHELL-02).
    implementation(libs.opencine.appkit)
    // The shared capture sheets (LadderSheet) over the camera vocabulary.
    implementation(libs.opencine.camera.controls)
    // Shared prepared PCM sampling and decoded-audio source lifetime.
    implementation(libs.opencine.native.runtime)
    // Shared Vulkan renderer: the Bitmap probe and its legacy OpcVulkan JNI class.
    implementation(libs.opencine.vulkan)
    // Keystore sealing for the camera Wi-Fi keys.
    implementation(libs.opencine.platform)
    implementation(project(":wear-relay"))
    // Shared transport owners; hardware camera sessions stay in the Nikon integration.
    implementation("com.opencapture.opencine:relay:0.1.0-SNAPSHOT")
    implementation("com.opencapture.opencine:relay-runtime:0.1.0-SNAPSHOT")
    implementation("com.opencapture.opencine:watch-runtime:0.1.0-SNAPSHOT")
    implementation("com.opencapture.opencine:nikon-wire:0.1.0-SNAPSHOT")
    // The shared reporting adapter: appkit's reporting sink, transport and problem report upload on
    // the Sentry SDK (sentry-android comes with it, at the version OpenCine pins).
    implementation("com.opencapture.opencine:appkit-sentry:0.1.0-SNAPSHOT")

    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.compose.material3)
    // Playback transport SF-symbol stand-ins (play/pause/share/volume/star).
    implementation(libs.compose.material.icons.extended)
    // Liquid glass: Kyant0/AndroidLiquidGlass layer-backdrop + AGSL lens path.
    implementation(libs.kyant.backdrop)
    // Runtime of backdrop, pinned here.
    implementation(libs.kyant.shapes)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.media3.effect)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui)
    implementation(libs.media3.transformer)
    // The phone relay is a foreground-only Data Layer endpoint. It carries
    // preview/state messages to a same-signed Wear OS companion; it never
    // opens a camera transport or routes a command directly to Nikon.
    implementation(libs.play.services.wearable)
    // Bundled, on-device Latin OCR: the scanner must work without a Play
    // Services model download or sending the camera's Wi-Fi key off-device.
    implementation(libs.mlkit.text.recognition)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.json)
    testImplementation(libs.kotlinx.coroutines.test)

    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.uiautomator)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    // Retired donor renderer for exact Vulkan pixel parity; test APK only.
    androidTestImplementation(project(":frozen-vulkan-donor"))

    debugImplementation(libs.compose.ui.test.manifest)
}

// Non-empty SENTRY_DSN_ANDROID wins; otherwise optional ignored repo-root properties (as Pocket).
val sentryDsnAndroidField =
    providers.environmentVariable("SENTRY_DSN_ANDROID")
        .orElse("")
        .zip(
            providers.of(LocalReliabilityDsnValueSource::class.java) {
                parameters.propertiesFile.set(repositoryRoot.resolve(".local/reliability.properties"))
            },
        ) { env, file ->
            val raw = env.trim().ifEmpty { file.trim() }
            val escaped = raw.replace("\\", "\\\\").replace("\"", "\\\"")
            com.android.build.api.variant.BuildConfigField("String", "\"$escaped\"", "optional Sentry Android DSN")
        }

// The commit this build came from (+ when the checkout is dirty), as Pocket and Insta stamp it.
val sourceRevisionField =
    providers.exec {
        workingDir = repositoryRoot
        commandLine("git", "rev-parse", "--short=12", "HEAD")
        isIgnoreExitValue = true
    }.standardOutput.asText
        .zip(
            providers.exec {
                workingDir = repositoryRoot
                commandLine("git", "status", "--porcelain")
                isIgnoreExitValue = true
            }.standardOutput.asText,
        ) { rev, status ->
            val cleaned =
                (System.getenv("GITHUB_SHA")?.take(12) ?: rev.trim())
                    .filter { it.isLetterOrDigit() || it == '.' || it == '-' || it == '_' }
                    .ifEmpty { "unknown" }
            val value = if (status.isNotBlank()) "$cleaned+" else cleaned
            com.android.build.api.variant.BuildConfigField("String", "\"$value\"", "git source revision")
        }

// Windows CPython installs put `python` on PATH and no `python3`. `PYTHON` overrides both.
val pythonExecutable: Provider<String> =
    providers.environmentVariable("PYTHON").orElse(
        providers.systemProperty("os.name").map { osName ->
            if (osName.startsWith("Windows", ignoreCase = true)) "python" else "python3"
        }
    )

androidComponents {
    onVariants { variant ->
        variant.buildConfigFields?.put("SENTRY_DSN_ANDROID", sentryDsnAndroidField)
        variant.buildConfigFields?.put("SOURCE_REVISION", sourceRevisionField)
        // Content identity of the build inputs this app lists in tools/build-identity.json (OpenCine
        // scripts/sentry). Exec output participates in configuration-cache validation.
        val identity = providers.exec {
            workingDir = repositoryRoot
            commandLine(
                pythonExecutable.get(),
                repositoryRoot.resolve("../OpenCine/scripts/sentry/build-identity.py").absolutePath,
                "--root", repositoryRoot.absolutePath, "--platform", "android", "--configuration",
                "${variant.name}-$resolvedVersionName-$resolvedVersionCode-${gradle.gradleVersion}",
            )
        }.standardOutput.asText.map { value ->
            com.android.build.api.variant.BuildConfigField(
                "String", "\"${value.trim()}\"", "content identity of build inputs",
            )
        }
        variant.buildConfigFields?.put("BUILD_IDENTITY", identity)
    }
}

abstract class LocalReliabilityDsnValueSource :
    ValueSource<String, LocalReliabilityDsnValueSource.Params> {
    interface Params : ValueSourceParameters {
        @get:org.gradle.api.tasks.Optional
        @get:InputFile
        @get:PathSensitive(PathSensitivity.NONE)
        val propertiesFile: RegularFileProperty
    }

    override fun obtain(): String {
        val file = parameters.propertiesFile.orNull?.asFile ?: return ""
        if (!file.isFile) return ""
        val props = Properties()
        file.inputStream().use { props.load(it) }
        return props.getProperty("SENTRY_DSN_ANDROID")?.trim().orEmpty()
    }
}
