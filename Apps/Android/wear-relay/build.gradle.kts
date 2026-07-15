plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.opencapture.openzcine.wearrelay"
    compileSdk = 36

    defaultConfig {
        minSdk = 29

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
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

    sourceSets {
        getByName("test").resources.directories.add(
            rootProject.projectDir.parentFile.parentFile
                .resolve("Tests/OpenZCineCoreTests/Fixtures")
                .path,
        )
    }
}

dependencies {
    testImplementation(libs.kotlin.test.junit)
    // Android provides org.json at runtime. The tiny JVM-only test dependency
    // executes the exact same strict wire parser without an emulator.
    testImplementation(libs.json)
}
