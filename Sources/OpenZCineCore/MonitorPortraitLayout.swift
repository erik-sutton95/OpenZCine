/// Which aspect the portrait feed renders at (operator pinch, persisted).
public enum PortraitFeedAspect: String, Codable, Equatable, Sendable {
    /// Full-width strip; whole image visible (16:9 letterboxed within the portrait width).
    case fit16x9

    /// Fills topBar→systemBar; center-crop zoom.
    case fill
}

/// Portrait monitor geometry the live chrome reads.
public enum MonitorPortraitLayout {
    /// Height of the fill-mode controls strip (capture bar).
    public static let captureBarHeight = 64.0
}
