#if targetEnvironment(macCatalyst) || MAC_VIRTUAL_CAMERA_TESTING
    import CoreImage
    import CoreMedia
    import CoreMediaIO
    import CoreVideo
    import Observation
    #if targetEnvironment(macCatalyst)
        import UIKit
    #endif
    import Foundation
    import os

    /// One retained pending frame. Capture never waits for the consumer or rendering queue.
    final class MacVirtualCameraMailbox<Frame>: @unchecked Sendable {
        struct Snapshot {
            let replaced: UInt64
            let rejected: UInt64
        }
        struct Entry {
            let frame: Frame
            let generation: UInt64
        }
        private let lock = NSLock()
        private var enabled = false
        private var generation: UInt64 = 0
        private var sourceGeneration: UInt64 = 0
        private var pending: Entry?
        private var replaced: UInt64 = 0
        private var rejected: UInt64 = 0

        var snapshot: Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(replaced: replaced, rejected: rejected)
        }

        var currentGeneration: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return sourceGeneration
        }

        @discardableResult func setEnabled(_ enabled: Bool) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            self.enabled = enabled
            generation &+= 1
            pending = nil
            return sourceGeneration
        }

        @discardableResult func resetSource() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            sourceGeneration &+= 1
            pending = nil
            return sourceGeneration
        }

        func offer(_ frame: Frame, generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard enabled, generation == sourceGeneration else {
                rejected &+= 1
                return
            }
            if pending != nil { replaced &+= 1 }
            pending = Entry(frame: frame, generation: self.generation)
        }

        func take(canConsume: Bool) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            guard enabled, canConsume else { return nil }
            let entry = pending
            pending = nil
            return entry
        }

        /// Fence the final short enqueue against concurrent disable/source replacement.
        func withAdmission(generation: UInt64, _ body: () -> Void) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard enabled, generation == self.generation else { return false }
            body()
            return true
        }
    }

    struct MacVirtualCameraTimeline {
        private var offset: CMTime?
        private var lastSource: CMTime?

        mutating func reset() {
            offset = nil
            lastSource = nil
        }

        mutating func map(_ timestamp: CMTime, hostNow: CMTime) -> CMTime? {
            guard timestamp.isNumeric, hostNow.isNumeric else { return nil }
            if let lastSource, CMTimeCompare(timestamp, lastSource) <= 0 { return nil }
            if offset == nil {
                // Preserve native host-clock capture timestamps; map other source clocks once.
                offset =
                    abs(CMTimeGetSeconds(CMTimeSubtract(timestamp, hostNow))) < 5
                    ? .zero : CMTimeSubtract(hostNow, timestamp)
            }
            lastSource = timestamp
            return CMTimeAdd(timestamp, offset ?? .zero)
        }
    }

    /// Catalyst producer for the native camera extension. It never captures a camera itself.
    @MainActor @Observable final class MacVirtualCamera {
        static let shared = MacVirtualCamera()
        private(set) var isEnabled = false
        private(set) var statusText = "Virtual webcam off"
        @ObservationIgnored private nonisolated let publisher = MacVirtualCameraPublisher()

        private init() {
            publisher.report = { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.statusText = status
                }
            }
        }

        func setEnabled(_ enabled: Bool) {
            guard enabled != isEnabled else { return }
            isEnabled = enabled
            statusText = enabled ? "Looking for OpenZCine virtual camera" : "Virtual webcam off"
            publisher.setEnabled(enabled)
            guard enabled else { return }
            publisher.findInstalled { [weak self] installed in
                guard !installed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.openCompanion()
                }
            }
        }

        /// Retire callbacks from a previous input. Capture the returned token in the new source.
        @discardableResult nonisolated func resetSource() -> UInt64 {
            publisher.resetSource()
        }

        /// Use when the upstream owner already fences retired source callbacks.
        nonisolated func submit(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
            publisher.submit(pixelBuffer, timestamp: timestamp, generation: nil)
        }

        /// The explicit token rejects late GPU/capture callbacks from a retired source.
        nonisolated func submit(
            _ pixelBuffer: CVPixelBuffer, timestamp: CMTime, sourceGeneration: UInt64
        ) {
            publisher.submit(pixelBuffer, timestamp: timestamp, generation: sourceGeneration)
        }

        /// Publish an immutable native image graph after the shared look is applied.
        nonisolated func submit(
            _ image: CIImage, timestamp: CMTime, sourceGeneration: UInt64
        ) {
            publisher.submit(image, timestamp: timestamp, generation: sourceGeneration)
        }

        private func openCompanion() {
            #if targetEnvironment(macCatalyst)
                guard let url = URL(string: "openzcine-camera-host://setup") else { return }
                UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                    Task { @MainActor [weak self] in
                        guard let self, self.isEnabled else { return }
                        self.statusText =
                            opened
                            ? "Approve OpenZCine Camera Host in System Settings to install the webcam"
                            : "Install OpenZCine Camera Host in Applications, then enable the webcam"
                    }
                }
            #endif
        }
    }

    /// All CMIO, Core Image and pool state belongs to `worker`; the mailbox alone crosses queues.
    private final class MacVirtualCameraPublisher: @unchecked Sendable {
        enum Picture {
            case pixelBuffer(CVPixelBuffer)
            case image(CIImage)
        }
        struct Frame {
            let picture: Picture
            let timestamp: CMTime
        }
        var report: (@Sendable (String) -> Void)?
        private let worker = DispatchQueue(
            label: "org.opencapture.openzcine.webcam", qos: .userInitiated)
        private let mailbox = MacVirtualCameraMailbox<Frame>()
        private let converter = MacVirtualCameraConverter()
        private let log = Logger(subsystem: "com.opencapture.openzcine", category: "virtual-camera")
        private let signposter = OSSignposter(
            subsystem: "com.opencapture.openzcine", category: "virtual-camera")
        private var timer: DispatchSourceTimer?
        private var connection: MacVirtualCameraSink?
        private var timeline = MacVirtualCameraTimeline()
        private var activeGeneration: UInt64?
        private var lastDiscovery: UInt64 = 0
        private var lastReport: UInt64 = 0
        private var lastDiagnostics: UInt64 = 0
        private var lastSourceHostTime: CMTime?
        private var published: UInt64 = 0
        private var queueFull: UInt64 = 0
        private var poolExhausted: UInt64 = 0
        private var malformed: UInt64 = 0

        func setEnabled(_ enabled: Bool) {
            mailbox.setEnabled(enabled)
            worker.async { [self] in
                stop()
                guard enabled else { return }
                let timer = DispatchSource.makeTimerSource(queue: worker)
                timer.schedule(
                    deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in
                    autoreleasepool { self?.tick() }
                }
                self.timer = timer
                timer.resume()
            }
        }

        func findInstalled(_ result: @escaping @Sendable (Bool) -> Void) {
            worker.async { result(MacVirtualCameraSink.find() != nil) }
        }

        func resetSource() -> UInt64 {
            let generation = mailbox.resetSource()
            worker.async { [self] in
                connection?.stop()
                connection = nil
                activeGeneration = nil
                timeline.reset()
                lastSourceHostTime = nil
                lastDiscovery = 0
            }
            return generation
        }

        func submit(_ image: CVPixelBuffer, timestamp: CMTime, generation: UInt64?) {
            mailbox.offer(
                Frame(picture: .pixelBuffer(image), timestamp: timestamp),
                generation: generation ?? mailbox.currentGeneration)
        }

        func submit(_ image: CIImage, timestamp: CMTime, generation: UInt64) {
            mailbox.offer(
                Frame(picture: .image(image), timestamp: timestamp), generation: generation)
        }

        private func stop() {
            timer?.cancel()
            timer = nil
            connection?.stop()
            connection = nil
            activeGeneration = nil
            timeline.reset()
            lastSourceHostTime = nil
            lastDiscovery = 0
            lastReport = 0
            converter.reset()
        }

        private func tick() {
            let now = DispatchTime.now().uptimeNanoseconds
            if connection == nil {
                guard now - lastDiscovery >= 1_000_000_000 else { return }
                lastDiscovery = now
                do { connection = try MacVirtualCameraSink.connect() } catch {
                    report?(error.localizedDescription)
                    return
                }
            }
            guard let connection else { return }
            guard connection.isPresent else {
                connection.stop()
                self.connection = nil
                report?("Virtual camera disconnected; waiting for OpenZCine Camera Host")
                return
            }
            let available = connection.hasSpace
            if !available { queueFull &+= 1 }
            if let entry = mailbox.take(canConsume: available) {
                publish(entry, to: connection)
            }
            if now - lastReport >= 1_000_000_000 {
                lastReport = now
                let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
                let hasPicture =
                    lastSourceHostTime.map {
                        CMTimeGetSeconds(CMTimeSubtract(hostNow, $0)) < 1
                    } ?? false
                report?(
                    hasPicture
                        ? "Virtual webcam publishing at 1080p"
                        : "Virtual webcam ready; waiting for picture")
            }
            if now - lastDiagnostics >= 10_000_000_000 {
                lastDiagnostics = now
                let counters = mailbox.snapshot
                log.info(
                    "sent=\(self.published) replaced=\(counters.replaced) busy=\(self.queueFull) pool=\(self.poolExhausted) rejected=\(counters.rejected + self.malformed); receiver delivery unmeasured"
                )
            }
        }

        private func publish(
            _ entry: MacVirtualCameraMailbox<Frame>.Entry, to connection: MacVirtualCameraSink
        ) {
            let interval = signposter.beginInterval("WebcamPublish")
            defer { signposter.endInterval("WebcamPublish", interval) }
            if activeGeneration != entry.generation {
                activeGeneration = entry.generation
                timeline.reset()
            }
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            guard let timestamp = timeline.map(entry.frame.timestamp, hostNow: hostNow) else {
                malformed &+= 1
                return
            }
            let converted: CVPixelBuffer?
            switch entry.frame.picture {
            case .pixelBuffer(let buffer): converted = converter.convert(buffer)
            case .image(let image): converted = converter.convert(image)
            }
            guard let image = converted else {
                poolExhausted &+= 1
                return
            }
            var format: CMVideoFormatDescription?
            guard
                CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault, imageBuffer: image,
                    formatDescriptionOut: &format
                ) == noErr, let format
            else { return }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: timestamp,
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
                    sampleTiming: &timing, sampleBufferOut: &sample
                ) == noErr, let sample
            else { return }
            _ = mailbox.withAdmission(generation: entry.generation) {
                if connection.enqueue(sample) {
                    published &+= 1
                    lastSourceHostTime = hostNow
                } else {
                    queueFull &+= 1
                }
            }
        }
    }

    /// A four-buffer IOSurface pool bounds conversion memory even if CMIO retains frames.
    final class MacVirtualCameraConverter {
        private var pool: CVPixelBufferPool?
        private let context = CIContext(options: [
            .workingFormat: CIFormat.BGRA8,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: false,
        ])
        private let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        private let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        func reset() { pool = nil }

        func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            if CVPixelBufferGetWidth(source) == 1_920,
                CVPixelBufferGetHeight(source) == 1_080,
                CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
                CVPixelBufferGetIOSurface(source) != nil
            {
                return source
            }
            guard let output = convert(CIImage(cvPixelBuffer: source)) else { return nil }
            CVBufferPropagateAttachments(source, output)
            return output
        }

        func convert(_ input: CIImage) -> CVPixelBuffer? {
            guard !input.extent.isInfinite, !input.extent.isEmpty else { return nil }
            if pool == nil {
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 1_920,
                    kCVPixelBufferHeightKey as String: 1_080,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
                guard
                    CVPixelBufferPoolCreate(
                        kCFAllocatorDefault, nil, attributes as CFDictionary, &pool
                    ) == kCVReturnSuccess
                else { return nil }
            }
            guard let pool else { return nil }
            var output: CVPixelBuffer?
            let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
            guard
                CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault, pool, limits, &output
                ) == kCVReturnSuccess, let output
            else { return nil }
            guard input.extent.width > 0, input.extent.height > 0 else { return nil }
            let scale = min(bounds.width / input.extent.width, bounds.height / input.extent.height)
            let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(
                by: CGAffineTransform(
                    translationX: bounds.midX - scaled.extent.midX,
                    y: bounds.midY - scaled.extent.midY))
            let image = centered.composited(over: CIImage(color: .black).cropped(to: bounds))
            // This synchronous render returns after the output is usable by another process.
            context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
            return output
        }
    }

    private enum MacVirtualCameraError: LocalizedError {
        case unavailable
        case operation(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return
                    "OpenZCine virtual camera unavailable; install or approve OpenZCine Camera Host"
            case .operation(let operation, let code):
                return
                    "Virtual webcam \(operation) failed (\(code)); check Camera Host permission and installation"
            }
        }
    }

    /// CMSimpleQueue does not retain elements. Successful enqueue transfers one retain to CMIO.
    final class MacVirtualCameraSampleQueue {
        private let queue: CMSimpleQueue
        init(_ queue: CMSimpleQueue) { self.queue = queue }
        var hasSpace: Bool { CMSimpleQueueGetCount(queue) == 0 }
        func enqueue(_ sample: CMSampleBuffer) -> Bool {
            guard hasSpace else { return false }
            let retained = Unmanaged.passRetained(sample)
            let result = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
            if result != noErr { retained.release() }
            return result == noErr
        }
    }

    private final class MacVirtualCameraSink {
        private static let deviceUIDs: Set<String> = [
            "OpenZCine.VirtualCamera", "99AF34B4-61A6-4B31-A31B-A9808A147FF0",
        ]
        private static let sinkName = "OpenZCine.VirtualCamera.sink"
        private static let discoveryLog = Logger(
            subsystem: "com.opencapture.openzcine", category: "cmio-discovery")
        private static let discoveryTraceTime = OSAllocatedUnfairLock(initialState: UInt64(0))
        private let device: CMIODeviceID
        private let stream: CMIOStreamID
        private let queue: MacVirtualCameraSampleQueue
        private var started = true

        private init(device: CMIODeviceID, stream: CMIOStreamID, queue: CMSimpleQueue) {
            self.device = device
            self.stream = stream
            self.queue = MacVirtualCameraSampleQueue(queue)
        }

        var hasSpace: Bool { queue.hasSpace }
        var isPresent: Bool {
            guard let uid = Self.stringProperty(device, selector: kCMIODevicePropertyDeviceUID)
            else { return false }
            return Self.deviceUIDs.contains(uid)
        }

        static func find() -> (CMIODeviceID, CMIOStreamID)? {
            let now = DispatchTime.now().uptimeNanoseconds
            let trace = discoveryTraceTime.withLock { last in
                guard now - last >= 5_000_000_000 else { return false }
                last = now
                return true
            }
            let devices = ids(
                CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices,
                trace: trace)
            if trace {
                discoveryLog.notice(
                    "[DEBUG-CMIO-DISCOVERY] pid=\(getpid(), privacy: .public) deviceCount=\(devices.count, privacy: .public)"
                )
            }
            for device in devices {
                let uid = stringProperty(
                    device, selector: kCMIODevicePropertyDeviceUID, trace: trace)
                if trace {
                    let name = stringProperty(
                        device, selector: kCMIOObjectPropertyName, trace: true)
                    discoveryLog.notice(
                        "[DEBUG-CMIO-DISCOVERY] device=\(device, privacy: .public) uid=\(uid ?? "nil", privacy: .public) name=\(name ?? "nil", privacy: .public)"
                    )
                }
                guard uid.map(deviceUIDs.contains) ?? false else { continue }
                let streams = ids(device, selector: kCMIODevicePropertyStreams, trace: trace)
                for stream in streams {
                    var address = property(kCMIOStreamPropertyDirection)
                    var direction: UInt32 = 1
                    var size = UInt32(MemoryLayout<UInt32>.size)
                    let result = CMIOObjectGetPropertyData(
                        stream, &address, 0, nil, size, &size, &direction)
                    let name = stringProperty(
                        stream, selector: kCMIOObjectPropertyName, trace: trace)
                    if trace {
                        discoveryLog.notice(
                            "[DEBUG-CMIO-DISCOVERY] stream=\(stream, privacy: .public) directionStatus=\(result, privacy: .public) direction=\(direction, privacy: .public) name=\(name ?? "nil", privacy: .public)"
                        )
                    }
                    guard result == noErr, direction == 0, name == sinkName else { continue }
                    if trace {
                        discoveryLog.notice(
                            "[DEBUG-CMIO-DISCOVERY] matched device=\(device, privacy: .public) stream=\(stream, privacy: .public)"
                        )
                    }
                    return (device, stream)
                }
            }
            if trace { discoveryLog.notice("[DEBUG-CMIO-DISCOVERY] no exact device/sink match") }
            return nil
        }

        static func connect() throws -> MacVirtualCameraSink {
            guard let (device, stream) = find() else { throw MacVirtualCameraError.unavailable }
            var address = property(kCMIOStreamPropertyOutputBufferQueueSize)
            var count: UInt32 = 1
            _ = CMIOObjectSetPropertyData(
                stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &count)
            // Keep the sink's declared producer mode aligned with the 60 Hz bounded handoff.
            // The extension independently negotiates 30/60 Hz delivery with each receiver.
            var rate = 60.0
            address = property(kCMIOStreamPropertyFrameRate)
            let configured = CMIOObjectSetPropertyData(
                stream, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
            guard configured == noErr else {
                throw MacVirtualCameraError.operation("60 fps sink format", configured)
            }
            var bufferQueue: Unmanaged<CMSimpleQueue>?
            let copied = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &bufferQueue)
            guard copied == noErr, let bufferQueue else {
                throw MacVirtualCameraError.operation("queue connection", copied)
            }
            let queue = bufferQueue.takeRetainedValue()
            let started = CMIODeviceStartStream(device, stream)
            guard started == noErr else {
                throw MacVirtualCameraError.operation("producer start", started)
            }
            return MacVirtualCameraSink(device: device, stream: stream, queue: queue)
        }

        func enqueue(_ sample: CMSampleBuffer) -> Bool {
            guard started, hasSpace else { return false }
            return queue.enqueue(sample)
        }

        func stop() {
            guard started else { return }
            started = false
            _ = CMIODeviceStopStream(device, stream)
        }

        private static func property(_ selector: Int) -> CMIOObjectPropertyAddress {
            CMIOObjectPropertyAddress(
                mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                mElement: UInt32(kCMIOObjectPropertyElementMain))
        }

        private static func ids(
            _ object: CMIOObjectID, selector: Int, trace: Bool = false
        ) -> [CMIOObjectID] {
            var address = property(selector)
            var size: UInt32 = 0
            let sizeStatus = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
            if trace {
                discoveryLog.notice(
                    "[DEBUG-CMIO-DISCOVERY] ids size object=\(object, privacy: .public) selector=\(selector, privacy: .public) status=\(sizeStatus, privacy: .public) bytes=\(size, privacy: .public)"
                )
            }
            guard sizeStatus == noErr, size > 0, size <= 65_536 else { return [] }
            var result = [CMIOObjectID](
                repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
            let status = result.withUnsafeMutableBytes { bytes in
                CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, bytes.baseAddress)
            }
            if trace {
                discoveryLog.notice(
                    "[DEBUG-CMIO-DISCOVERY] ids data object=\(object, privacy: .public) selector=\(selector, privacy: .public) status=\(status, privacy: .public) bytes=\(size, privacy: .public) count=\(result.count, privacy: .public)"
                )
            }
            return status == noErr ? result : []
        }

        private static func stringProperty(
            _ object: CMIOObjectID, selector: Int, trace: Bool = false
        ) -> String? {
            var address = property(selector)
            var result: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &result)
            if trace {
                discoveryLog.notice(
                    "[DEBUG-CMIO-DISCOVERY] string object=\(object, privacy: .public) selector=\(selector, privacy: .public) status=\(status, privacy: .public) bytes=\(size, privacy: .public) hasValue=\(result != nil, privacy: .public)"
                )
            }
            guard status == noErr, let result else { return nil }
            return result.takeRetainedValue() as String
        }
    }
#endif
