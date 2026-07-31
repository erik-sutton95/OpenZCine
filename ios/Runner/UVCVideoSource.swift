import AVFoundation
import CoreImage
import UIKit

/// A frame handed from the capture queue to the main actor.
///
/// `UIImage` is not formally `Sendable`. The instance inside is created on the capture queue,
/// never read or mutated there again, and delivered exactly once — the same one-way transfer
/// `FrameDecoder.decode`'s `sending` return performs on the camera's own live-view path.
struct UVCFrameHandoff: @unchecked Sendable {
    let image: UIImage
}

/// What the HDMI capture path is currently doing, for the operator-facing readout.
enum UVCVideoSourceState: Equatable, Sendable {
    /// This device cannot host a capture device at all. iPadOS exposes UVC devices; iOS does not.
    case unsupportedDevice
    /// The operator has not granted camera access, or refused it.
    case permissionDenied
    /// Supported and permitted, but nothing is plugged in.
    case waitingForDevice
    /// A device is attached and the session is coming up.
    case starting
    /// Frames are arriving. Carries the device's own product name and the format actually
    /// selected — the resolution and rate are the first thing to check when the picture looks
    /// worse than expected, and they should not need a console to read.
    case streaming(deviceName: String, format: String?)
    case failed(reason: String)

    /// Operator-facing one-liner. Deliberately says what to *do*, not what went wrong internally.
    var message: String {
        switch self {
        case .unsupportedDevice:
            "HDMI capture needs an iPad — iOS doesn't expose USB capture devices to apps."
        case .permissionDenied:
            "Allow camera access in Settings so the app can read the capture device."
        case .waitingForDevice:
            "Connect the HDMI capture device and the camera's HDMI output."
        case .starting:
            "Starting HDMI capture…"
        case .streaming(let deviceName, let format):
            format.map { "HDMI capture streaming from \(deviceName) at \($0)." }
                ?? "HDMI capture streaming from \(deviceName)."
        case .failed(let reason):
            reason
        }
    }

    /// Short form for a settings row, where `message` would wrap to three lines.
    var shortStatus: String {
        switch self {
        case .unsupportedDevice: "iPad only"
        case .permissionDenied: "No camera access"
        case .waitingForDevice: "Not connected"
        case .starting: "Starting…"
        case .streaming(let deviceName, let format):
            format.map { "\(deviceName) · \($0)" } ?? deviceName
        case .failed: "Failed"
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }
}

/// Drives the monitor from an HDMI signal digitised by an attached USB Video Class device.
///
/// ## Why this is native rather than a USB driver
///
/// `AVCaptureDevice.DeviceType.external` *is* UVC on iPadOS ("On iPad, external devices are those
/// that conform to the UVC specification" — `AVCaptureDevice.h`), available from iOS 17, which is
/// this app's deployment target. No entitlement is required; only visionOS before 3.0 needed one.
/// So the whole capture path is AVFoundation, and the dongle's vendor and chipset never matter.
///
/// ## Why frames become CGImage-backed `UIImage`s
///
/// The monitor's downstream consumers already assume a real bitmap: the scope tap in particular
/// hard-guards on `image.cgImage` (`LiveFrameProcessor.swift:176`) and silently produces nothing
/// without one. A `UIImage(ciImage:)` would render on screen and quietly kill every scope, so each
/// frame is rendered through a `CIContext` to a `CGImage` — the same shape the JPEG path produces
/// via `preparingForDisplay()`.
///
/// ponytail: one GPU→CGImage render per frame. That is the honest cost of matching the existing
/// `liveFrameImage: UIImage?` contract, and it replaces a JPEG decode rather than adding to it. If
/// 1080p60 proves too heavy on hardware, the upgrade is to route the `CVPixelBuffer` straight into
/// `MetalFeedFrameBaker` and leave `liveFrameImage` for the scope tap alone.
final class UVCVideoSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    /// Whether this hardware can host a UVC capture device at all.
    ///
    /// iPad only — and deliberately checked by idiom rather than by probing for devices, so the
    /// connect wizard can explain the limitation on an iPhone instead of showing a path that will
    /// never find anything. The Simulator reports `.pad` on an iPad simulator but never enumerates
    /// a device, which lands on `waitingForDevice`.
    static var isSupportedHardware: Bool {
        #if DEBUG
            // Debug-only experiment: `AVCaptureDeviceTypeExternal` is documented as iPad-only, but
            // a discovery session costs nothing to run and the only way to learn whether some
            // phone + dongle pair ever enumerates is to let it try. It finds nothing on a phone
            // today, in which case the capture step simply sits on "waiting for the device" —
            // there is no session to start and so no camera indicator or thermal load either.
            // Release keeps the honest gate, so nothing ships an option that cannot work.
            return true
        #else
            return isDocumentedHardware
        #endif
    }

    /// Whether Apple documents UVC support on this hardware. Kept separate from
    /// `isSupportedHardware` so a Debug build that lets a phone try can still explain why it
    /// found nothing.
    static var isDocumentedHardware: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Delivered frames, newest-wins.
    ///
    /// A stream rather than a callback so the consumer is a single serial loop — the same shape as
    /// the camera's own live-view loop — instead of one task per frame, which at 60 fps would both
    /// churn tasks and let frames overtake each other on the way to the screen. `bufferingNewest(1)`
    /// is the monitor's rule stated as a policy: show the latest frame, drop what it replaced.
    let frames: AsyncStream<UVCFrameHandoff>
    private let framesContinuation: AsyncStream<UVCFrameHandoff>.Continuation
    /// Called on the main actor whenever `state` changes.
    private let onStateChange: @MainActor (UVCVideoSourceState) -> Void

    private let session = AVCaptureSession()
    /// Serial queue owning session mutation and sample delivery. `startRunning` blocks, so it must
    /// never be the main thread.
    private let captureQueue = DispatchQueue(
        label: "com.opencapture.openzcine.uvc-capture", qos: .userInitiated)
    private let renderContext: CIContext
    private var currentDevice: AVCaptureDevice?
    private var isRunning = false

    init(onStateChange: @escaping @MainActor (UVCVideoSourceState) -> Void) {
        (self.frames, self.framesContinuation) = AsyncStream.makeStream(
            of: UVCFrameHandoff.self, bufferingPolicy: .bufferingNewest(1))
        self.onStateChange = onStateChange
        // Intermediates are never reused across frames here, so caching them only grows the
        // working set on a path that already runs alongside the Metal feed baker's own context.
        self.renderContext = CIContext(options: [.cacheIntermediates: false])
        super.init()
    }

    // MARK: - Lifecycle

    /// Requests permission if needed, then brings the session up around whatever is attached.
    @MainActor
    func start() async {
        guard Self.isSupportedHardware else {
            onStateChange(.unsupportedDevice)
            return
        }
        guard await Self.ensureCameraAccess() else {
            onStateChange(.permissionDenied)
            return
        }
        observeDeviceChanges()
        Self.logDiscoverableVideoDevices()
        onStateChange(.starting)
        captureQueue.async { [weak self] in self?.configureAndRun() }
    }

    /// Debug-only census of every video device the system will admit to.
    ///
    /// The point of the iPhone experiment is not really "does `.external` return something" — it
    /// is whether the dongle shows up *at all*, possibly under another type, the way Mac Catalyst
    /// reports external cameras as `builtInWideAngleCamera` unless an Info.plist key opts in.
    /// "Found nothing" and "found it, filed differently" are very different answers.
    private static func logDiscoverableVideoDevices() {
        #if DEBUG
            let types: [AVCaptureDevice.DeviceType] = [
                .external, .builtInWideAngleCamera, .builtInTelephotoCamera,
                .builtInUltraWideCamera, .builtInDualCamera, .builtInDualWideCamera,
                .builtInTripleCamera, .continuityCamera,
            ]
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: types, mediaType: .video, position: .unspecified
            ).devices
            let census =
                devices
                .map { "\($0.localizedName) [\($0.deviceType.rawValue)]" }
                .joined(separator: ", ")
            print("UVC census (\(devices.count)): \(census.isEmpty ? "none" : census)")
        #endif
    }

    /// Tears the session down. Safe to call more than once, and safe to call before `start`.
    @MainActor
    func stop() {
        NotificationCenter.default.removeObserver(self)
        // Ends the consumer's `for await`, so a stopped source can never keep a loop alive.
        framesContinuation.finish()
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.isRunning = false
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.currentDevice = nil
        }
    }

    private static func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// A capture dongle is hot-pluggable and is very often plugged in *after* the operator has
    /// chosen HDMI, so attach/detach has to re-drive the session rather than being read once.
    @MainActor
    private func observeDeviceChanges() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        for name in [
            AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
        ] {
            center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.captureQueue.async { self.configureAndRun() }
            }
        }
    }

    // MARK: - Session configuration (capture queue only)

    private func configureAndRun() {
        dispatchPrecondition(condition: .onQueue(captureQueue))
        guard let device = Self.attachedCaptureDevice() else {
            if isRunning || currentDevice != nil {
                if session.isRunning { session.stopRunning() }
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                isRunning = false
                currentDevice = nil
            }
            publish(.waitingForDevice)
            return
        }
        // Already streaming from this exact device — an unrelated attach event, so leave the
        // running session alone rather than restarting it and dropping frames.
        if isRunning, currentDevice?.uniqueID == device.uniqueID { return }

        let selectedFormat: String?
        do {
            selectedFormat = try configure(for: device)
        } catch {
            publish(
                .failed(
                    reason: "The capture device couldn't be opened: \(error.localizedDescription)"))
            return
        }
        if !session.isRunning { session.startRunning() }
        isRunning = session.isRunning
        currentDevice = device
        publish(
            isRunning
                ? .streaming(deviceName: device.localizedName, format: selectedFormat)
                : .failed(reason: "The capture session didn't start."))
    }

    /// Returns a human-readable description of the format actually selected, if one was.
    @discardableResult
    private func configure(for device: AVCaptureDevice) throws -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        // The capture device's own `activeFormat` decides the resolution, not a preset ladder —
        // presets describe built-in cameras and would quietly downscale an HDMI signal.
        session.sessionPreset = .inputPriority

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw UVCError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // BGRA so the CIImage → CGImage render is a straight copy rather than a colour conversion.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // A monitor shows the newest frame or it is not a monitor: never queue behind a slow bake.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw UVCError.cannotAddOutput
        }
        session.addOutput(output)

        // AVFoundation will happily crop a capture connection on our behalf, and both mechanisms
        // are silent: video stabilization reserves a margin (~10%) to swing the frame around in,
        // and the scale-and-crop factor is a plain zoom. Neither has any business on a monitor
        // feed — the operator is judging framing, so the one guarantee that matters is that what
        // the camera sent is what reaches the screen. Set both explicitly rather than trusting the
        // defaults for an external device.
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            connection.videoScaleAndCropFactor = 1
        }

        return selectBestFormat(on: device)
    }

    /// Below this a format is a slideshow, not a monitor feed.
    private static let minimumUsableFrameRate = 24.0

    /// Frame heights to prefer when the incoming signal's own resolution is unknowable.
    ///
    /// AVFoundation exposes what the device can send over USB but never what it locked on HDMI,
    /// and capturing ABOVE the input resolution is pure upscale: it spends bandwidth on pixels
    /// that carry no detail the device ever received, and on a compressed format it takes bits
    /// away from the pixels that do. A device's largest mode is therefore only its best mode when
    /// the input is at least that large — the UGREEN's 2560×1440 is a genuine mode of its (spec:
    /// capture up to 2K@30) yet the wrong choice while the camera feeds it 1080p.
    ///
    /// Preferring broadcast standards lands on the input's own resolution in the common cases, and
    /// on this class of device the 1080p mode is additionally offered at twice the frame rate of
    /// the largest one. It stays a heuristic: the honest answer for an operator who knows their
    /// own signal chain is to pick the format explicitly. [verify-on-HW]
    private static let preferredCaptureHeights = [2160, 1080, 720]

    /// Picks the best format the device can actually feed, and returns a description of it.
    ///
    /// Three filters in order, because each one alone picks wrongly on real hardware:
    /// usable frame rate (a dongle advertises the resolutions it accepts on HDMI, not the ones it
    /// can push down USB), then a natively-produced resolution (it also advertises sizes its
    /// scaler invents), then the largest of what survives. Devices list the same resolution twice
    /// — MJPEG and uncompressed — so the final rate tiebreak lands on whichever encoding the
    /// device can sustain.
    @discardableResult
    private func selectBestFormat(on device: AVCaptureDevice) -> String? {
        let ranked = device.formats.map {
            format -> (
                format: AVCaptureDevice.Format, pixels: Int, fps: Double,
                dimensions: CMVideoDimensions
            ) in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return (format, Int(dimensions.width) * Int(dimensions.height), fps, dimensions)
        }
        #if DEBUG
            let census =
                ranked
                .map { "\($0.dimensions.width)x\($0.dimensions.height)@\(Int($0.fps.rounded()))" }
                .joined(separator: ", ")
            print("UVC formats (\(ranked.count)): \(census)")
        #endif

        // MOTION BEFORE PIXELS. Ranking on resolution alone picks whatever descriptor the device
        // advertises largest — and a capture dongle advertises the resolutions it will *accept on
        // HDMI*, not the ones it can push down USB. Selecting one of those is a good way to end up
        // holding a format the hardware never feeds, which presents as a dead or "no signal"
        // stream rather than an error. Take the largest format that can still carry motion, and
        // only fall back to the unfiltered list if the device offers nothing at rate at all.
        let usable = ranked.filter { $0.fps >= Self.minimumUsableFrameRate }
        let candidates = usable.isEmpty ? ranked : usable
        // Then prefer a resolution the incoming signal plausibly IS, over the largest the device
        // can synthesise — see `preferredCaptureHeights`. Falls through to the full list for
        // anything unusual, so a device offering only non-standard sizes still streams.
        let preferred = candidates.filter {
            Self.preferredCaptureHeights.contains(Int($0.dimensions.height))
        }
        let pool = preferred.isEmpty ? candidates : preferred
        guard
            let best = pool.max(by: { lhs, rhs in
                lhs.pixels == rhs.pixels ? lhs.fps < rhs.fps : lhs.pixels < rhs.pixels
            })
        else { return nil }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = best.format
        } catch {
            // A device that refuses configuration still streams in its default format, which is
            // a worse picture but a working one — not worth failing the whole session over.
            return nil
        }
        return "\(best.dimensions.width)×\(best.dimensions.height) @\(Int(best.fps.rounded()))"
    }

    /// The attached capture device's product name, without opening a session.
    ///
    /// Lets the connect wizard say whether the dongle is there before committing to a capture
    /// session, which on this path is the operator's whole question.
    static var attachedDeviceName: String? {
        guard isSupportedHardware else { return nil }
        return attachedCaptureDevice()?.localizedName
    }

    private static func attachedCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first
    }

    private func publish(_ state: UVCVideoSourceState) {
        Task { @MainActor [onStateChange] in onStateChange(state) }
    }

    private enum UVCError: LocalizedError {
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "the session refused the capture device"
            case .cannotAddOutput: "the session refused the video output"
            }
        }
    }

    // MARK: - Frame delivery

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        guard
            let rendered = autoreleasepool(invoking: {
                renderContext.createCGImage(source, from: source.extent)
            })
        else { return }
        framesContinuation.yield(UVCFrameHandoff(image: UIImage(cgImage: rendered)))
    }
}
