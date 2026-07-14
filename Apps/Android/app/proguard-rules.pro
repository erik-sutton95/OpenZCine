# App-specific R8/ProGuard rules for release builds.
#
# Keep the camera-core seam (Apps/Android/core-api) intact. That module is the
# deliberate public boundary where the shared camera core plugs in (JNI bridge or
# Kotlin port later); shrinking or renaming its surface would break the seam
# contract, and reflection/JNI lookups against it must keep working.
-keep class com.opencapture.openzcine.core.** { *; }
