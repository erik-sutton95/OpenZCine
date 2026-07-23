import Foundation
import OpenZCineCore
import Testing

@Suite("Z camera operation policy")
struct ZCameraCapabilityProfileTests {
    private static let gen1Ops: Set<UInt16> = [
        0x90CA, 0x90C2, 0x9201, 0x9202, 0x9203, 0x9428, 0x90C7, 0x941C, 0x90C8,
        0x100E, 0x9207, 0x90C0, 0x90CB, 0x920C,
    ]
    private static let gen2Ops: Set<UInt16> = gen1Ops.union([0x9435])
    private static let gen3Ops: Set<UInt16> =
        gen2Ops.subtracting([0x90CA]).union([
            0x9439, 0x943A, 0x943B, 0x943C, 0x9445, 0x9446, 0x9447,
        ])

    @Test func gen1UsesPropertyAppModeAndLegacyDiscovery() {
        let policy = ZCameraOperationPolicy(operations: Self.gen1Ops)
        #expect(policy.isKnown)
        #expect(!policy.appModeViaOperation)
        #expect(policy.vendorCodeDiscoveryOperation == .getVendorPropCodes)
        #expect(!policy.supportsExtendedPropertyOps)
        #expect(!policy.supportsOpenCapture)
        #expect(policy.stillCaptureOperation == .initiateCaptureRecInMedia)
    }

    @Test func gen2AddsAppModeOperation() {
        let policy = ZCameraOperationPolicy(operations: Self.gen2Ops)
        #expect(policy.appModeViaOperation)
        #expect(!policy.supportsExtendedPropertyOps)
    }

    @Test func gen3AddsVendorCodesExOpsAndOpenCapture() {
        let policy = ZCameraOperationPolicy(operations: Self.gen3Ops)
        #expect(policy.vendorCodeDiscoveryOperation == .getVendorCodes)
        #expect(policy.supportsExtendedPropertyOps)
        #expect(policy.supportsOpenCapture)
    }

    @Test func unknownOpsAssumeModernSurfaceExceptOpenCapture() {
        let policy = ZCameraOperationPolicy(operations: [])
        #expect(!policy.isKnown)
        #expect(policy.stillCaptureOperation == .initiateCaptureRecInMedia)
        #expect(policy.appModeViaOperation)
        #expect(policy.supportsExtendedPropertyOps)
        #expect(!policy.supportsOpenCapture)
    }

    @Test func missingMediaCaptureFallsBackToStandardCapture() {
        let policy = ZCameraOperationPolicy(operations: [0x100E])
        #expect(policy.stillCaptureOperation == .initiateCapture)
    }

    @Test func vendorPropertyListDecodesBothWidths() {
        // Eight 4-byte codes (the plausibility floor) incl. one extended code.
        var wide = Data(ByteCoding.uint32LE(8))
        for code in [0xD1A6, 0xD100, 0xD061, 0xD05D, 0xD054, 0xD030, 0xD0B5, 0x0001_D070] {
            wide += Data(ByteCoding.uint32LE(UInt32(code)))
        }
        let wideCodes = PTPVendorPropertyCodeList.decode(wide, fourByteCodes: true)
        #expect(wideCodes.contains(0xD1A6))
        #expect(wideCodes.contains(0x0001_D070))

        var narrow = Data(ByteCoding.uint32LE(8))
        for code in [0xD1A6, 0xD100, 0xD061, 0xD05D, 0xD054, 0xD030, 0xD0A2, 0xD16C] {
            narrow += Data(ByteCoding.uint16LE(UInt16(code)))
        }
        let narrowCodes = PTPVendorPropertyCodeList.decode(narrow, fourByteCodes: false)
        #expect(narrowCodes.contains(0xD0A2))
        #expect(narrowCodes.count == 8)
    }

    @Test func vendorPropertyListRejectsGarbledPayloads() {
        #expect(PTPVendorPropertyCodeList.decode(Data(), fourByteCodes: true).isEmpty)
        // Count claims more elements than the payload carries.
        var truncated = Data(ByteCoding.uint32LE(100))
        truncated += Data(ByteCoding.uint32LE(0xD1A6))
        #expect(PTPVendorPropertyCodeList.decode(truncated, fourByteCodes: true).isEmpty)
        // Implausibly small lists are treated as garbage, not a poll veto.
        var tiny = Data(ByteCoding.uint32LE(2))
        tiny += Data(ByteCoding.uint32LE(0xD1A6)) + Data(ByteCoding.uint32LE(0xD100))
        #expect(PTPVendorPropertyCodeList.decode(tiny, fourByteCodes: true).isEmpty)
    }
}
