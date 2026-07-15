plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val handheldVersionCode: Int =
    (findProperty("versionCode") ?: property("openzcine.versionCode")).toString().toInt()
val wearVersionCodeOffset = 1_000_000_000
val resolvedVersionCode: Int =
    findProperty("wearVersionCode")?.toString()?.toInt()
        ?: (handheldVersionCode + wearVersionCodeOffset)
val resolvedVersionName: String = property("openzcine.versionName").toString()
val maximumPlayVersionCode = 2_100_000_000
val keystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")
val releaseApkDirectory = layout.buildDirectory.dir("outputs/apk/release")
val releaseAabDirectory = layout.buildDirectory.dir("outputs/bundle/release")
val repositoryRoot = rootProject.projectDir.parentFile.parentFile
val verifyWearReleaseScript = repositoryRoot.resolve("scripts/verify-android-wear-release.sh")

require(resolvedVersionCode in 1..maximumPlayVersionCode) {
    "Wear versionCode $resolvedVersionCode is outside Google Play's supported range."
}
require(resolvedVersionCode != handheldVersionCode) {
    "The phone and Wear artifacts must use different version codes."
}

android {
    namespace = "com.opencapture.openzcine.wear"
    compileSdk = 36

    defaultConfig {
        // Data Layer peers must use the same signed application id. The
        // wearable APK is installed on a different device, so this does not
        // collide with the handheld package.
        applicationId = "com.opencapture.openzcine"
        minSdk = 29
        targetSdk = 36
        versionCode = resolvedVersionCode
        versionName = resolvedVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
            // Data Layer peers must be signed with the same certificate.
            signingConfig = signingConfigs.findByName("release")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = false
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

/**
 * Verifies the release pair as one phone-mediated Wear product. The APKs must
 * share package and signer identity while retaining form-factor-specific
 * version codes and the non-standalone Wear capability declaration.
 */
val verifyWearReleaseArtifact = tasks.register<Exec>("verifyWearReleaseArtifact") {
    group = "verification"
    description = "Verify the phone/Wear release pair, Wear AAB, capabilities, and signing parity."
    dependsOn(":app:assembleRelease", "assembleRelease", "bundleRelease")
    workingDir = repositoryRoot
    inputs.dir(project(":app").layout.buildDirectory.dir("outputs/apk/release"))
    inputs.dir(releaseApkDirectory)
    inputs.dir(releaseAabDirectory)
    inputs.file(verifyWearReleaseScript)
    commandLine(
        "bash",
        verifyWearReleaseScript.absolutePath,
        "--phone-apk-dir",
        project(":app").layout.buildDirectory.dir("outputs/apk/release").get().asFile.absolutePath,
        "--wear-apk-dir",
        releaseApkDirectory.get().asFile.absolutePath,
        "--wear-aab-dir",
        releaseAabDirectory.get().asFile.absolutePath,
        "--phone-version-code",
        handheldVersionCode.toString(),
        "--wear-version-code",
        resolvedVersionCode.toString(),
    )
}

dependencies {
    implementation(project(":wear-relay"))

    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.foundation)
    implementation(libs.compose.ui)
    implementation(libs.wear.compose.foundation)
    implementation(libs.wear.compose.material3)
    implementation(libs.play.services.wearable)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)

    debugImplementation(libs.compose.ui.test.manifest)
}
