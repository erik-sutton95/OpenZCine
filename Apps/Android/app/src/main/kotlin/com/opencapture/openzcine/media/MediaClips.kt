package com.opencapture.openzcine.media

typealias MediaContentKind = com.opencapture.opencine.nikon.NikonMediaContentKind
typealias StillPreviewStrategy = com.opencapture.opencine.nikon.NikonStillPreviewStrategy
typealias StillPhotoClassification = com.opencapture.opencine.nikon.NikonStillPhotoClassification
typealias MediaClipRecord = com.opencapture.opencine.nikon.NikonMediaClipRecord
typealias MediaObjectIdentity = com.opencapture.opencine.nikon.NikonMediaObjectIdentity

object MediaClips {
    fun parse(wire: String): List<MediaClipRecord> = com.opencapture.opencine.nikon.NikonMediaClips.parse(wire)
    fun newestFirst(clips: List<MediaClipRecord>): List<MediaClipRecord> =
        com.opencapture.opencine.nikon.NikonMediaClips.newestFirst(clips)
}
