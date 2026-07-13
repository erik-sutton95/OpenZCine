import Foundation
import Testing

@testable import OpenZCineCore

@Test func deviceInfoParserExtractsIdentityStrings() throws {
    var bytes: [UInt8] = [
        100, 0,  // StandardVersion
        10, 0, 0, 0,  // VendorExtensionID
        100, 0,  // VendorExtensionVersion
    ]
    bytes.append(contentsOf: ptpString(""))
    bytes.append(contentsOf: [
        0, 0,  // FunctionalMode
    ])
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: ptpString("Nikon"))
    bytes.append(contentsOf: ptpString("ZR"))
    bytes.append(contentsOf: ptpString("1.0"))
    bytes.append(contentsOf: ptpString("ABC123"))

    let info = try PTPDeviceInfo(data: Data(bytes))

    #expect(info.manufacturer == "Nikon")
    #expect(info.model == "ZR")
    #expect(info.deviceVersion == "1.0")
    #expect(info.serialNumber == "ABC123")
}

@Test func cameraDisplayNamePrefersCameraAssignedName() {
    let displayName = CameraDisplayNamePolicy.displayName(
        cameraName: "ZR_6001234",
        manufacturer: "Nikon Corporation",
        model: "ZR"
    )

    #expect(displayName == "ZR_6001234")
}

@Test func cameraDisplayNameNormalizesNikonCorporationFallback() {
    let displayName = CameraDisplayNamePolicy.displayName(
        cameraName: "",
        manufacturer: "Nikon Corporation",
        model: "ZR"
    )

    #expect(displayName == "Nikon ZR")
}

private func ptpString(_ value: String) -> [UInt8] {
    guard !value.isEmpty else { return [0] }
    var bytes = [UInt8(value.utf16.count + 1)]
    for unit in value.utf16 {
        bytes += ByteCoding.uint16LE(unit)
    }
    bytes += [0, 0]
    return bytes
}

private func emptyUInt16Array() -> [UInt8] {
    [0, 0, 0, 0]
}
