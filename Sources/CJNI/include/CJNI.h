// Exposes the Android NDK's JNI interface to Swift. On Darwin there is no
// <jni.h> in the search path, so the module is deliberately empty there —
// the facade target that imports it is `#if os(Android)`-gated as well.
#ifndef OZC_CJNI_H
#define OZC_CJNI_H

#ifdef __ANDROID__
#include <jni.h>
#endif

#endif /* OZC_CJNI_H */
