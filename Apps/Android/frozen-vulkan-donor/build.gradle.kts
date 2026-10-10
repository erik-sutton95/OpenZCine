// SIMULATED parity fixture, androidTest only: the retired Nikon Vulkan live-feed renderer, frozen
// byte-exact from its last app commit (renderer, header, SPIR-V; JNI symbols renamed to
// FrozenNikonVulkanLiveFeedNative). Never a dependency of a shipping variant.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.opencapture.openzcine.frozen.vulkan"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 29
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                // The donor's original app flags.
                cppFlags += listOf("-std=c++17", "-fno-exceptions", "-fno-rtti")
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}
