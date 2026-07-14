# App-specific R8/ProGuard rules for release builds.
#
# Keep the camera-core seam (Apps/Android/core-api) intact. That module is the
# deliberate public boundary where the shared camera core plugs in (JNI bridge or
# Kotlin port later); shrinking or renaming its surface would break the seam
# contract, and reflection/JNI lookups against it must keep working.
-keep class com.opencapture.openzcine.core.** { *; }

# Swift invokes the bridge methods and listener callbacks by their exact JNI
# names (`Java_com_opencapture_…` / GetMethodID). R8 must not rename or remove
# either side of that contract from a release package.
-keep class com.opencapture.openzcine.bridge.** { *; }
