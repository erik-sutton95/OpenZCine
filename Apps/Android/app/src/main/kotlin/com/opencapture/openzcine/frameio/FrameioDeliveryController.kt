package com.opencapture.openzcine.frameio

import android.content.Context
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.media.StagedMediaShare
import com.opencapture.opencine.appkit.*
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.ensureActive

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
        val skippedCount: Int = 0,
        val metadataFailureCount: Int = 0,
        val cleanupFailureCount: Int = 0,
        val historyFailureCount: Int = 0,
        val firstFailureMessage: String? = null,
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

/** Immutable account facts returned to the existing shared preparation task. */
internal class FrameioCapturedProjectListing internal constructor(
    internal val owner: FrameioDeliveryController, internal val accountRevision: UUID,
    val listing: FrameioProjectListing,
)

private data class FrameioBatchArtifact(val index: Int, val artifact: FrameioDeliveryArtifact)

private data class FrameioArtifactUploadOutcome(
    val metadataFailure: Boolean,
    val cleanupFailure: Boolean,
)

/** Exact instance route claim; completion joins entered leave without owning another task. */
internal class FrameioInternetLease internal constructor(
    internal val owner: FrameioDeliveryController,
    internal val revision: UUID,
    internal val hop: FrameioCameraHop,
    internal val admission: () -> Boolean,
) {
    internal var leaveStarted = false
    internal var leftCamera: Boolean? = null
    internal val left = CompletableDeferred<Boolean>()
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
    private val uploadHistory: FrameioUploadHistoryStore = NoFrameioUploadHistoryStore,
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
    private var deliveryPublication = Any()
    var internetHopState by mutableStateOf<FrameioInternetHopState>(FrameioInternetHopState.Idle)
        private set
    var cameraHopAvailability by
        mutableStateOf(FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    internal var accountRevision = UUID.randomUUID()
        private set
    private var cameraHop: FrameioCameraHop? = null
    private var activeCameraHop: FrameioCameraHop? = null
    private var internetLease: FrameioInternetLease? = null
    private var latestInternetLease: FrameioInternetLease? = null
    private val cameraRejoinMutex = Mutex()

    /** Whether a production Adobe client registration is available in this build. */
    val isConfigured: Boolean
        get() = configuration() != null

    /** Whether a stored session exists for a configured build. */
    val isConnected: Boolean
        get() = connectionState == FrameioConnectionState.CONNECTED

    /** True after the consented AP release and until a rejoin attempt finishes. */
    val isInternetHopActive: Boolean
        get() =
            activeCameraHop != null ||
                cameraRejoinMutex.isLocked ||
                internetHopState is FrameioInternetHopState.LeavingCamera

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
        if (!isInternetHopActive && internetHopState !is FrameioInternetHopState.Idle) {
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
        if (isInternetHopActive) return internetHopState is FrameioInternetHopState.Online
        val captured = claimInternetHop { true } ?: return false
        return waitInternetHop(captured)
    }

    fun claimInternetHop(admission: () -> Boolean): FrameioInternetLease? {
        networkState = reachability.state()
        if (networkState != FrameioNetworkState.CAMERA_ACCESS_POINT) {
            errorMessage = if (networkState == FrameioNetworkState.ONLINE)
                "This phone already has a validated internet route." else FrameioReachabilityPolicy.operatorMessage(networkState)
            return null
        }
        val hop = cameraHop
        cameraHopAvailability = hop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
        if (hop == null || cameraHopAvailability != FrameioHopAvailability.READY) {
            errorMessage = cameraHopAvailability.operatorMessage
            return null
        }
        if (isInternetHopActive || internetLease != null || !admission() || cameraHop !== hop ||
            isInternetHopActive || internetLease != null) return null
        val captured = FrameioInternetLease(this, UUID.randomUUID(), hop, admission)
        internetLease = captured; latestInternetLease = captured
        errorMessage = null; internetHopState = FrameioInternetHopState.LeavingCamera
        return captured.takeIf { ownsInternetHop(it) }
    }
    fun ownsInternetHop(captured: FrameioInternetLease): Boolean =
        captured.owner === this && internetLease === captured && latestInternetLease === captured
    fun endedInternetHop(captured: FrameioInternetLease): Boolean =
        captured.owner === this && internetLease == null && latestInternetLease === captured && !cameraRejoinMutex.isLocked

    fun transferInternetHop(captured: FrameioInternetLease): FrameioInternetLease? {
        if (!ownsInternetHop(captured)) return null
        val transferred = FrameioInternetLease(this, captured.revision, captured.hop, captured.admission)
        transferred.leaveStarted = captured.leaveStarted
        if (!captured.left.isCompleted) return null
        // Transfer is admitted only after the existing leave/wait has completed.
        transferred.leftCamera = captured.leftCamera
        transferred.left.complete(captured.leftCamera == true)
        internetLease = transferred; latestInternetLease = transferred
        return transferred
    }

    suspend fun waitInternetHop(captured: FrameioInternetLease): Boolean {
        if (!ownsInternetHop(captured)) return false
        if (!captured.leaveStarted) {
            if (cameraHop !== captured.hop || !captured.admission() || !ownsInternetHop(captured) ||
                cameraHop !== captured.hop) { endInternetHop(captured); return false }
            captured.leaveStarted = true
            val leftCamera = try { withContext(NonCancellable) { captured.hop.leaveCameraNetwork() } }
                catch (_: Exception) { false }
            captured.leftCamera = leftCamera
            captured.left.complete(leftCamera)
            if (!ownsInternetHop(captured)) return false
            if (!leftCamera) {
                internetLease = null
                internetHopState = FrameioInternetHopState.Failed(
                    "OpenZCine couldn't safely disconnect the camera, so its Wi-Fi binding was not released.")
                errorMessage = (internetHopState as FrameioInternetHopState.Failed).message
                return false
            }
            activeCameraHop = captured.hop
        } else if (!captured.left.await()) return false
        if (!ownsInternetHop(captured)) return false
        internetHopState = FrameioInternetHopState.WaitingForInternet
        try {
            repeat(internetWaitAttempts) {
                if (!ownsInternetHop(captured)) return false
                val network = reachability.state()
                if (!ownsInternetHop(captured)) return false
                networkState = network
                if (network == FrameioNetworkState.ONLINE) {
                    internetHopState = FrameioInternetHopState.Online; errorMessage = null
                    return ownsInternetHop(captured)
                }
                internetWaitPoll()
            }
        } catch (error: CancellationException) {
            endInternetHop(captured)
            throw error
        }
        if (!ownsInternetHop(captured)) return false
        val timeout = "A validated internet route did not become available."
        errorMessage = timeout
        endInternetHop(captured)
        if (latestInternetLease === captured && internetHopState is FrameioInternetHopState.Failed)
            errorMessage = "$timeout Camera rejoin could not be verified."
        return false
    }

    fun endInternetHopAfterDismiss() {
        val captured = internetLease ?: return
        restoreInternetHopAfterDismiss(captured)
    }
    fun restoreInternetHopAfterDismiss(captured: FrameioInternetLease) {
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
            try { endInternetHop(captured) } catch (_: Exception) { }
        }
    }
    suspend fun endInternetHop(): Boolean {
        val captured = internetLease
        if (captured != null) return endInternetHop(captured)
        val entered = latestInternetLease ?: return internetHopState is FrameioInternetHopState.Rejoined
        // Legacy concurrent callers still join the exact already-entered attempt and result.
        return withContext(NonCancellable) {
            cameraRejoinMutex.withLock { latestInternetLease === entered &&
                internetHopState is FrameioInternetHopState.Rejoined }
        }
    }
    suspend fun endInternetHop(captured: FrameioInternetLease): Boolean = withContext(NonCancellable) {
        cameraRejoinMutex.withLock {
            if (!ownsInternetHop(captured)) return@withLock false
            // Claim once before suspension; an old caller never reads a successor's native owner.
            internetLease = null
            val leftCamera = if (captured.leaveStarted) captured.left.await() else false
            if (!leftCamera) {
                if (latestInternetLease === captured) internetHopState = FrameioInternetHopState.Idle
                return@withLock false
            }
            if (latestInternetLease !== captured) return@withLock false
            activeCameraHop = null
            internetHopState = FrameioInternetHopState.RejoiningCamera
            val evidence = try { captured.hop.rejoinCameraNetwork() } catch (_: Exception) { null }
            if (latestInternetLease !== captured) return@withLock false
            networkState = reachability.state()
            if (evidence != null) {
                internetHopState = FrameioInternetHopState.Rejoined(evidence)
                true
            } else {
                val message = "Frame.io work finished, but OpenZCine could not verify a new camera session. " +
                    "Reconnect from Your cameras."
                internetHopState = FrameioInternetHopState.Failed(message); errorMessage = message
                false
            }
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
            accountRevision = UUID.randomUUID()
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
        accountRevision = UUID.randomUUID()
        secretStore.clearAll()
        destinationStore.clear()
        selectedDestination = null
        projectListing = null
        projectState = FrameioProjectState.IDLE
        errorMessage = null
        connectionState = if (isConfigured) FrameioConnectionState.SIGNED_OUT else FrameioConnectionState.UNCONFIGURED
    }

    /** Legacy settings facade over the same bounded native query. */
    suspend fun loadProjects() {
        projectState = FrameioProjectState.LOADING; errorMessage = null
        try {
            val captured = loadProjectsCaptured { true }
            if (!ownsProjects(captured)) return
            projectListing = captured.listing; projectState = FrameioProjectState.READY
            chooseSavedOrFirstProject(captured.listing)
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { projectState = FrameioProjectState.ERROR
            errorMessage = error.operatorMessage("Couldn't load Frame.io projects.") }
    }

    /** Native account/query port; page/loading/create policy belongs to shared Preparation. */
    suspend fun loadProjectsCaptured(current: () -> Boolean): FrameioCapturedProjectListing {
        val revision = accountRevision
        val admitted = MonitorDeliveryAdmission { accountRevision == revision && current() && accountRevision == revision }
        checkDeliveryAdmission(admitted)
        val config = requireConfiguration() ?: throw FrameioDeliveryException(errorMessage ?: "Frame.io isn't configured.")
        requireOnlineOrThrow(admitted)
        val token = accessToken(config, admitted)
        val accounts = core.decodeAccounts(apiResponse(FrameioCoreOperation.ACCOUNTS, token, admission = admitted))
            ?.takeIf { it.isNotEmpty() } ?: throw FrameioDeliveryException("Frame.io has no available account.")
        checkDeliveryAdmission(admitted)
        val account = accounts.first()
        val workspaces = core.decodeWorkspaces(apiResponse(FrameioCoreOperation.WORKSPACES, token,
            accountID = account.id, admission = admitted))?.takeIf { it.isNotEmpty() }
            ?: throw FrameioDeliveryException("Frame.io has no available workspace.")
        checkDeliveryAdmission(admitted)
        val workspace = workspaces.first()
        val projects = core.decodeProjects(apiResponse(FrameioCoreOperation.PROJECTS, token,
            accountID = account.id, workspaceID = workspace.id, admission = admitted))
            ?: throw FrameioDeliveryException("Frame.io returned an invalid project list.")
        checkDeliveryAdmission(admitted)
        return FrameioCapturedProjectListing(this, revision,
            FrameioProjectListing(account.id, workspace.id, workspace.name, projects))
    }
    internal fun ownsProjects(captured: FrameioCapturedProjectListing): Boolean =
        captured.owner === this && captured.accountRevision == accountRevision

    fun selectProject(project: FrameioProject): Boolean {
        val listing = projectListing ?: return false
        return selectProjectCaptured(project, FrameioCapturedProjectListing(this, accountRevision, listing)) { true }
    }
    fun selectProjectCaptured(project: FrameioProject, captured: FrameioCapturedProjectListing, current: () -> Boolean): Boolean {
        if (!ownsProjects(captured) || !current() || !ownsProjects(captured)) return false
        val listing = captured.listing
        val folder = project.rootFolderID?.takeIf { it.isNotBlank() } ?: return false
        val destination = FrameioDestination(listing.accountID, listing.workspaceID, project.id, project.name, folder)
        if (!current() || !ownsProjects(captured)) return false
        destinationStore.save(destination)
        if (!current() || !ownsProjects(captured)) return false
        selectedDestination = destination
        return true
    }

    suspend fun createProject(name: String) {
        val listing = projectListing ?: run { errorMessage = "Load Frame.io projects before creating a project."; return }
        val context = FrameioCapturedProjectListing(this, accountRevision, listing)
        projectState = FrameioProjectState.LOADING; errorMessage = null
        try {
            val created = createProjectCaptured(name, context) { true }
            if (!ownsProjects(context)) return
            projectListing = listing.copy(projects = listing.projects + created)
            projectState = FrameioProjectState.READY
            if (!selectProject(created)) errorMessage = "Frame.io created a project without an upload folder. Pick another project."
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { if (ownsProjects(context)) { projectState = FrameioProjectState.ERROR
            errorMessage = error.operatorMessage("Couldn't create the Frame.io project.") } }
    }
    suspend fun createProjectCaptured(name: String, captured: FrameioCapturedProjectListing, current: () -> Boolean): FrameioProject {
        val admitted = MonitorDeliveryAdmission { ownsProjects(captured) && current() && ownsProjects(captured) }
        checkDeliveryAdmission(admitted)
        val config = requireConfiguration() ?: throw FrameioDeliveryException(errorMessage ?: "Frame.io isn't configured.")
        requireOnlineOrThrow(admitted)
        val listing = captured.listing
        val created = core.decodeProject(apiResponse(FrameioCoreOperation.CREATE_PROJECT,
            accessToken(config, admitted), accountID = listing.accountID, workspaceID = listing.workspaceID,
            name = name, admission = admitted)) ?: throw FrameioDeliveryException("Frame.io returned an invalid project response.")
        checkDeliveryAdmission(admitted)
        return created
    }

    /**
     * Uploads only [artifacts] that survived the complete-cache staging path.
     * Each upload is Create File → every pre-signed HTTPS part → status poll;
     * no progressive camera `.part` file or arbitrary filesystem path enters
     * this method.
     */
    suspend fun deliver(
        artifacts: List<FrameioDeliveryArtifact>,
        options: MediaDeliveryConfiguration = MediaDeliveryConfiguration(),
        onDeliveryState: (FrameioDeliveryState) -> Unit = {},
    ) {
        deliverCaptured(artifacts, options, MonitorDeliveryAdmission { true }, internetLease,
            MonitorDeliveryOriginalService({ true }, {}, { null }), { it.share.displayName }, { it },
            onDeliveryState = onDeliveryState)
    }

    /** Shared ordered batch over supplied complete originals; HTTP/export leaves retain native policy. */
    suspend fun <R> deliverCaptured(
        records: List<R>, options: MediaDeliveryConfiguration, source: MonitorDeliveryAdmission,
        route: FrameioInternetLease?, originals: MonitorDeliveryOriginalService<R>, filename: (R) -> String,
        stage: suspend (R) -> FrameioDeliveryArtifact,
        onBatchProgress: (MonitorDeliveryBatchProgress) -> Unit = {},
        onDeliveryState: (FrameioDeliveryState) -> Unit = {},
        completion: MonitorDeliveryAdmission = source,
        capturedProjects: FrameioCapturedProjectListing? = null,
        capturedDestination: FrameioDestination? = null,
    ): FrameioDeliveryState {
        val revision = capturedProjects?.accountRevision ?: accountRevision
        fun accountCurrent(): Boolean = accountRevision == revision && (capturedProjects == null || ownsProjects(capturedProjects))
        val admission = MonitorDeliveryAdmission { accountCurrent() && source.isCurrent() && accountCurrent() }
        val completionAdmission = MonitorDeliveryAdmission { accountCurrent() && completion.isCurrent() && accountCurrent() }
        var publication: Any? = null
        fun publish(state: FrameioDeliveryState) {
            if (admission.isCurrent()) {
                val next = Any()
                publication = next
                deliveryPublication = next
                deliveryState = state
                onDeliveryState(state)
            }
        }
        if (records.isEmpty()) {
            val failed = FrameioDeliveryState.Failed("Only complete cached media can be delivered.")
            publish(failed); route?.let { endInternetHop(it) }; return failed
        }
        if (!admission.isCurrent()) { route?.let { endInternetHop(it) }; return FrameioDeliveryState.Idle }
        val config = requireConfiguration()
        if (config == null) { route?.let { endInternetHop(it) }; return deliveryState }
        if (!requireOnline()) {
            val failed = FrameioDeliveryState.Failed(errorMessage ?: "Frame.io needs a validated internet connection.")
            publish(failed); route?.let { endInternetHop(it) }; return failed
        }
        val destination = if (capturedProjects != null) capturedDestination else capturedDestination ?: selectedDestination
        if (destination == null) {
            val failed = FrameioDeliveryState.Failed("Pick a Frame.io project before uploading.")
            publish(failed); route?.let { endInternetHop(it) }; return failed
        }
        var uploaded = 0; var skipped = 0; var failed = 0
        var metadataFailures = 0; var cleanupFailures = 0; var historyFailures = 0
        var firstFailure: String? = null
        var cancelled: CancellationException? = null
        fun failure(error: Exception) { failed += 1; if (firstFailure == null) firstFailure = error.operatorMessage("Upload failed.") }
        try {
            val indexed = records.mapIndexed { index, value -> IndexedValue(index, value) }
            val batch = MonitorDeliveryModel.runBatch<IndexedValue<R>, FrameioBatchArtifact, FrameioInternetLease>(
                records = indexed, destination = MonitorDeliveryDestination.REMOTE_UPLOAD,
                action = MonitorDeliveryPostExportAction.SYSTEM_SHARE, admission = admission,
                originals = MonitorDeliveryOriginalService({ originals.available(it.value) },
                    { originals.acquire(it.value) }, { originals.progress(it.value) }),
                exporter = MonitorDeliveryExportService { item, _ ->
                    try {
                        val artifact = stage(item.value)
                        checkDeliveryAdmission(admission)
                        val identity = artifact.context.stableClipIdentity
                        val already = if (identity.isNotBlank() && !options.forceFrameioReupload) {
                            try { withContext(Dispatchers.IO) { uploadHistory.wasUploaded(identity) } }
                            catch (error: CancellationException) { throw error }
                            catch (error: Exception) { historyFailures += 1
                                throw FrameioDeliveryException("OpenZCine couldn't read the private Frame.io upload history.") }
                        } else false
                        checkDeliveryAdmission(admission)
                        if (already) { skipped += 1; null } else FrameioBatchArtifact(item.index + 1, artifact)
                    } catch (error: CancellationException) { cancelled = error; throw error }
                    catch (error: Exception) { failure(error); throw error }
                }, share = null, photos = null,
                upload = MonitorDeliveryUploadService("Uploading to Frame.io") { entered, progress ->
                    val artifact = entered.artifact
                    val index = entered.index
                    try {
                        publish(FrameioDeliveryState.Uploading(index, records.size, artifact.share.displayName, 0.0))
                        checkDeliveryAdmission(admission)
                        val outcome = uploadArtifact(config, destination, artifact, options, index, records.size, { state ->
                            publish(state)
                            if (state is FrameioDeliveryState.Uploading)
                                progress((state.progress - 0.45) / 0.55)
                        }, admission)
                        if (outcome.metadataFailure) metadataFailures += 1
                        if (outcome.cleanupFailure) cleanupFailures += 1
                        uploaded += 1
                        val identity = artifact.context.stableClipIdentity
                        if (identity.isNotBlank()) {
                            val saved = try { withContext(Dispatchers.IO) { uploadHistory.recordUploaded(identity) } }
                                catch (error: CancellationException) { throw error } catch (_: Exception) { false }
                            if (!saved) historyFailures += 1
                        }
                    } catch (error: CancellationException) { cancelled = error; throw error }
                    catch (error: Exception) { failure(error); throw error }
                },
                internet = MonitorDeliveryInternetService(needsHop = { false },
                    begin = { error("A route is acquired by the existing preparation owner.") },
                    owns = ::ownsInternetHop, wait = ::waitInternetHop,
                    restoreEntered = { endInternetHop(it) }, restore = ::restoreInternetHopAfterDismiss),
                initialLease = route, filename = { filename(it.value) },
                policy = MonitorDeliveryBatchPolicy(emptySelection = "Only complete cached media can be delivered.",
                    behavior = MonitorDeliveryBatchBehavior(emptyUploadSucceeds = true, singleUploadFailureUsesDetail = false)),
                progress = onBatchProgress)
            cancelled?.let { throw it }
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if (!completionAdmission.isCurrent()) return FrameioDeliveryState.Idle
            val result = if (batch is MonitorDeliveryBatchOutcome.Failed && failed == 0 && skipped == 0 && uploaded == 0)
                FrameioDeliveryState.Failed(batch.message)
            else FrameioDeliveryState.Completed(uploaded, failed, skipped, metadataFailures, cleanupFailures, historyFailures, firstFailure)
            if (completionAdmission.isCurrent()) {
                val next = Any()
                publication = next
                deliveryPublication = next
                deliveryState = result
                onDeliveryState(result)
            }
            return result
        } catch (error: CancellationException) {
            if (publication != null && deliveryPublication === publication) {
                val next = Any()
                deliveryPublication = next
                deliveryState = FrameioDeliveryState.Idle
                if (admission.isCurrent() && deliveryPublication === next) onDeliveryState(FrameioDeliveryState.Idle)
            }
            throw error
        }
    }

    /** Clears a completed/failed delivery message when its overlay is dismissed. */
    fun clearDeliveryState() {
        deliveryPublication = Any()
        deliveryState = FrameioDeliveryState.Idle
    }

    /**
     * Applies the same verified export configuration used by Frame.io without
     * starting OAuth, network, or upload work. Native Share and Gallery call
     * this only after the share stager published a complete immutable copy.
     */
    suspend fun prepareForExternalDelivery(
        artifact: FrameioDeliveryArtifact,
        configuration: MediaDeliveryConfiguration,
        onProgress: suspend (Double) -> Unit = {},
    ): FrameioPreparedArtifact {
        validateApprovedArtifact(artifact)
        val prepared = artifactPreparer.prepare(artifact, configuration, onProgress)
        try {
            validateApprovedArtifact(prepared.share, prepared.byteCount)
            return prepared
        } catch (error: Throwable) {
            withContext(NonCancellable) { runCatching { artifactPreparer.release(prepared) } }
            throw error
        }
    }

    /** Releases an app-owned temporary export after its destination has made a verified copy. */
    suspend fun releaseExternalDelivery(prepared: FrameioPreparedArtifact) {
        artifactPreparer.release(prepared)
    }

    private suspend fun uploadArtifact(
        config: FrameioPublicConfiguration,
        destination: FrameioDestination,
        artifact: FrameioDeliveryArtifact,
        options: MediaDeliveryConfiguration,
        itemIndex: Int,
        itemCount: Int,
        publishDeliveryState: (FrameioDeliveryState) -> Unit,
        admission: MonitorDeliveryAdmission? = null,
    ): FrameioArtifactUploadOutcome {
        checkDeliveryAdmission(admission)
        validateApprovedArtifact(artifact)
        checkDeliveryAdmission(admission)
        val accessToken = accessToken(config, admission)
        checkDeliveryAdmission(admission)
        val prepared =
            artifactPreparer.prepare(artifact, options) { fraction ->
                withContext(uiDispatcher) {
                    publishDeliveryState(FrameioDeliveryState.Uploading(
                            itemIndex,
                            itemCount,
                            artifact.share.displayName,
                            (fraction.coerceIn(0.0, 1.0) * PREPARATION_PROGRESS_SHARE),
                        ))
                }
            }
        var metadataFailure = false
        var primaryFailure: Throwable? = null
        try {
            checkDeliveryAdmission(admission)
            validateApprovedArtifact(prepared.share, prepared.byteCount)
            checkDeliveryAdmission(admission)
            val filename = prepared.share.displayName
            val response =
                apiResponse(
                    operation = FrameioCoreOperation.CREATE_FILE,
                    accessToken = accessToken,
                    accountID = destination.accountID,
                    folderID = destination.folderID,
                    name = filename,
                    fileSize = prepared.byteCount,
                    admission = admission,
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
                requireOnlineOrThrow(admission)
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
                            publishDeliveryState(FrameioDeliveryState.Uploading(
                                    itemIndex,
                                    itemCount,
                                    filename,
                                    progress.coerceAtMost(UPLOAD_PROGRESS_END),
                                ))
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
                publishDeliveryState = publishDeliveryState,
                admission = admission,
            )
            metadataFailure = if (options.includeMetadata) {
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
        } catch (error: Throwable) {
            primaryFailure = error
        }
        val cleanupFailure =
            try {
                withContext(NonCancellable) { artifactPreparer.release(prepared) }
                null
            } catch (error: Throwable) {
                error
            }
        primaryFailure?.let { failure ->
            cleanupFailure?.let(failure::addSuppressed)
            throw failure
        }
        return FrameioArtifactUploadOutcome(
            metadataFailure = metadataFailure,
            cleanupFailure = cleanupFailure != null,
        )
    }

    private suspend fun waitForUploadComplete(
        accountID: String,
        fileID: String,
        config: FrameioPublicConfiguration,
        itemIndex: Int,
        itemCount: Int,
        filename: String,
        publishDeliveryState: (FrameioDeliveryState) -> Unit,
        admission: MonitorDeliveryAdmission? = null,
    ) {
        repeat(MAX_UPLOAD_STATUS_POLLS) { attempt ->
            val response =
                apiResponse(
                    operation = FrameioCoreOperation.UPLOAD_STATUS,
                    accessToken = accessToken(config, admission),
                    accountID = accountID,
                    fileID = fileID,
                    admission = admission,
                )
            when (core.decodeUploadComplete(response)) {
                true -> {
                    publishDeliveryState(FrameioDeliveryState.Uploading(itemIndex, itemCount, filename, 1.0))
                    return
                }
                false -> {
                    val progress = 0.85 + 0.1 * attempt.toDouble() / MAX_UPLOAD_STATUS_POLLS.toDouble()
                    publishDeliveryState(FrameioDeliveryState.Uploading(itemIndex, itemCount, filename, progress))
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
        admission: MonitorDeliveryAdmission? = null,
    ): String {
        requireOnlineOrThrow(admission)
        val request =
            core.apiRequest(operation, accountID, workspaceID, folderID, fileID, name, fileSize)
                ?: throw FrameioDeliveryException("Frame.io support is unavailable in this install.")
        checkDeliveryAdmission(admission)
        val response = http.execute(request, bearerToken = accessToken)
        requireSuccess(response, "Frame.io request")
        return response.body
    }

    private suspend fun accessToken(config: FrameioPublicConfiguration, admission: MonitorDeliveryAdmission? = null): String {
        checkDeliveryAdmission(admission)
        val stored = secretStore.load().token
            ?: throw FrameioDeliveryException("Sign in to Frame.io from Settings → Storage first.")
        checkDeliveryAdmission(admission)
        if (clock() < stored.expiresAtEpochMillis - REFRESH_EARLY_MILLIS) return stored.accessToken
        val refreshToken = stored.refreshToken
            ?: run {
                secretStore.clearToken()
                connectionState = FrameioConnectionState.SIGNED_OUT
                throw FrameioDeliveryException("Your Frame.io session expired. Sign in again from Settings → Storage.")
            }
        requireOnlineOrThrow(admission)
        val request =
            core.tokenRequest(
                kind = TOKEN_REFRESH,
                config = config,
                refreshToken = refreshToken,
            ) ?: throw FrameioDeliveryException("Frame.io could not prepare a token refresh.")
        checkDeliveryAdmission(admission)
        val response =
            http.execute(
                request = request,
                contentType = "application/x-www-form-urlencoded",
            )
        checkDeliveryAdmission(admission)
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

    private fun checkDeliveryAdmission(admission: MonitorDeliveryAdmission?) {
        if (admission != null && !admission.isCurrent()) throw CancellationException("Delivery source is no longer available.")
    }

    private fun requireOnlineOrThrow(admission: MonitorDeliveryAdmission? = null) {
        checkDeliveryAdmission(admission)
        val online = requireOnline()
        checkDeliveryAdmission(admission)
        if (online) return
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
        uploadHistory = AndroidFrameioUploadHistoryStore(context),
    )
}

/** Internal failure whose text is intentionally free of response bodies/tokens. */
internal class FrameioDeliveryException(message: String) : IOException(message)

private fun Exception.operatorMessage(fallback: String): String =
    (this as? FrameioDeliveryException)?.message ?: fallback
