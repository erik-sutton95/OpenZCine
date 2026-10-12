package com.opencapture.openzcine.media

import android.content.Context
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliveryRemote
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliverySelection
import com.opencapture.opencine.frameio.FrameioCapturedProjectListing
import com.opencapture.opencine.frameio.FrameioDeliveryController
import com.opencapture.opencine.frameio.FrameioInternetLease
import com.opencapture.opencine.frameio.FrameioProject
import com.opencapture.opencine.frameio.FrameioSidecarFacts
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.frameio.FrameioArtifactContext
import com.opencapture.openzcine.frameio.FrameioArtifactPreparer
import com.opencapture.openzcine.frameio.FrameioDeliveryArtifact
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal typealias NikonDeliverySelection = MonitorOperatorDeliverySelection<MediaDeliverySelection, Unit,
    MonitorMovieExportContainer, FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease>

/**
 * Nikon cache facts, SDK ports and export leaves of one delivery selection (A4-10). The shared
 * Host owns the popup and request, the app-scoped coordinator owns the run, its progress and
 * toast, and the root chrome presents the chooser. Every delivered file is a staged copy in the
 * FileProvider's `share/ready` subtree, so the original cache stays private.
 */
internal class NikonMediaDelivery(
    appContext: Context,
    /** The app-scoped run owner the root chrome reads. */
    val coordinator: MonitorDeliveryCoordinator,
    val frameio: FrameioDeliveryController,
    private val cacheStore: MediaCacheStore,
    galleryGateway: MediaGalleryGateway,
    private val exporter: FrameioArtifactPreparer,
) {
    private val stager = MediaShareStager(appContext.cacheDir.toPath())
    private val gallery = MediaGallerySaver(galleryGateway)
    private class Delivered(val share: StagedMediaShare, val captureTimestampMillis: Long?)
    // Delivered files of this process: what the chooser, Gallery and upload name each one.
    private val delivered = ConcurrentHashMap<File, Delivered>()

    fun displayName(file: File): String = delivered[file]?.share?.displayName ?: file.name
    fun mimeType(file: File): String = delivered[file]?.share?.mimeType ?: "application/octet-stream"

    /** One Gallery insert per delivered file; camera masters are not Gallery media. */
    val photos = MonitorDeliveryPhotosService<File> { file ->
        val item = delivered[file] ?: return@MonitorDeliveryPhotosService false
        if (!item.share.mimeType.startsWith("video/") && !item.share.mimeType.startsWith("image/")) false
        else withContext(Dispatchers.IO) {
            val entered = currentCoroutineContext()
            gallery.saveOne(MediaGalleryArtifact.fromStagedShare(item.share, item.captureTimestampMillis)) { entered.ensureActive() } == null
        }
    }

    /**
     * Captures one selection. Its popup stays current while the gallery (or an owned internet
     * route) is; its run only needs the cache content, so it outlives the media screen. Camera
     * transfer for uncached originals needs the gallery's camera source.
     */
    fun selection(
        records: List<MonitorMediaRecord<NikonLibraryClip>>, library: MonitorMediaLibraryModel<NikonLibraryClip>,
        opening: MonitorMediaGalleryOpen<NikonLibraryClip>, connectionOwner: Long?, sourceCurrent: () -> Boolean,
        captureRecord: (MonitorMediaRecord<NikonLibraryClip>) -> MonitorPlaybackAdmission,
        selectedLut: FeedLutSelection?, lutLabel: String?, defaults: MediaDeliveryConfiguration = MediaDeliveryConfiguration(),
    ): NikonDeliverySelection? {
        if (records.isEmpty()) return null
        val capture = Capture(records, records.map(captureRecord), library, opening, sourceCurrent)
        if (!capture.popupCurrent()) return null
        val selection = capture.selection
        val bakeable = selection.any { it.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY }
        val originals = NikonDeliveryOriginals(selection, cacheStore, connectionOwner != null,
            SwiftCoreMediaObjectTransferBridge(connectionOwner), MonitorDeliveryAdmission(capture::contentCurrent),
            acquisition = MonitorDeliveryAdmission(capture::nativeCurrent))
        val source = MonitorDeliverySource<MediaDeliverySelection, Unit, MonitorMovieExportContainer>(originals.service,
            prepare = { record, configuration, report ->
                // Stills and camera masters are delivered unchanged; only a video proxy takes the look.
                prepare(originals.workItem(record) ?: error("Cached clip is no longer available."),
                    MediaDeliveryConfiguration(bakeLut = configuration?.bakeLUT == true && selectedLut != null &&
                        record.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY,
                        exportContainer = configuration?.exportFormat ?: defaults.exportContainer,
                        includeMetadata = configuration?.includeMetadata ?: defaults.includeMetadata,
                        selectedLut = selectedLut, forceFrameioReupload = configuration?.forceReupload == true), report)
            }, filename = { it.clip.filename },
            metadata = { mediaDeliveryMetadataSummary(it.map { record -> record.clip }) },
            load = { originals.loadCompleteEntries() })
        val options = MonitorDeliveryExportOptions<Unit, MonitorMovieExportContainer>(
            curves = emptyList(), formats = MonitorMovieExportContainer.entries.map { MonitorDeliveryChoice(it.name, it.label, it) },
            lutAvailable = { selectedLut != null && bakeable }, convertLogAvailable = { null }, lutLabel = { lutLabel },
            convertHelp = "", convertUnavailableHelp = "", bakeExposureAvailable = { null }, formatsForRemoteUpload = true,
            filename = { records.singleOrNull()?.payload?.clip?.filename })
        val remote = MonitorOperatorDeliveryRemote<MediaDeliverySelection, FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease>(
            frameio.remoteService(current = capture::popupCurrent, onLease = { capture.lease = it }),
            run = { request ->
                val includeMetadata = request.configuration?.includeMetadata ?: defaults.includeMetadata
                val lutName = lutLabel.takeIf { request.configuration?.bakeLUT == true }
                frameio.remoteRun<MediaDeliverySelection>(request, identity = { it.clip.libraryKey(it.cameraID) },
                    sidecar = { record -> if (!includeMetadata) null
                        else FrameioSidecarFacts(record.cameraID, record.clip.captureDate, record.clip.filename, lutName) },
                    displayName = ::displayName)
            })
        return NikonDeliverySelection(selection, facts = { capture.selectionFacts(connectionOwner) },
            admission = MonitorDeliveryAdmission(capture::contentCurrent), source = source, photos = photos,
            exportOptions = options, configuration = MonitorDeliveryExportConfiguration(Unit, defaults.exportContainer,
                bakeLUT = selectedLut != null && bakeable, bakeLUTExposure = false, includeMetadata = defaults.includeMetadata,
                forceReupload = defaults.forceFrameioReupload),
            remote = remote)
    }

    /** Stages the cached original, or its LUT export, as one immutable `share/ready` copy. */
    private suspend fun prepare(item: MediaDeliveryWorkItem, options: MediaDeliveryConfiguration,
        report: (Double) -> Unit): File {
        val original = withContext(Dispatchers.IO) {
            val entered = currentCoroutineContext()
            stager.stage(item.entry, item.clip) { entered.ensureActive() }
        }
        val artifact = FrameioDeliveryArtifact(original, withContext(Dispatchers.IO) { Files.size(original.file) },
            FrameioArtifactContext(item.cameraID, item.clip.captureDate,
                item.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY, item.clip.libraryKey(item.cameraID)))
        val prepared = exporter.prepare(artifact, options) { report(it) }
        val ready = try {
            if (prepared.transientExport == null) prepared.share else withContext(Dispatchers.IO) {
                val entered = currentCoroutineContext()
                stager.stagePreparedArtifact(prepared.share.file, prepared.byteCount, prepared.share.displayName,
                    prepared.share.mimeType) { entered.ensureActive() }
            }
        } finally {
            // The staged copy is the deliverable; the temporary export goes now.
            if (prepared.transientExport != null) withContext(NonCancellable) { runCatching { exporter.release(prepared) } }
        }
        val file = ready.file.toFile()
        delivered[file] = Delivered(ready, mediaCaptureTimestampMillis(item.clip.captureDate).takeIf { options.includeMetadata })
        return file
    }

    /** Captured gallery, cache and route facts of one selection. */
    private inner class Capture(
        val records: List<MonitorMediaRecord<NikonLibraryClip>>, private val native: List<MonitorPlaybackAdmission>,
        private val library: MonitorMediaLibraryModel<NikonLibraryClip>,
        private val opening: MonitorMediaGalleryOpen<NikonLibraryClip>, private val sourceCurrent: () -> Boolean,
    ) {
        val selection = records.map { MediaDeliverySelection(it.payload.bucket, it.payload.clip) }
        private val directory = library.cache.directory
        private val directoryRoot = directory.root
        private val directoryGeneration = directory.generation
        private val cacheRoot = cacheStore.rootDirectory
        private val store = library.cache.catalogStore
        private val namespace = store?.namespace
        private val storeGeneration = store?.generation
        var lease: FrameioInternetLease? = null
        /** The cache content this selection captured is unchanged. */
        fun contentCurrent(): Boolean {
            if (!sameRoots()) return false
            val indexed = library.cache.load()
            val accepted = records.all { old -> indexed.firstOrNull { it.asset.id == old.asset.id }?.let {
                it.address == old.address && sameNikonActionContent(it.payload.clip, old.payload.clip)
            } ?: true }
            return accepted && sameRoots()
        }
        private fun sameRoots(): Boolean = directory.root == directoryRoot && directory.generation == directoryGeneration &&
            cacheStore.rootDirectory == cacheRoot && library.cache.catalogStore === store &&
            store?.namespace == namespace && store?.generation == storeGeneration
        /** The gallery's camera source that captured the selection is still the open one. */
        fun nativeCurrent(): Boolean = sourceCurrent() && library.isCurrent(opening.admission) &&
            native.all { it.isCurrent() } && sourceCurrent()
        /** The popup is current while its gallery is, or while it owns the internet route it left on. */
        fun popupCurrent(): Boolean {
            if (!contentCurrent()) return false
            val route = lease
            val planned = route != null && frameio.ownsInternetHop(route) && route.leftCamera == true
            return (planned || nativeCurrent()) && contentCurrent()
        }
        fun selectionFacts(connectionOwner: Long?) = MonitorDeliverySelectionFacts(records.map {
            MonitorDeliveryFileFacts(it.payload.clip.filename, it.payload.clip.sizeBytes.takeIf { size -> size > 0 })
        }, selection.count {
            runCatching { cacheStore.completedEntryOrNull(it.cameraID, MediaCacheObjectIdentity(it.clip), it.clip.sizeBytes) }.getOrNull() != null
        }, if (nativeCurrent()) connectionOwner != null else false)
    }
}
