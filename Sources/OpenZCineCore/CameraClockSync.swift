import Foundation

/// Decides whether a freshly connected body's clock should be set to the phone's.
///
/// A camera's clock is set once in a drawer and drifts forever; the phone's is network-disciplined.
/// The bodies this app drives can derive time-of-day timecode from that clock, so a drifted body
/// quietly stamps every take with the wrong time — and a field report asked whether the app syncs
/// it "automatically or with a toggle", to which the honest answer was "neither".
///
/// Automatic, deliberately, with two hard limits instead of a preference:
/// - **Never while recording.** Time-of-day timecode derives from this clock, and a mid-take
///   clock step is a mid-take timecode step.
/// - **Only past a real threshold.** Transaction latency plus the one-second granularity of the
///   wire format makes sub-threshold corrections flappy; five seconds is beyond any monitoring
///   use of the clock but catches every drawer-drifted body on its first connect.
///
/// The comparison is WALL clock to WALL clock. The camera's value carries no zone, so the only
/// meaningful comparison is against the phone's local wall time — which also means a body carried
/// across a timezone syncs to local time on first connect, exactly what an operator expects.
///
/// Pure and payload-in, payload-out, so the platforms' only job is one read, one call, and at
/// most one write at session bootstrap — after the record state is known, once per session.
public enum CameraClockSync {
    /// Drift at or under this many seconds is left alone.
    public static let driftToleranceSeconds = 5

    /// The phone's local wall clock, pre-split so the decision needs no Calendar and stays
    /// deterministic under test.
    public struct WallClock: Equatable, Sendable {
        public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
        }

        public let year: Int
        public let month: Int
        public let day: Int
        public let hour: Int
        public let minute: Int
        public let second: Int

        /// "YYYYMMDDThhmmss" — the wire shape the clock property speaks.
        var wireString: String {
            String(
                format: "%04d%02d%02dT%02d%02d%02d",
                year, month, day, hour, minute, second)
        }

        /// Days-since-epoch × 86400 + seconds-of-day, for drift arithmetic across midnight and
        /// month boundaries without a Calendar. Proleptic-Gregorian day number; both sides of a
        /// comparison use the same rule, so only the difference matters.
        var absoluteSeconds: Int {
            let a = (14 - month) / 12
            let y = year + 4800 - a
            let m = month + 12 * a - 3
            let dayNumber =
                day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
            return dayNumber * 86_400 + hour * 3_600 + minute * 60 + second
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Set the body's clock: the encoded property payload to write.
        case write(Data)
        /// Within tolerance; nothing to do.
        case inSync
        /// The body is recording; its clock is not ours to step mid-take.
        case recordingHoldOff
        /// The camera's value did not parse; writing on top of a misparse is how a body ends up
        /// set to a nonsense time, so an unreadable clock is never written.
        case unreadable
    }

    /// One decision per session, made at property bootstrap once the record state is known.
    public static func decide(
        cameraPayload: Data, phoneNow: WallClock, isRecording: Bool
    ) -> Decision {
        guard let camera = parse(payload: cameraPayload) else { return .unreadable }
        if isRecording { return .recordingHoldOff }
        let drift = abs(camera.absoluteSeconds - phoneNow.absoluteSeconds)
        guard drift > driftToleranceSeconds else { return .inSync }
        return .write(encode(phoneNow))
    }

    /// The camera's clock as a wall clock, from the property's PTP-string payload.
    static func parse(payload: Data) -> WallClock? {
        let bytes = Array(payload)
        guard let first = bytes.first else { return nil }
        let characterCount = Int(first)
        guard characterCount > 0, bytes.count >= 1 + characterCount * 2 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(characterCount)
        for index in 0..<characterCount {
            units.append(ByteCoding.readUInt16LE(bytes, at: 1 + index * 2))
        }
        if units.last == 0 { units.removeLast() }
        let value = String(decoding: units, as: UTF16.self)
        // "YYYYMMDDThhmmss", with any sub-second suffix ignored — one-second granularity is all
        // the tolerance arithmetic uses.
        guard value.count >= 15 else { return nil }
        let scalars = Array(value.prefix(15))
        guard scalars[8] == "T" else { return nil }
        func int(_ range: Range<Int>) -> Int? {
            Int(String(scalars[range.lowerBound..<range.upperBound]))
        }
        guard
            let year = int(0..<4), let month = int(4..<6), let day = int(6..<8),
            let hour = int(9..<11), let minute = int(11..<13), let second = int(13..<15),
            (1..<13).contains(month), (1..<32).contains(day),
            (0..<24).contains(hour), (0..<60).contains(minute), (0..<61).contains(second)
        else { return nil }
        return WallClock(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// The phone's wall clock as the property's PTP-string payload.
    ///
    /// Public because the WRITE happens later than the DECISION: the decision runs at property
    /// bootstrap, but the record state is only authoritative once live view delivers a frame
    /// header, so the platforms defer the write to their first steady-state poll tick — and
    /// re-encode the phone's clock THERE. Writing the payload stashed at decision time would set
    /// the body's clock slow by however long the gap took.
    public static func encode(_ clock: WallClock) -> Data {
        var data = Data()
        let units = Array(clock.wireString.utf16) + [0]
        data.append(UInt8(units.count))
        for unit in units {
            data.append(contentsOf: ByteCoding.uint16LE(unit))
        }
        return data
    }

    /// The phone's current local wall clock. Split out so the decision itself stays pure.
    public static func phoneNow(date: Date = Date(), calendar: Calendar = .current) -> WallClock {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return WallClock(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0,
            hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0)
    }
}
