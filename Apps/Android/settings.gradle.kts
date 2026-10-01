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

// Candidate (OpenCine CORE-02): the common camera contracts from a sibling OpenCineCore checkout,
// pinned by SHA in opencine-pins.txt. Named because OpenCineUI's build also lives in a directory
// called `Android`. Replace with the published Maven coordinate once it exists.
includeBuild("../../../OpenCineCore/Android") {
    name = "opencinecore"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:core")).using(project(":core"))
    }
}

include(":app")
include(":core-api")
// The relay wire is deliberately separate from the camera core: it is the
// tiny versioned transport contract that both the handheld and the Wear OS
// process can host without giving the watch a Nikon/PTP implementation.
include(":wear-relay")
include(":wear")
