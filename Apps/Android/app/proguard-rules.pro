# App-specific R8/ProGuard rules for release builds.
#
# Keep what is left of the core-api seam (monitor availability, relay lease and
# encoder profile) intact. The Nikon session contract moved to OpenCine `:nikon`,
# whose consumer rules keep it and its NikonNative JNI facade.
-keep class com.opencapture.openzcine.core.** { *; }

# Swift invokes the bridge methods and listener callbacks by their exact JNI
# names (`Java_com_opencapture_…` / GetMethodID). R8 must not rename or remove
# either side of that contract from a release package.
-keep class com.opencapture.openzcine.bridge.** { *; }

# ML Kit boots itself from a ContentProvider that reflectively instantiates the
# ComponentRegistrar named in each `MlKitComponentDiscoveryService` meta-data
# KEY. R8 sees no code reference to those class names, and AGP's generated aapt
# rules only keep the provider/service themselves — so nothing but this rule
# stands between a shrunk release and `MlKitContext has not been initialized`,
# which is exactly the "text recognition is not ready" report in issue #267.
# `verify-android-native-libs.sh` fails the release build if the packaged model,
# native pipeline, or init provider ever goes missing.
-keep class com.google.mlkit.common.internal.MlKitComponentDiscoveryService { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.mlkit.vision.text.internal.** { *; }
# The bundled Latin pipeline reaches its Java side from libmlkit_google_ocr_pipeline.so.
-keepclasseswithmembernames class com.google.mlkit.** {
    native <methods>;
}

# USB-C PTP byte transport is only called from Swift via GetMethodID on
# writeBulk/readBulk/readEvent/isClosed/close. R8 cannot see those native
# call sites and otherwise strips the methods as unused, which surfaces as
# NoSuchMethodError inside sessionConnectUsb on release/minified builds. The
# interface moved to OpenCine `:nikon`, whose consumer rules keep it and every
# implementation (this app's AndroidUsbPtpTransport included).
