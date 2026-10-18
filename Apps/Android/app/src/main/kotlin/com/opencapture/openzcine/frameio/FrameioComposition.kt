package com.opencapture.openzcine.frameio

import android.content.Context
import com.opencapture.opencine.frameio.AndroidFrameioDestinationStore
import com.opencapture.opencine.frameio.AndroidFrameioHttpClient
import com.opencapture.opencine.frameio.AndroidFrameioMetadataSidecarWriter
import com.opencapture.opencine.frameio.AndroidFrameioReachability
import com.opencapture.opencine.frameio.AndroidFrameioSecretStore
import com.opencapture.opencine.frameio.AndroidFrameioUploadHistoryStore
import com.opencapture.opencine.frameio.FrameioDeliveryController
import com.opencapture.opencine.frameio.FrameioNative
import com.opencapture.opencine.frameio.FrameioPublicConfiguration
import com.opencapture.opencine.frameio.FrameioStorageNamespace
import com.opencapture.opencine.frameio.NativeFrameioCoreBridge
import com.opencapture.openzcine.BuildConfig
import com.opencapture.openzcine.lut.AndroidLutLibrary

/** The redirect callback the activity hands to the shared Frame.io owner. */
internal typealias FrameioRedirectCallback = com.opencapture.opencine.frameio.FrameioRedirectCallback

/** Reads and validates the deliberately optional Android Frame.io configuration. */
internal object FrameioBuildConfiguration {
    private const val UNCONFIGURED_SCHEME = "openzcine-frameio-unconfigured"

    fun current(): FrameioPublicConfiguration? =
        FrameioPublicConfiguration.from(
            clientID = BuildConfig.FRAMEIO_CLIENT_ID,
            redirectURI = BuildConfig.FRAMEIO_REDIRECT_URI,
            registeredScheme = BuildConfig.FRAMEIO_REDIRECT_SCHEME,
            placeholderScheme = UNCONFIGURED_SCHEME,
        )
}

/**
 * OpenZCine's composition of the shared Frame.io owner: its storage namespace (unchanged, so a
 * signed-in operator stays signed in), approved upload roots and the shared Swift wire exported
 * by libOpenZCineAndroid.so.
 */
internal fun frameioDeliveryController(context: Context): FrameioDeliveryController {
    FrameioNative.load("OpenZCineAndroid")
    val namespace = FrameioStorageNamespace("openzcine.frameio", "openzcine.frameio.oauth", "openzcine.frameio-upload-history")
    return FrameioDeliveryController(
        configuration = FrameioBuildConfiguration::current,
        core = NativeFrameioCoreBridge,
        http = AndroidFrameioHttpClient,
        secretStore = AndroidFrameioSecretStore(context, namespace),
        destinationStore = AndroidFrameioDestinationStore(context, namespace),
        reachability = AndroidFrameioReachability(context),
        approvedUploadRoots = listOf(shareReadyRoot(context), frameioExportRoot(context)),
        productName = "OpenZCine",
        metadataSidecarWriter =
            AndroidFrameioMetadataSidecarWriter(context.filesDir.resolve("frameio-delivery/metadata").toPath(), "OpenZCine"),
        uploadHistory = AndroidFrameioUploadHistoryStore(context, namespace),
    )
}

/** The LUT export preparer whose outputs land in the controller's approved export root. */
internal fun frameioArtifactPreparer(context: Context, lutLibrary: AndroidLutLibrary): FrameioArtifactPreparer =
    AndroidFrameioArtifactPreparer(
        exportRoot = frameioExportRoot(context),
        lutProvider = AndroidFrameioLutProvider(lutLibrary),
        exporter = AndroidMedia3FrameioLutVideoExporter(context),
    )

private fun shareReadyRoot(context: Context) = context.cacheDir.resolve("share/ready").toPath()

private fun frameioExportRoot(context: Context) = context.cacheDir.resolve("frameio/exports").toPath()
