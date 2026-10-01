// The `.cube` parser and the frame-rate sampler live in OpenCineCore's OpenCineMedia product
// (moved there from this file and FrameRateSampler.swift, MEDIA-01). Scoped re-exports keep
// every core, facade, Runner and test call site unchanged without importing OpenCineMedia's
// other names, some of which (`ScopeDisplayScale`, `PortraitFeedAspect`) OpenZCine defines
// itself.

@_exported import struct OpenCineMedia.CubeLUT
@_exported import enum OpenCineMedia.CubeLUTParseError
@_exported import struct OpenCineMedia.FrameRateSampler

/// OpenZCine's renderer policy: Core Image's `CIColorCube` and the Android 8×8 slice atlas
/// both stop at 64, and a 65³ import is shown on the even 33³ lattice (lattice-exact, no
/// interpolation). OpenPocketCine resamples to 64 instead (`colorCube`); the policy stays
/// with each app.
extension CubeLUT {
    /// Edge lengths a GPU renderer can consume without resampling.
    public static let rendererSizeRange = 2...64

    /// Monitoring grid used when a parsed cube is larger than ``rendererSizeRange``.
    /// 65 = 2·32+1, so 65³ → 33³ hits every other source lattice point exactly.
    public static let rendererDisplaySize = 33

    /// The table a GPU renderer can consume. Cubes already inside ``rendererSizeRange`` are
    /// returned unchanged; a 65³ import is resampled to ``rendererDisplaySize``.
    public func preparedForRenderer() -> CubeLUT {
        Self.rendererSizeRange.contains(size) ? self : resampled(to: Self.rendererDisplaySize)
    }
}
