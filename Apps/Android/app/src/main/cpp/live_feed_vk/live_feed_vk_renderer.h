#pragma once

#include <android/asset_manager.h>
#include <android/native_window.h>
#include <jni.h>
#include <cstdint>

// Minimal Vulkan live-feed session. Owned by Kotlin [VulkanLiveFeedNative].
struct LiveFeedVkSession;

extern "C" {

bool LiveFeedVk_IsAvailable();

LiveFeedVkSession* LiveFeedVk_Create(AAssetManager* assets);

void LiveFeedVk_Destroy(LiveFeedVkSession* session);

bool LiveFeedVk_AttachSurface(LiveFeedVkSession* session, ANativeWindow* window);

void LiveFeedVk_DetachSurface(LiveFeedVkSession* session);

void LiveFeedVk_Resize(LiveFeedVkSession* session, int width, int height);

void LiveFeedVk_Resume(LiveFeedVkSession* session);

void LiveFeedVk_Pause(LiveFeedVkSession* session);

void LiveFeedVk_ClearFrame(LiveFeedVkSession* session);

void LiveFeedVk_ClearPlan(LiveFeedVkSession* session);

bool LiveFeedVk_SubmitBitmap(LiveFeedVkSession* session, JNIEnv* env, jobject bitmap);

bool LiveFeedVk_SetPlan(
    LiveFeedVkSession* session,
    int lutSize,
    const uint8_t* lutRgba,
    int lutBytes,
    int limitsPaintSize,
    const uint8_t* limitsPaintRgba,
    int limitsPaintBytes,
    int limitsWeightSize,
    const uint8_t* limitsWeightRgba,
    int limitsWeightBytes,
    bool limitsOn,
    bool peakingOn,
    const float* peakingColor3,
    const float* deLogCurve5,
    float peakingThreshold,
    float peakingRamp,
    bool zebraHighlightOn,
    float zebraHighlight,
    const float* zebraHighlightColor3,
    bool zebraMidtoneOn,
    float zebraMidtone,
    const float* zebraMidtoneColor3,
    bool aspectFill);

}  // extern "C"
