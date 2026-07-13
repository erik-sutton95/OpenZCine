import Foundation

/// In-memory index built while listing camera clips — pairs proxy MP4/MOV files with sibling R3D
/// masters by filename stem.
public struct R3DClipIndex: Sendable {
    /// One R3D master discovered on the card.
    public struct Sibling: Sendable, Equatable {
        public let filename: String
        public let width: UInt32
        public let height: UInt32

        public init(filename: String, width: UInt32, height: UInt32) {
            self.filename = filename
            self.width = width
            self.height = height
        }
    }

    private var siblingsByStem: [String: Sibling] = [:]
    private var proxyStems: Set<String> = []

    public init() {}

    public mutating func registerR3D(filename: String, width: UInt32, height: UInt32) {
        let stem = MediaClipFilename.stem(of: filename)
        siblingsByStem[stem] = Sibling(filename: filename, width: width, height: height)
    }

    public mutating func noteProxy(_ filename: String) {
        proxyStems.insert(MediaClipFilename.stem(of: filename))
    }

    public func siblingForProxy(_ proxyFilename: String) -> Sibling? {
        siblingsByStem[MediaClipFilename.stem(of: proxyFilename)]
    }

    public func hasProxy(forR3DFilename filename: String) -> Bool {
        proxyStems.contains(MediaClipFilename.stem(of: filename))
    }
}
