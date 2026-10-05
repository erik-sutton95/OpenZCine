pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "OpenZCine"

// Candidate (OpenCine CORE-02): the common camera contracts from the sibling OpenCine checkout
// (one Gradle build for every OpenCine module), pinned by SHA in opencine-pins.txt. Named
// because its build directory is also called `Android`. Replace with the published Maven
// coordinate once it exists.
includeBuild("../../../OpenCine/Android") {
    name = "opencine"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:core")).using(project(":core"))
        // Shared Compose monitor UI and the multicam engine (NIKON-01).
        substitute(module("com.opencapture.opencine:monitor-ui")).using(project(":monitor-ui"))
        substitute(module("com.opencapture.opencine:multicam")).using(project(":multicam"))
        // The Nikon session, its contract and the NikonNative JNI facade (SHELL-04).
        substitute(module("com.opencapture.opencine:nikon")).using(project(":nikon"))
        // The shared cameras page, connection model and saved-camera document (SHELL-02).
        substitute(module("com.opencapture.opencine:appkit")).using(project(":appkit"))
        substitute(module("com.opencapture.opencine:native-runtime")).using(project(":native-runtime"))
        // The shared renderer's legacy OpcVulkan JNI class, probed by the live-feed backend factory.
        substitute(module("com.opencapture.opencine:vulkan")).using(project(":vulkan"))
    }
}

include(":app")
include(":core-api")
// The relay wire is deliberately separate from the camera core: it is the
// tiny versioned transport contract that both the handheld and the Wear OS
// process can host without giving the watch a Nikon/PTP implementation.
include(":wear-relay")
include(":wear")
