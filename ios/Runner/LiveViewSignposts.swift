import os

/// Lightweight `os_signpost` markers for Instruments — filter the LiveView category in Points of
/// Interest to separate display readback from Metal presentation and scope work.
enum LiveViewSignposts {
    private static let log = OSLog(subsystem: "OpenZCine", category: "LiveView")

    static func beginCreateCGImageReadback() {
        os_signpost(.begin, log: log, name: "createCGImageReadback")
    }

    static func endCreateCGImageReadback() {
        os_signpost(.end, log: log, name: "createCGImageReadback")
    }

    static func beginMetalFeedPresent() {
        os_signpost(.begin, log: log, name: "MetalFeedPresent")
    }

    static func endMetalFeedPresent() {
        os_signpost(.end, log: log, name: "MetalFeedPresent")
    }

    static func beginScopeScatterPresent() {
        os_signpost(.begin, log: log, name: "ScopeScatterPresent")
    }

    static func endScopeScatterPresent() {
        os_signpost(.end, log: log, name: "ScopeScatterPresent")
    }
}
