package com.opencapture.openzcine.media

/** iOS `MediaDeliveryDestination`: where a delivery run sends prepared clips. */
internal enum class MediaDeliveryDestination(
    val title: String,
    val subtitle: String,
    val actionTitle: String,
) {
    NATIVE_SHARE(
        title = "Share",
        subtitle = "Nearby Share, Files, and other apps",
        actionTitle = "Share",
    ),
    FRAMEIO(
        title = "Frame.io",
        subtitle = "Upload to your Frame.io project",
        actionTitle = "Upload",
    ),
}

/** iOS `MediaDeliveryPostExportAction` for the native Share path. */
internal enum class MediaDeliveryPostExportAction {
    SYSTEM_SHARE,
    SAVE_TO_PHOTOS,
}
