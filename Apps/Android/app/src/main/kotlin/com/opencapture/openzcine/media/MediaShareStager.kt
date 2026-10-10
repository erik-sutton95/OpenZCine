package com.opencapture.openzcine.media

import com.opencapture.opencine.media.MonitorMediaShareIntentSpec
import com.opencapture.opencine.media.MonitorMediaShareStager
import com.opencapture.opencine.media.MonitorMediaShareStagingPolicy
import com.opencapture.opencine.media.isSafeMonitorMediaDisplayName
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import java.nio.file.Path

public typealias MediaShareException = com.opencapture.opencine.media.MonitorMediaShareException
public typealias IncompleteMediaShareException = com.opencapture.opencine.media.IncompleteMonitorMediaShareException
public typealias UnsafeMediaShareFilenameException = com.opencapture.opencine.media.UnsafeMonitorMediaShareFilenameException
public typealias InvalidMediaShareSourceException = com.opencapture.opencine.media.InvalidMonitorMediaShareSourceException
public typealias MediaShareCacheLimitException = com.opencapture.opencine.media.MonitorMediaShareCacheLimitException
public typealias StagedMediaShare = com.opencapture.opencine.media.MonitorStagedMediaShare

internal fun isSafeMediaDisplayName(filename: String): Boolean = isSafeMonitorMediaDisplayName(filename)

/** Exact Android intent content over the shared one/many-file policy. */
internal data class MediaShareIntentSpec(
    val action: String,
    val mimeType: String,
    val streamExtraIncluded: Boolean,
    val clipDataLabel: String,
    val grantsReadUriPermission: Boolean,
    val chooserTitle: String,
) {
    companion object {
        fun forShare(share: StagedMediaShare): MediaShareIntentSpec = forShares(listOf(share))
        fun forShares(shares: List<StagedMediaShare>): MediaShareIntentSpec {
            val value = MonitorMediaShareIntentSpec.forShares(shares, batchLabel = "OpenZCine media")
            return MediaShareIntentSpec(value.action, value.mimeType, value.streamExtraIncluded,
                value.clipDataLabel, value.grantsReadUriPermission, value.chooserTitle)
        }
        const val ACTION_SEND: String = MonitorMediaShareIntentSpec.ACTION_SEND
        const val ACTION_SEND_MULTIPLE: String = MonitorMediaShareIntentSpec.ACTION_SEND_MULTIPLE
    }
}

/** Source metadata and the deployed FileProvider retention facts; shared Media owns file IO. */
class MediaShareStager private constructor(private val owner: MonitorMediaShareStager) {
    constructor(cacheDirectory: Path) : this(MonitorMediaShareStager(cacheDirectory,
        MonitorMediaShareStagingPolicy(1_073_741_824L, 8, 24L * 60L * 60L * 1000L, 64 * 1024)))

    internal constructor(cacheDirectory: Path, clock: () -> Long, maximumReadyBytes: Long,
        maximumReadyArtifacts: Int, grantRetentionMillis: Long) : this(MonitorMediaShareStager(cacheDirectory,
            MonitorMediaShareStagingPolicy(maximumReadyBytes, maximumReadyArtifacts, grantRetentionMillis, 64 * 1024), clock))

    fun stage(entry: MediaCacheEntry, clip: NikonMediaClipRecord,
        cancellationCheck: () -> Unit = {}): StagedMediaShare = owner.stage(entry, clip.filename,
            mimeTypeFor(clip.contentKind), cancellationCheck)

    fun stage(entry: MediaCacheEntry, filename: String,
        cancellationCheck: () -> Unit = {}): StagedMediaShare = owner.stage(entry, filename,
            "application/octet-stream", cancellationCheck)

    internal fun stagePreparedArtifact(source: Path, expectedBytes: Long, displayName: String,
        mimeType: String, cancellationCheck: () -> Unit = {}): StagedMediaShare =
        owner.stagePreparedArtifact(source, expectedBytes, displayName, mimeType, cancellationCheck)

    private fun mimeTypeFor(contentKind: NikonMediaContentKind): String = when (contentKind) {
        NikonMediaContentKind.PLAYABLE_PROXY -> "video/*"
        NikonMediaContentKind.STILL_PHOTO -> "image/*"
        NikonMediaContentKind.R3D_MASTER, NikonMediaContentKind.UNSUPPORTED -> "application/octet-stream"
    }
}
