import Testing

@testable import OpenZCineCore

@Test func storedLUTDisplayNameDropsCubeExtension() {
    #expect(StoredLUT(fileName: "MyLook.cube").displayName == "MyLook")
    #expect(StoredLUT(fileName: "Bleach.CUBE").displayName == "Bleach")
    #expect(StoredLUT(fileName: "weird").displayName == "weird")
}

@Test func defaultRedLUTPrefersRec709MediumContrastThenFallsBack() {
    let set = [
        StoredLUT(fileName: "RED_FilmBias_N-Log_to_Rec709.cube"),
        StoredLUT(fileName: "N-Log_REC709_HIGH_CONTRAST.cube"),
        StoredLUT(fileName: "N-Log_REC709_MEDIUM_CONTRAST.cube"),
    ]
    #expect(
        LUTLibraryIndex.defaultRedLUT(from: set)?.fileName == "N-Log_REC709_MEDIUM_CONTRAST.cube")
    #expect(
        LUTLibraryIndex.defaultRedLUT(from: [StoredLUT(fileName: "A.cube")])?.fileName == "A.cube")
    #expect(LUTLibraryIndex.defaultRedLUT(from: []) == nil)
}

@Test func defaultRedLUTPrefersMediumContrastSoftRolloffRec709() {
    let set = [
        StoredLUT(
            fileName:
                "RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and R_1_Hard size_33 v1.13.cube"),
        StoredLUT(
            fileName:
                "RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and R_4_VerySoft size_33 v1.13.cube"
        ),
        StoredLUT(
            fileName:
                "RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and R_3_Soft size_33 v1.13.cube"),
        StoredLUT(
            fileName:
                "RWG_Log3G10 to REC2020_BT1886 with MEDIUM_CONTRAST and R_3_Soft size_33 v1.13.cube"
        ),
    ]
    #expect(
        LUTLibraryIndex.defaultRedLUT(from: set)?.fileName
            == "RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and R_3_Soft size_33 v1.13.cube")
}

@Test func libraryIndexKeepsOnlyCubesSortedCaseInsensitively() {
    let names = ["b.cube", "A.cube", "notes.txt", "C.CUBE", "sub/dir"]
    let stored = LUTLibraryIndex.stored(fromFileNames: names)
    #expect(stored.map(\.fileName) == ["A.cube", "b.cube", "C.CUBE"])
}

@Test func redPresetNameDropsSourceContrastWordsSizeAndVersion() {
    // Real RED IPP2 names: ".../<output>_BT1886 with <contrast>_CONTRAST and R_<n>_<rolloff>
    // size_33 v1.13.cube". Keep output · contrast · rolloff; drop the shared source, "_CONTRAST",
    // the R_n index, and the size/version metadata.
    #expect(
        RedPresetName.short(
            "RWG_Log3G10 to REC2020_BT1886 with HIGH_CONTRAST and R_1_Hard size_33 v1.13.cube")
            == "Rec.2020 · High · Hard")
    #expect(
        RedPresetName.short(
            "RWG_Log3G10 to REC709_BT1886 with NO_CONTRAST and R_3_Soft size_33 v1.13.cube")
            == "Rec.709 · No · Soft")
}

@Test func redPresetNameSplitsCamelCasedRolloff() {
    #expect(
        RedPresetName.short(
            "RWG_Log3G10 to REC709_BT1886 with MEDIUM_CONTRAST and R_4_VerySoft size_33 v1.13.cube")
            == "Rec.709 · Medium · Very soft")
}

@Test func redPresetNameFallsBackForUnpatternedNames() {
    #expect(RedPresetName.short("My Custom Look.cube") == "My Custom Look")
}
