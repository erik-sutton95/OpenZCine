import Foundation

/// A `.cube` LUT stored in the app's library — an imported file (or, later, a downloaded one).
public struct StoredLUT: Equatable, Sendable, Identifiable {
    /// On-disk file name, e.g. `MyLook.cube`.
    public let fileName: String

    public init(fileName: String) {
        self.fileName = fileName
    }

    /// Human-readable label — the file name without its `.cube` extension.
    public var displayName: String {
        fileName.lowercased().hasSuffix(".cube") ? String(fileName.dropLast(5)) : fileName
    }

    public var id: String { fileName }
}

/// Pure indexing for a LUT library directory. The file I/O itself is the shell's job (storage is
/// platform-owned); turning a directory's file names into a sorted, filtered `StoredLUT` list is
/// portable and testable here.
public enum LUTLibraryIndex {
    /// Keeps only `.cube` entries and sorts them case-insensitively by file name.
    public static func stored(fromFileNames names: [String]) -> [StoredLUT] {
        names
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted { $0.lowercased() < $1.lowercased() }
            .map { StoredLUT(fileName: $0) }
    }

    /// A sensible default from a freshly-imported RED set: REC.709, medium contrast, soft highlight
    /// rolloff — the canonical monitor look — then progressively looser fallbacks.
    public static func defaultRedLUT(from luts: [StoredLUT]) -> StoredLUT? {
        func has(_ lut: StoredLUT, _ needle: String) -> Bool {
            lut.fileName.uppercased().contains(needle)
        }
        let rec709 = luts.filter { has($0, "REC709") || has($0, "REC.709") }
        let medium = rec709.filter { has($0, "MEDIUM_CONTRAST") || has($0, "MEDIUM CONTRAST") }
        // Prefer the plain "Soft" rolloff (RED's R_3), not "VerySoft" (R_4).
        let softMedium = medium.first { has($0, "SOFT") && !has($0, "VERYSOFT") }
        return softMedium ?? medium.first ?? rec709.first ?? luts.first
    }
}

/// Compact labels for RED's verbose IPP2 preset file names, e.g.
/// `RWG_Log3G10 to REC2020_BT1886 with HIGH_CONTRAST and MEDIUM_SOFT_HIGHLIGHT.cube`
/// → `Rec.2020 · High · Medium soft`. Every IPP2 preset shares the `RWG_Log3G10 to …` source
/// transform, so it's dropped; the output color space, contrast, and highlight roll-off are kept
/// and tidied. Falls back to the bare stem when a name doesn't match the pattern.
public enum RedPresetName {
    public static func short(_ fileName: String) -> String {
        var stem = fileName
        if stem.lowercased().hasSuffix(".cube") { stem = String(stem.dropLast(5)) }
        // Drop the source transform prefix (`RWG_Log3G10 to `) — common to every preset.
        if let toRange = stem.range(of: " to ") {
            stem = String(stem[toRange.upperBound...])
        }
        let segments = stem.components(separatedBy: " with ")
        let output = prettyOutput(segments[0])
        guard segments.count > 1 else { return output.isEmpty ? stem : output }
        let look =
            segments[1]
            .components(separatedBy: " and ")
            .map(prettyLook)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if output.isEmpty { return look.isEmpty ? stem : look }
        return look.isEmpty ? output : "\(output) · \(look)"
    }

    /// `REC2020_BT1886` → `Rec.2020`; `REC2020_BT2020_PQ` → `Rec.2020 PQ`. Standard SDR display
    /// curves are implied and dropped; non-standard ones (PQ/HLG) are kept.
    private static func prettyOutput(_ raw: String) -> String {
        var parts: [String] = []
        for token in raw.components(separatedBy: "_") {
            switch token.uppercased() {
            case "REC709": parts.append("Rec.709")
            case "REC2020": parts.append("Rec.2020")
            case "REC601": parts.append("Rec.601")
            case "BT1886", "BT2020", "GAMMA24", "": break
            case "PQ": parts.append("PQ")
            case "HLG": parts.append("HLG")
            default: parts.append(token.capitalized)
            }
        }
        return parts.joined(separator: " ")
    }

    /// `HIGH_CONTRAST` → `High`; `R_1_Hard size_33 v1.13` → `Hard`; `R_4_VerySoft …` → `Very soft`.
    /// Drops the redundant `contrast`/`highlight` words, RED's `R_<n>` rolloff index, and the shared
    /// `size_<n> v<x>` metadata, then tidies the remaining descriptor.
    private static func prettyLook(_ raw: String) -> String {
        // Drop the trailing `size_33 v1.13` metadata common to every preset.
        var segment = raw
        if let sizeRange = segment.range(of: " size", options: .caseInsensitive) {
            segment = String(segment[..<sizeRange.lowerBound])
        }
        let descriptors =
            segment
            .split(whereSeparator: { $0 == "_" || $0 == " " })
            .map(String.init)
            .filter { word in
                let lower = word.lowercased()
                return lower != "contrast" && lower != "highlight" && lower != "r"
                    && Int(word) == nil
            }
            .map(normalizeWord)
        return descriptors.joined(separator: " ")
    }

    /// `HIGH` → `High` (sentence-case an all-caps token); `VerySoft` → `Very soft` (split camel
    /// case); `Hard` → `Hard`.
    private static func normalizeWord(_ word: String) -> String {
        if word == word.uppercased() {
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        var spaced = ""
        for (index, character) in word.enumerated() {
            if index > 0 && character.isUppercase { spaced += " " }
            spaced.append(index > 0 ? Character(character.lowercased()) : character)
        }
        return spaced
    }
}
