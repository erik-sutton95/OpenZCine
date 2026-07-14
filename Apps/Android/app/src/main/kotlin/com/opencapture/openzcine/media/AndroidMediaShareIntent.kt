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
     * Builds the native chooser for [share]. The nested `ACTION_SEND` intent
     * carries both `EXTRA_STREAM` and ClipData so Android grants its read URI
     * permission to the selected recipient instead of exposing a `file://` URI.
     */
    fun chooserIntent(context: Context, share: StagedMediaShare): Intent {
        val uri = contentUri(context, share)
        val spec = MediaShareIntentSpec.forShare(share)
        val sendIntent =
            Intent(spec.action).apply {
                type = spec.mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, share.displayName)
                clipData = ClipData.newRawUri(spec.clipDataLabel, uri)
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
