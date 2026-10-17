// Pure-JVM monitor and relay types (monitor data availability, relay control lease, relay
// encoder profile). No Android dependencies allowed in this module. The camera session contract
// that used to live here moved to OpenCine's `com.opencapture.opencine:nikon` (SHELL-04).
plugins {
    alias(libs.plugins.kotlin.jvm)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    // Public API surface must be deliberate — this module IS the seam.
    explicitApi()
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    api("com.opencapture.opencine:core:0.1.0-SNAPSHOT")
    api("com.opencapture.opencine:relay:0.1.0-SNAPSHOT")
    api(libs.kotlinx.coroutines.core)

    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
}
