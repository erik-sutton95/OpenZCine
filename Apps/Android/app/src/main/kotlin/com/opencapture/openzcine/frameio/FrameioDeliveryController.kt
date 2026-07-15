package com.opencapture.openzcine.frameio

import android.content.Context
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.media.StagedMediaShare
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Operator-visible Frame.io account state; never contains bearer material. */
internal enum class FrameioConnectionState {
    UNCONFIGURED,
    SIGNED_OUT,
    AUTHORIZING,
    CONNECTED,
    ERROR,
}

/** Project-list activity shown by the Android delivery picker. */
internal enum class FrameioProjectState {
    IDLE,
    LOADING,
    READY,
    ERROR,
}

/** Persisted-safe delivery progress displayed above the media grid. */
internal sealed interface FrameioDeliveryState {
    data object Idle : FrameioDeliveryState

    data class Uploading(
        val itemIndex: Int,
        val itemCount: Int,
        val filename: String,
        val progress: Double,
    ) : FrameioDeliveryState

    data class Completed(
        val uploadedCount: Int,
        val failedCount: Int,
        val metadataFailureCount: Int = 0,
    ) : FrameioDeliveryState

    data class Failed(val message: String) : FrameioDeliveryState
}

/** One validated original staged from the complete camera cache for upload. */
internal class FrameioDeliveryArtifact(
    val share: StagedMediaShare,
    val byteCount: Long,
    val context: FrameioArtifactContext =
        FrameioArtifactContext(
            cameraID = "",
            captureDate = "",
            supportsLutBake = true,
        ),
) {
    override fun toString(): String = "FrameioDeliveryArtifact(redacted)"
}

/**
 * State holder for Android Frame.io sign-in, destination selection, and
 * original-cache delivery. The class has no camera protocol knowledge: callers
 * may supply only [FrameioDeliveryArtifact] values produced from the existing
 * complete-cache share staging path.
 */
@Stable
internal class FrameioDeliveryController(
    private val configuration: () -> FrameioPublicConfiguration?,
    private val core: FrameioCoreBridge,
    private val http: FrameioHttpClient,
    private val secretStore: FrameioSecretStore,
    private val destinationStore: FrameioDestinationStore,
    private val reachability: FrameioReachability,
    private val shareReadyRoot: Path,
    private val approvedUploadRoots: List<Path> = listOf(shareReadyRoot),
    private val artifactPreparer: FrameioArtifactPreparer = PassthroughFrameioArtifactPreparer,
    private val metadataSidecarWriter: FrameioMetadataSidecarWriter =
        NoFrameioMetadataSidecarWriter,
    private val clock: () -> Long = System::currentTimeMillis,
    private val uiDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val internetWaitPoll: suspend () -> Unit = { delay(INTERNET_WAIT_POLL_MILLIS) },
    private val internetWaitAttempts: Int = DEFAULT_INTERNET_WAIT_ATTEMPTS,
) {
    var connectionState by mutableStateOf(initialConnectionState())
        private set
    var projectState by mutableStateOf(FrameioProjectState.IDLE)
        private set
    var networkState by mutableStateOf(reachability.state())
        private set
    var projectListing by mutableStateOf<FrameioProjectListing?>(null)
        private set
    var selectedDestination by mutableStateOf(destinationStore.load())
        private set
    var deliveryState by mutableStateOf<FrameioDeliveryState>(FrameioDeliveryState.Idle)
        private set
    var internetHopState by mutableStateOf<FrameioInternetHopState>(FrameioInternetHopState.Idle)
        private set
    var cameraHopAvailability by
        mutableStateOf(FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    private var cameraHop: FrameioCameraHop? = null
    private var activeCameraHop: FrameioCameraHop? = null

    /** Whether a production Adobe client registration is available in this build. */
    val isConfigured: Boolean
        get() = configuration() != null

    /** Whether a stored session exists for a configured build. */
    val isConnected: Boolean
        get() = connectionState == FrameioConnectionState.CONNECTED

    /** True after the consented AP release and until a rejoin attempt finishes. */
    val isInternetHopActive: Boolean
        get() = activeCameraHop != null

    init {
        require(internetWaitAttempts > 0) { "internetWaitAttempts must be positive." }
        require(approvedUploadRoots.isNotEmpty()) { "At least one approved upload root is required." }
    }

    /**
     * Attaches the current monitor's camera lifecycle owner.
     *
     * Recomposition may replace this adapter, but an already-started hop retains its exact owner
     * until rejoin finishes so it cannot return through a different saved profile.
     */
    fun attachCameraHop(hop: FrameioCameraHop?) {
        cameraHop = hop
        cameraHopAvailability = hop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
    }

    /** Refreshes visible state after app resume or settings presentation. */
    fun refresh() {
        networkState = reachability.state()
        connectionState = initialConnectionState()
        selectedDestination = destinationStore.load()
        cameraHopAvailability = cameraHop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
        if (activeCameraHop == null && internetHopState !is FrameioInternetHopState.Idle) {
            internetHopState = FrameioInternetHopState.Idle
        }
    }

    /**
     * Performs only the operator-approved first half of a camera-AP internet hop.
     *
     * The active delivery sheet remains mounted while this waits for a validated route. No cloud
     * request runs and no binding is released unless this explicit method is called.
     */
    suspend fun beginInternetHop(): Boolean {
        networkState = reachability.state()
        if (networkState != FrameioNetworkState.CAMERA_ACCESS_POINT) {
            errorMessage =
                if (networkState == FrameioNetworkState.ONLINE) {
                    "This phone already has a validated internet route."
                } else {
                    FrameioReachabilityPolicy.operatorMessage(networkState)
                }
            return false
        }
        val hop = cameraHop
        cameraHopAvailability = hop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
        if (hop == null || cameraHopAvailability != FrameioHopAvailability.READY) {
            errorMessage = cameraHopAvailability.operatorMessage
            return false
        }
        if (activeCameraHop != null) return internetHopState is FrameioInternetHopState.Online

        errorMessage = null
        internetHopState = FrameioInternetHopState.LeavingCamera
        val leftCamera =
            try {
                // Consent has already been captured. Complete the session shutdown and binding
                // release as one operation even if the delivery sheet is dismissed concurrently.
                withContext(NonCancellable) { hop.leaveCameraNetwork() }
            } catch (_: Exception) {
                false
            }
        if (!leftCamera) {
            internetHopState =
                FrameioInternetHopState.Failed(
                    "OpenZCine couldn't safely disconnect the camera, so its Wi-Fi binding was not released.",
                )
            errorMessage = (internetHopState as FrameioInternetHopState.Failed).message
            return false
        }
        activeCameraHop = hop
        internetHopState = FrameioInternetHopState.WaitingForInternet
        try {
            repeat(internetWaitAttempts) {
                networkState = reachability.state()
                if (networkState == FrameioNetworkState.ONLINE) {
                    internetHopState = FrameioInternetHopState.Online
                    errorMessage = null
                    return true
                }
                internetWaitPoll()
            }
        } catch (error: CancellationException) {
            endInternetHop()
            throw error
        }

        val timeout = "A validated internet route did not become available."
        errorMessage = timeout
        withContext(NonCancellable) { endInternetHop() }
        if (internetHopState is FrameioInternetHopState.Failed) {
            errorMessage = "$timeout Camera rejoin could not be verified."
        }
        return false
    }

    /** Rejoins through the exact saved profile and records only a protocol-connected result. */
    suspend fun endInternetHop(): Boolean =
        withContext(NonCancellable) {
            val hop = activeCameraHop ?: return@withContext false
            internetHopState = FrameioInternetHopState.RejoiningCamera
            val evidence =
                try {
                    hop.rejoinCameraNetwork()
                } catch (_: Exception) {
                    null
                }
            activeCameraHop = null
            networkState = reachability.state()
            if (evidence != null) {
                internetHopState = FrameioInternetHopState.Rejoined(evidence)
                true
            } else {
                val message =
                    "Frame.io work finished, but OpenZCine could not verify a new camera session. " +
                        "Reconnect from Your cameras."
                internetHopState = FrameioInternetHopState.Failed(message)
                errorMessage = message
                false
            }
        }

    /**
     * Starts an Adobe browser sign-in and persists only encrypted PKCE state.
     *
     * Returns the authorization HTTPS URL for the activity to present, or
     * null after updating [errorMessage] with a safe operator-facing reason.
     */
    fun beginSignIn(): String? {
        val config = requireConfiguration() ?: return null
        if (!requireOnline()) return null
        val transaction = core.beginAuthorization(config, clock())
        if (transaction == null) {
            failConnection("Frame.io support is unavailable in this install. Rebuild with the shared Swift core.")
            return null
        }
        secretStore.savePendingAuthorization(
            FrameioPendingAuthorization(
                redirectURI = config.redirectURI,
                state = transaction.state,
                verifier = transaction.verifier,
                createdAtEpochMillis = transaction.createdAtEpochMillis,
            ),
        )
        errorMessage = null
        connectionState = FrameioConnectionState.AUTHORIZING
        return transaction.authorizationURL
    }

    /** Clears a transaction if Android cannot hand the authorization URL to a browser. */
    fun signInBrowserUnavailable() {
        secretStore.clearPendingAuthorization()
        failConnection("Couldn't open Adobe sign-in on this device. Check for a supported browser and try again.")
    }

    /**
     * Completes a callback delivered to the manifest redirect activity. The
     * shared core verifies the exact redirect and state before Android sends a
     * token-exchange request. No callback parameter is parsed in Kotlin.
     */
    suspend fun completeRedirect(callbackURI: String) {
        val config = requireConfiguration() ?: return
        val pending = secretStore.load().pendingAuthorization
        if (pending == null || pending.redirectURI != config.redirectURI) {
            failConnection("Frame.io sign-in expired. Start it again from Settings → Storage.")
            return
        }
        if (clock() - pending.createdAtEpochMillis !in 0..MAX_PENDING_AUTH_AGE_MILLIS) {
            secretStore.clearPendingAuthorization()
            failConnection("Frame.io sign-in expired. Start it again from Settings → Storage.")
            return
        }
        if (!requireOnline()) return
        val code = core.parseRedirect(config, callbackURI, pending.state)
        if (code == null) {
            secretStore.clearPendingAuthorization()
            failConnection("Frame.io sign-in could not verify this redirect. Start it again from Settings → Storage.")
            return
        }
        try {
            val request =
                core.tokenRequest(
                    kind = TOKEN_EXCHANGE,
                    config = config,
                    code = code,
                    verifier = pending.verifier,
                ) ?: throw FrameioDeliveryException("Frame.io sign-in could not prepare a token exchange.")
            // Do not let an OAuth callback briefly switch the app away from the camera AP and
            // issue a cloud request after the initial reachability check above.
            if (!requireOnline()) return
            val response =
                http.execute(
                    request = request,
                    contentType = "application/x-www-form-urlencoded",
                )
            requireSuccess(response, "Frame.io sign-in")
            val token = core.decodeToken(response.body)
                ?: throw FrameioDeliveryException("Frame.io returned an invalid token response.")
            secretStore.saveToken(token.storedAt(clock()))
            secretStore.clearPendingAuthorization()
            connectionState = FrameioConnectionState.CONNECTED
            errorMessage = null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            secretStore.clearPendingAuthorization()
            failConnection(error.operatorMessage("Frame.io sign-in failed."))
        }
    }

    /** Removes the encrypted token, pending PKCE state, and selected destination. */
    fun disconnect() {
        secretStore.clearAll()
        destinationStore.clear()
        selectedDestination = null
        projectListing = null
        projectState = FrameioProjectState.IDLE
        errorMessage = null
        connectionState = if (isConfigured) FrameioConnectionState.SIGNED_OUT else FrameioConnectionState.UNCONFIGURED
    }

    /** Loads the first account/workspace's eligible upload projects. */
    suspend fun loadProjects() {
        val config = requireConfiguration() ?: return
        if (!requireOnline()) return
        projectState = FrameioProjectState.LOADING
        errorMessage = null
        try {
            val accessToken = accessToken(config)
            val accounts = apiResponse(FrameioCoreOperation.ACCOUNTS, accessToken)
                .let { response -> core.decodeAccounts(response) }
                ?.takeIf { values -> values.isNotEmpty() }
                ?: throw FrameioDeliveryException("Frame.io has no available account.")
            val account = accounts.first()
            val workspaces =
                apiResponse(
                    operation = FrameioCoreOperation.WORKSPACES,
                    accessToken = accessToken,
                    accountID = account.id,
                ).let { response -> core.decodeWorkspaces(response) }
                    ?.takeIf { values -> values.isNotEmpty() }
                    ?: throw FrameioDeliveryException("Frame.io has no available workspace.")
            val workspace = workspaces.first()
            val projects =
                apiResponse(
                    operation = FrameioCoreOperation.PROJECTS,
                    accessToken = accessToken,
                    accountID = account.id,
                    workspaceID = workspace.id,
                ).let { response -> core.decodeProjects(response) }
                    ?: throw FrameioDeliveryException("Frame.io returned an invalid project list.")
            val listing = FrameioProjectListing(account.id, workspace.id, workspace.name, projects)
            projectListing = listing
            projectState = FrameioProjectState.READY
            chooseSavedOrFirstProject(listing)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            projectState = FrameioProjectState.ERROR
            errorMessage = error.operatorMessage("Couldn't load Frame.io projects.")
        }
    }

    /** Persists an eligible project selected in the delivery picker. */
    fun selectProject(project: FrameioProject): Boolean {
        val listing = projectListing ?: return false
        val folderID = project.rootFolderID?.takeIf { value -> value.isNotBlank() } ?: return false
        val destination =
            FrameioDestination(
                accountID = listing.accountID,
                workspaceID = listing.workspaceID,
                projectID = project.id,
                projectName = project.name,
                folderID = folderID,
            )
        destinationStore.save(destination)
        selectedDestination = destination
        return true
    }

    /** Creates and selects a project using the shared Codable request model. */
    suspend fun createProject(name: String) {
        val config = requireConfiguration() ?: return
        val listing = projectListing ?: run {
            errorMessage = "Load Frame.io projects before creating a project."
            return
        }
        if (!requireOnline()) return
        projectState = FrameioProjectState.LOADING
        errorMessage = null
        try {
            val created =
                apiResponse(
                    operation = FrameioCoreOperation.CREATE_PROJECT,
                    accessToken = accessToken(config),
                    accountID = listing.accountID,
                    workspaceID = listing.workspaceID,
                    name = name,
                ).let { response -> core.decodeProject(response) }
                    ?: throw FrameioDeliveryException("Frame.io returned an invalid project response.")
            val updated = listing.copy(projects = listing.projects + created)
            projectListing = updated
            projectState = FrameioProjectState.READY
            if (!selectProject(created)) {
                errorMessage = "Frame.io created a project without an upload folder. Pick another project."
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            projectState = FrameioProjectState.ERROR
            errorMessage = error.operatorMessage("Couldn't create the Frame.io project.")
        }
    }

    /**
     * Uploads only [artifacts] that survived the complete-cache staging path.
     * Each upload is Create File → every pre-signed HTTPS part → status poll;
     * no progressive camera `.part` file or arbitrary filesystem path enters
     * this method.
     */
    suspend fun deliver(
        artifacts: List<FrameioDeliveryArtifact>,
        options: FrameioDeliveryOptions = FrameioDeliveryOptions(),
    ) {
        val rejoinAfterDelivery = activeCameraHop != null
        try {
            if (artifacts.isEmpty()) {
                deliveryState = FrameioDeliveryState.Failed("Only complete cached media can be delivered.")
                return
            }
            val config = requireConfiguration() ?: return
            if (!requireOnline()) {
                deliveryState =
                    FrameioDeliveryState.Failed(
                        errorMessage ?: "Frame.io needs a validated internet connection.",
                    )
                return
            }
            val destination = selectedDestination ?: run {
                deliveryState = FrameioDeliveryState.Failed("Pick a Frame.io project before uploading.")
                return
            }
            var uploaded = 0
            var failed = 0
            var metadataFailures = 0
            var firstFailure: String? = null
            artifacts.forEachIndexed { index, artifact ->
                deliveryState =
                    FrameioDeliveryState.Uploading(
                        itemIndex = index + 1,
                        itemCount = artifacts.size,
                        filename = artifact.share.displayName,
                        progress = 0.0,
                    )
                try {
                    if (
                        uploadArtifact(
                            config,
                            destination,
                            artifact,
                            options,
                            index + 1,
                            artifacts.size,
                        )
                    ) {
                        metadataFailures += 1
                    }
                    uploaded += 1
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    failed += 1
                    if (firstFailure == null) firstFailure = error.operatorMessage("Upload failed.")
                }
            }
            deliveryState =
                if (uploaded > 0) {
                    FrameioDeliveryState.Completed(
                        uploadedCount = uploaded,
                        failedCount = failed,
                        metadataFailureCount = metadataFailures,
                    )
                } else {
                    FrameioDeliveryState.Failed(firstFailure ?: "Frame.io could not upload the selected media.")
                }
        } catch (error: CancellationException) {
            deliveryState = FrameioDeliveryState.Idle
            throw error
        } finally {
            if (rejoinAfterDelivery) {
                withContext(NonCancellable) { endInternetHop() }
            }
        }
    }

    /** Clears a completed/failed delivery message when its overlay is dismissed. */
    fun clearDeliveryState() {
        deliveryState = FrameioDeliveryState.Idle
    }

    private suspend fun uploadArtifact(
        config: FrameioPublicConfiguration,
        destination: FrameioDestination,
        artifact: FrameioDeliveryArtifact,
        options: FrameioDeliveryOptions,
        itemIndex: Int,
        itemCount: Int,
    ): Boolean {
        validateApprovedArtifact(artifact)
        val accessToken = accessToken(config)
        val prepared =
            artifactPreparer.prepare(artifact, options) { fraction ->
                withContext(uiDispatcher) {
                    deliveryState =
                        FrameioDeliveryState.Uploading(
                            itemIndex,
                            itemCount,
                            artifact.share.displayName,
                            (fraction.coerceIn(0.0, 1.0) * PREPARATION_PROGRESS_SHARE),
                        )
                }
            }
        try {
            validateApprovedArtifact(prepared.share, prepared.byteCount)
            val filename = prepared.share.displayName
            val response =
                apiResponse(
                    operation = FrameioCoreOperation.CREATE_FILE,
                    accessToken = accessToken,
                    accountID = destination.accountID,
                    folderID = destination.folderID,
                    name = filename,
                    fileSize = prepared.byteCount,
                )
            val plan = core.decodeUploadPlan(response)
                ?: throw FrameioDeliveryException("Frame.io returned an invalid upload plan.")
            var plannedBytes = 0L
            plan.parts.forEach { part ->
                if (part.sizeBytes > prepared.byteCount - plannedBytes) {
                    throw FrameioDeliveryException("Frame.io's upload plan did not match the approved media size.")
                }
                plannedBytes += part.sizeBytes
            }
            if (plannedBytes != prepared.byteCount) {
                throw FrameioDeliveryException("Frame.io's upload plan did not match the approved media size.")
            }
            val contentType = plan.mediaType ?: core.mediaTypeFor(filename)
                ?: throw FrameioDeliveryException("Frame.io could not resolve a media type for this clip.")
            if (!contentType.isSafeMediaType()) {
                throw FrameioDeliveryException("Frame.io returned an unsafe media type for this clip.")
            }

            var offset = 0L
            val uploadProgressStart =
                if (options.bakeLut) PREPARATION_PROGRESS_SHARE else DIRECT_UPLOAD_PROGRESS_START
            plan.parts.forEach { part ->
                requireOnlineOrThrow()
                val sentBeforePart = offset
                val result =
                    http.putUploadPart(
                        uploadURL = part.url,
                        source = prepared.share.file,
                        offset = offset,
                        byteCount = part.sizeBytes,
                        contentType = contentType,
                    ) { sentInPart ->
                        val sent = sentBeforePart + sentInPart
                        val fraction = sent.toDouble() / prepared.byteCount.toDouble()
                        val progress =
                            uploadProgressStart +
                                (UPLOAD_PROGRESS_END - uploadProgressStart) * fraction
                        // putUploadPart writes on Dispatchers.IO. Compose state is
                        // owned by the UI coroutine, so return to its dispatcher
                        // before publishing incremental upload progress.
                        withContext(uiDispatcher) {
                            deliveryState =
                                FrameioDeliveryState.Uploading(
                                    itemIndex,
                                    itemCount,
                                    filename,
                                    progress.coerceAtMost(UPLOAD_PROGRESS_END),
                                )
                        }
                    }
                requireSuccess(result, "Frame.io upload")
                offset += part.sizeBytes
            }
            waitForUploadComplete(
                accountID = destination.accountID,
                fileID = plan.fileID,
                config = config,
                itemIndex = itemIndex,
                itemCount = itemCount,
                filename = filename,
            )
            return if (options.includeMetadata) {
                try {
                    metadataSidecarWriter.recordSuccessfulDelivery(
                        artifact,
                        prepared,
                        destination,
                        options,
                    )
                    false
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    true
                }
            } else {
                false
            }
        } finally {
            artifactPreparer.release(prepared)
        }
    }

    private suspend fun waitForUploadComplete(
        accountID: String,
        fileID: String,
        config: FrameioPublicConfiguration,
        itemIndex: Int,
        itemCount: Int,
        filename: String,
    ) {
        repeat(MAX_UPLOAD_STATUS_POLLS) { attempt ->
            val response =
                apiResponse(
                    operation = FrameioCoreOperation.UPLOAD_STATUS,
                    accessToken = accessToken(config),
                    accountID = accountID,
                    fileID = fileID,
                )
            when (core.decodeUploadComplete(response)) {
                true -> {
                    deliveryState = FrameioDeliveryState.Uploading(itemIndex, itemCount, filename, 1.0)
                    return
                }
                false -> {
                    val progress = 0.85 + 0.1 * attempt.toDouble() / MAX_UPLOAD_STATUS_POLLS.toDouble()
                    deliveryState = FrameioDeliveryState.Uploading(itemIndex, itemCount, filename, progress)
                }
                null -> throw FrameioDeliveryException("Frame.io returned an invalid upload status.")
            }
            delay(UPLOAD_STATUS_POLL_DELAY_MILLIS)
        }
        throw FrameioDeliveryException("Frame.io did not confirm that the upload finished.")
    }

    private suspend fun apiResponse(
        operation: String,
        accessToken: String,
        accountID: String? = null,
        workspaceID: String? = null,
        folderID: String? = null,
        fileID: String? = null,
        name: String? = null,
        fileSize: Long = 0,
    ): String {
        requireOnlineOrThrow()
        val request =
            core.apiRequest(operation, accountID, workspaceID, folderID, fileID, name, fileSize)
                ?: throw FrameioDeliveryException("Frame.io support is unavailable in this install.")
        val response = http.execute(request, bearerToken = accessToken)
        requireSuccess(response, "Frame.io request")
        return response.body
    }

    private suspend fun accessToken(config: FrameioPublicConfiguration): String {
        val stored = secretStore.load().token
            ?: throw FrameioDeliveryException("Sign in to Frame.io from Settings → Storage first.")
        if (clock() < stored.expiresAtEpochMillis - REFRESH_EARLY_MILLIS) return stored.accessToken
        val refreshToken = stored.refreshToken
            ?: run {
                secretStore.clearToken()
                connectionState = FrameioConnectionState.SIGNED_OUT
                throw FrameioDeliveryException("Your Frame.io session expired. Sign in again from Settings → Storage.")
            }
        requireOnlineOrThrow()
        val request =
            core.tokenRequest(
                kind = TOKEN_REFRESH,
                config = config,
                refreshToken = refreshToken,
            ) ?: throw FrameioDeliveryException("Frame.io could not prepare a token refresh.")
        val response =
            http.execute(
                request = request,
                contentType = "application/x-www-form-urlencoded",
            )
        if (response.statusCode !in 200..299) {
            secretStore.clearToken()
            connectionState = FrameioConnectionState.SIGNED_OUT
            throw FrameioDeliveryException("Your Frame.io session expired. Sign in again from Settings → Storage.")
        }
        val refreshed = core.decodeToken(response.body)
            ?: throw FrameioDeliveryException("Frame.io returned an invalid refreshed session.")
        val updated = refreshed.storedAt(clock(), fallbackRefreshToken = refreshToken)
        secretStore.saveToken(updated)
        connectionState = FrameioConnectionState.CONNECTED
        return updated.accessToken
    }

    private fun chooseSavedOrFirstProject(listing: FrameioProjectListing) {
        val eligible = listing.projects.filter { project -> !project.rootFolderID.isNullOrBlank() }
        val saved = selectedDestination
        val matching =
            saved?.takeIf { destination ->
                destination.accountID == listing.accountID &&
                    destination.workspaceID == listing.workspaceID &&
                    eligible.any { project -> project.id == destination.projectID }
            }
        if (matching != null) return
        eligible.firstOrNull()?.let(::selectProject)
    }

    private fun validateApprovedArtifact(artifact: FrameioDeliveryArtifact) {
        validateApprovedArtifact(artifact.share, artifact.byteCount)
    }

    private fun validateApprovedArtifact(share: StagedMediaShare, byteCount: Long) {
        val roots = approvedUploadRoots.map { root -> root.toAbsolutePath().normalize() }
        val source = share.file.toAbsolutePath().normalize()
        if (
            roots.none(source::startsWith) ||
                !Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(source) ||
                byteCount <= 0 ||
                Files.size(source) != byteCount ||
                !safeDisplayName(share.displayName)
        ) {
            throw FrameioDeliveryException("Only complete approved cache artifacts can be uploaded.")
        }
    }

    private fun safeDisplayName(value: String): Boolean =
        value.isNotBlank() &&
            value == value.trim() &&
            !value.contains('/') &&
            !value.contains('\\') &&
            value.none { character -> character.code < 0x20 || character.code == 0x7F }

    private fun requireConfiguration(): FrameioPublicConfiguration? {
        val config = configuration()
        if (config == null) {
            connectionState = FrameioConnectionState.UNCONFIGURED
            errorMessage =
                "Frame.io isn't configured in this Android build. An approved Adobe OAuth Native App client ID and exact redirect URI are required."
        }
        return config
    }

    private fun requireOnline(): Boolean {
        networkState = reachability.state()
        if (networkState == FrameioNetworkState.ONLINE) return true
        errorMessage = FrameioReachabilityPolicy.operatorMessage(networkState)
        return false
    }

    private fun requireOnlineOrThrow() {
        if (requireOnline()) return
        throw FrameioDeliveryException(errorMessage ?: "Frame.io needs a validated internet connection.")
    }

    private fun initialConnectionState(): FrameioConnectionState =
        if (configuration() == null) {
            FrameioConnectionState.UNCONFIGURED
        } else if (secretStore.load().token == null) {
            FrameioConnectionState.SIGNED_OUT
        } else {
            FrameioConnectionState.CONNECTED
        }

    private fun failConnection(message: String) {
        connectionState = FrameioConnectionState.ERROR
        errorMessage = message
    }

    private fun requireSuccess(response: FrameioHttpResponse, action: String) {
        if (response.statusCode !in 200..299) {
            throw FrameioDeliveryException("$action failed (HTTP ${response.statusCode}).")
        }
    }

    private fun FrameioAccessToken.storedAt(
        nowEpochMillis: Long,
        fallbackRefreshToken: String? = null,
    ): FrameioStoredToken {
        val lifespanMillis = expiresInSeconds.saturatingMillis()
        val expiry = if (lifespanMillis > Long.MAX_VALUE - nowEpochMillis) Long.MAX_VALUE else nowEpochMillis + lifespanMillis
        return FrameioStoredToken(
            accessToken = accessToken,
            refreshToken = refreshToken ?: fallbackRefreshToken,
            expiresAtEpochMillis = expiry,
            tokenType = tokenType,
        )
    }

    private fun Long.saturatingMillis(): Long =
        if (this > Long.MAX_VALUE / 1_000) Long.MAX_VALUE else this * 1_000

    private companion object {
        const val TOKEN_EXCHANGE = "exchange"
        const val TOKEN_REFRESH = "refresh"
        const val REFRESH_EARLY_MILLIS = 60_000L
        const val MAX_PENDING_AUTH_AGE_MILLIS = 10 * 60_000L
        const val MAX_UPLOAD_STATUS_POLLS = 45
        const val UPLOAD_STATUS_POLL_DELAY_MILLIS = 2_000L
        const val PREPARATION_PROGRESS_SHARE = 0.35
        const val DIRECT_UPLOAD_PROGRESS_START = 0.1
        const val UPLOAD_PROGRESS_END = 0.85
        const val INTERNET_WAIT_POLL_MILLIS = 500L
        const val DEFAULT_INTERNET_WAIT_ATTEMPTS = 60
    }
}

/** Creates the production controller with Android-keystore and network adapters. */
internal fun frameioDeliveryController(
    context: Context,
    lutLibrary: com.opencapture.openzcine.lut.AndroidLutLibrary,
): FrameioDeliveryController {
    val shareReadyRoot = context.cacheDir.resolve("share/ready").toPath()
    val frameioExportRoot = context.cacheDir.resolve("frameio/exports").toPath()
    return FrameioDeliveryController(
        configuration = FrameioBuildConfiguration::current,
        core = SwiftFrameioCoreBridge,
        http = AndroidFrameioHttpClient,
        secretStore = AndroidFrameioSecretStore(context),
        destinationStore = AndroidFrameioDestinationStore(context),
        reachability = AndroidFrameioReachability(context),
        shareReadyRoot = shareReadyRoot,
        approvedUploadRoots = listOf(shareReadyRoot, frameioExportRoot),
        artifactPreparer =
            AndroidFrameioArtifactPreparer(
                exportRoot = frameioExportRoot,
                lutProvider = AndroidFrameioLutProvider(lutLibrary),
                exporter = AndroidMedia3FrameioLutVideoExporter(context),
            ),
        metadataSidecarWriter =
            AndroidFrameioMetadataSidecarWriter(
                context.filesDir.resolve("frameio-delivery/metadata").toPath(),
            ),
    )
}

/** Internal failure whose text is intentionally free of response bodies/tokens. */
internal class FrameioDeliveryException(message: String) : IOException(message)

private fun Exception.operatorMessage(fallback: String): String =
    (this as? FrameioDeliveryException)?.message ?: fallback
