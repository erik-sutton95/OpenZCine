#include "live_feed_vk_renderer.h"

#include <android/asset_manager_jni.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <vector>

namespace {

AAssetManager* gAssets = nullptr;

jbyte* pinBytes(JNIEnv* env, jbyteArray arr, jboolean* copy, std::vector<uint8_t>& storage) {
    if (!arr) return nullptr;
    const jsize len = env->GetArrayLength(arr);
    storage.resize(static_cast<size_t>(len));
    env->GetByteArrayRegion(arr, 0, len, reinterpret_cast<jbyte*>(storage.data()));
    if (copy) *copy = JNI_TRUE;
    return reinterpret_cast<jbyte*>(storage.data());
}

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_isAvailable(JNIEnv*, jobject) {
    return LiveFeedVk_IsAvailable() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_nativeInitAssets(
    JNIEnv* env,
    jobject,
    jobject assetManager) {
    gAssets = AAssetManager_fromJava(env, assetManager);
}

JNIEXPORT jlong JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_createSession(JNIEnv*, jobject) {
    if (!gAssets) return 0;
    auto* session = LiveFeedVk_Create(gAssets);
    return reinterpret_cast<jlong>(session);
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_destroySession(JNIEnv*, jobject, jlong session) {
    LiveFeedVk_Destroy(reinterpret_cast<LiveFeedVkSession*>(session));
}

JNIEXPORT jboolean JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_attachSurface(
    JNIEnv* env,
    jobject,
    jlong session,
    jobject surface) {
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (!window) return JNI_FALSE;
    const bool ok = LiveFeedVk_AttachSurface(reinterpret_cast<LiveFeedVkSession*>(session), window);
    // Attach acquires; release the local ref from fromSurface.
    ANativeWindow_release(window);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_detachSurface(JNIEnv*, jobject, jlong session) {
    LiveFeedVk_DetachSurface(reinterpret_cast<LiveFeedVkSession*>(session));
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_resize(
    JNIEnv*,
    jobject,
    jlong session,
    jint width,
    jint height) {
    LiveFeedVk_Resize(reinterpret_cast<LiveFeedVkSession*>(session), width, height);
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_resume(JNIEnv*, jobject, jlong session) {
    LiveFeedVk_Resume(reinterpret_cast<LiveFeedVkSession*>(session));
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_pause(JNIEnv*, jobject, jlong session) {
    LiveFeedVk_Pause(reinterpret_cast<LiveFeedVkSession*>(session));
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_clearFrame(JNIEnv*, jobject, jlong session) {
    LiveFeedVk_ClearFrame(reinterpret_cast<LiveFeedVkSession*>(session));
}

JNIEXPORT void JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_clearPlan(JNIEnv*, jobject, jlong session) {
    LiveFeedVk_ClearPlan(reinterpret_cast<LiveFeedVkSession*>(session));
}

JNIEXPORT jboolean JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_submitBitmap(
    JNIEnv* env,
    jobject,
    jlong session,
    jobject bitmap) {
    return LiveFeedVk_SubmitBitmap(reinterpret_cast<LiveFeedVkSession*>(session), env, bitmap)
        ? JNI_TRUE
        : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_opencapture_openzcine_VulkanLiveFeedNative_setPlan(
    JNIEnv* env,
    jobject,
    jlong session,
    jint lutSize,
    jbyteArray lutRgba,
    jint limitsPaintSize,
    jbyteArray limitsPaintRgba,
    jint limitsWeightSize,
    jbyteArray limitsWeightRgba,
    jboolean limitsOn,
    jboolean peakingOn,
    jfloatArray peakingColor,
    jfloatArray deLogCurve,
    jfloat peakingThreshold,
    jfloat peakingRamp,
    jboolean zebraHighlightOn,
    jfloat zebraHighlight,
    jfloatArray zebraHighlightColor,
    jboolean zebraMidtoneOn,
    jfloat zebraMidtone,
    jfloatArray zebraMidtoneColor,
    jboolean aspectFill) {
    std::vector<uint8_t> lut, paint, weight;
    jboolean copy = JNI_FALSE;
    auto* lutPtr = pinBytes(env, lutRgba, &copy, lut);
    auto* paintPtr = pinBytes(env, limitsPaintRgba, &copy, paint);
    auto* weightPtr = pinBytes(env, limitsWeightRgba, &copy, weight);

    float peak[3]{}, zh[3]{}, zm[3]{}, curve[5]{};
    if (peakingColor) env->GetFloatArrayRegion(peakingColor, 0, 3, peak);
    if (zebraHighlightColor) env->GetFloatArrayRegion(zebraHighlightColor, 0, 3, zh);
    if (zebraMidtoneColor) env->GetFloatArrayRegion(zebraMidtoneColor, 0, 3, zm);
    if (deLogCurve) {
        const jsize n = env->GetArrayLength(deLogCurve);
        env->GetFloatArrayRegion(deLogCurve, 0, n > 5 ? 5 : n, curve);
    }

    return LiveFeedVk_SetPlan(
               reinterpret_cast<LiveFeedVkSession*>(session),
               lutSize,
               lutPtr ? reinterpret_cast<const uint8_t*>(lutPtr) : nullptr,
               static_cast<int>(lut.size()),
               limitsPaintSize,
               paintPtr ? reinterpret_cast<const uint8_t*>(paintPtr) : nullptr,
               static_cast<int>(paint.size()),
               limitsWeightSize,
               weightPtr ? reinterpret_cast<const uint8_t*>(weightPtr) : nullptr,
               static_cast<int>(weight.size()),
               limitsOn == JNI_TRUE,
               peakingOn == JNI_TRUE,
               peak,
               curve,
               peakingThreshold,
               peakingRamp,
               zebraHighlightOn == JNI_TRUE,
               zebraHighlight,
               zh,
               zebraMidtoneOn == JNI_TRUE,
               zebraMidtone,
               zm,
               aspectFill == JNI_TRUE)
        ? JNI_TRUE
        : JNI_FALSE;
}

}  // extern "C"
