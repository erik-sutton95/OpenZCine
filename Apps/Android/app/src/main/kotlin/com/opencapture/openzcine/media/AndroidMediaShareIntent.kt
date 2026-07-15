package com.opencapture.openzcine.media

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider

/**
 * Android adapter for the pure [MediaShareIntentSpec] policy.
 *
 * The manifest scopes this provider to `cacheDir/share/ready` only. Do not
 * broaden that XML path: the no-backup progressive cache and `share/staging`
 * must remain invisible to receiving applications.
 */
internal object AndroidMediaShareIntent {
    private const val PROVIDER_AUTHORITY_SUFFIX = ".media-share"

    /** Returns the provider-backed content URI for a fully staged clip. */
    fun contentUri(context: Context, share: StagedMediaShare): Uri =
        FileProvider.getUriForFile(
            context,
            "${context.packageName}$PROVIDER_AUTHORITY_SUFFIX",
            share.file.toFile(),
        )

    /**
     * Builds the native chooser for one fully staged artifact.
     */
    fun chooserIntent(context: Context, share: StagedMediaShare): Intent =
        chooserIntent(context, listOf(share))

    /**
     * Builds the native chooser for already-staged artifacts. The nested send
     * intent carries both `EXTRA_STREAM` and ClipData so Android grants read
     * access to each provider URI without exposing a `file://` path.
     */
    fun chooserIntent(
        context: Context,
        shares: List<StagedMediaShare>,
        metadataText: String? = null,
    ): Intent {
        require(shares.isNotEmpty()) { "At least one staged media file is required." }
        val uris = shares.map { share -> contentUri(context, share) }
        val spec = MediaShareIntentSpec.forShares(shares)
        val clipData = ClipData.newRawUri(spec.clipDataLabel, uris.first())
        uris.drop(1).forEach { uri -> clipData.addItem(ClipData.Item(uri)) }
        val sendIntent =
            Intent(spec.action).apply {
                type = spec.mimeType
                if (shares.size == 1) {
                    putExtra(Intent.EXTRA_STREAM, uris.single())
                    putExtra(Intent.EXTRA_TITLE, shares.single().displayName)
                } else {
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                    putExtra(Intent.EXTRA_TITLE, "OpenZCine media")
                }
                metadataText?.takeIf(String::isNotBlank)?.let { summary ->
                    putExtra(Intent.EXTRA_TEXT, summary)
                }
                this.clipData = clipData
                if (spec.grantsReadUriPermission) {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
        return Intent.createChooser(sendIntent, spec.chooserTitle).apply {
            if (spec.grantsReadUriPermission) {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
    }
}
