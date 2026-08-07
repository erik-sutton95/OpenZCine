import Foundation
import Testing

@testable import OpenZCineCore

/// The one path whose bandwidth is fixed by the camera's own radio starts at Fast; nothing else
/// is known to be narrow, so nothing else is second-guessed.
@Test func onlyTheAccessPointStartsAtAFasterBiasThanTheSeed() {
    for kind in CameraPath.Kind.allCases {
        let resolved = SetupStreamSettings.qualityBias(
            stored: nil, pathKind: kind, seed: .balanced)
        #expect(resolved == (kind == .cameraAccessPoint ? .latency : .balanced))
    }
    // No path at all — a record that predates the declared path — is not an access point.
    #expect(
        SetupStreamSettings.qualityBias(stored: nil, pathKind: nil, seed: .balanced) == .balanced)
}

/// A default is what fills the absence of a choice, never something that overrides one. An
/// operator who deliberately picked Quality for an access-point setup keeps it.
@Test func aStoredBiasWinsOnEveryPathIncludingTheAccessPoint() {
    for kind in CameraPath.Kind.allCases {
        for stored in OperatorPreferences.QualityBias.allCases {
            #expect(
                SetupStreamSettings.qualityBias(stored: stored, pathKind: kind, seed: .balanced)
                    == stored)
        }
    }
}

/// The seed is what the settings rows edit while nothing is connected, so it has to be what an
/// unconfigured setup inherits — otherwise changing the default would silently do nothing.
@Test func anUnconfiguredSetupInheritsTheSeedRatherThanAShippedConstant() {
    for seed in OperatorPreferences.QualityBias.allCases {
        #expect(
            SetupStreamSettings.qualityBias(stored: nil, pathKind: .usbC, seed: seed) == seed)
    }
    for seed in OperatorPreferences.StreamPreset.allCases {
        #expect(
            SetupStreamSettings.streamPreset(stored: nil, pathKind: .usbC, seed: seed) == seed)
    }
}

/// The preset picks the frame SIZE and the assists read that frame. A narrow link is a reason to
/// compress harder, not to hand every detector a picture too small to measure.
@Test func noPathOverridesTheStreamPresetIncludingTheAccessPoint() {
    for kind in CameraPath.Kind.allCases {
        #expect(
            SetupStreamSettings.streamPreset(stored: nil, pathKind: kind, seed: .quality)
                == .quality)
        #expect(
            SetupStreamSettings.streamPreset(stored: .fast, pathKind: kind, seed: .quality)
                == .fast)
    }
}

/// Two setups of one camera are two records, and an address cannot tell them apart — every
/// camera-AP Nikon answers on 192.168.1.1, and a body's AP and router setups can share a host.
@Test func writingOneSetupsStreamSettingsLeavesItsSiblingSetupAlone() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            path: .cameraAccessPoint(ssid: "NIKON_ZR_6002199")
        ),
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            path: .infrastructure(networkName: "Studio")
        ),
    ]

    let updated = PTPIPSavedCameraRecords.updatingStreamSettings(
        host: "192.168.1.1",
        pathKind: .cameraAccessPoint,
        streamPreset: .fast,
        qualityBias: .latency,
        in: records
    )

    let accessPoint = updated.first { $0.pathKind == .cameraAccessPoint }
    let router = updated.first { $0.pathKind == .infrastructure }
    #expect(accessPoint?.streamPreset == .fast)
    #expect(accessPoint?.qualityBias == .latency)
    #expect(router?.streamPreset == nil)
    #expect(router?.qualityBias == nil)
}

/// A caller that knows one setting should not have to read the other back to avoid clearing it.
@Test func aNilArgumentLeavesThatSettingAloneRatherThanClearingIt() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            path: .cameraAccessPoint(ssid: nil),
            streamPreset: .quality,
            qualityBias: .detail
        )
    ]

    let updated = PTPIPSavedCameraRecords.updatingStreamSettings(
        host: "192.168.1.1",
        pathKind: .cameraAccessPoint,
        streamPreset: nil,
        qualityBias: .latency,
        in: records
    )

    #expect(updated.first?.streamPreset == .quality)
    #expect(updated.first?.qualityBias == .latency)
}

/// Every reconnect upserts a record that knows nothing about stream settings. If the merge let
/// that win, an operator's choice would survive exactly until the next time they used the setup.
@Test func reconnectingToASetupDoesNotEraseTheStreamSettingsChosenOnIt() {
    let chosen = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "Nikon ZR",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        path: .cameraAccessPoint(ssid: "NIKON_ZR_6002199"),
        streamPreset: .fast,
        qualityBias: .latency
    )
    // What a reconnect writes: newer, and blank on everything it has no reason to know.
    let reconnect = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "Nikon ZR",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
        path: .cameraAccessPoint(ssid: "NIKON_ZR_6002199")
    )

    let merged = PTPIPSavedCameraRecords.canonicalized([chosen, reconnect])

    #expect(merged.count == 1)
    #expect(merged.first?.streamPreset == .fast)
    #expect(merged.first?.qualityBias == .latency)
}

/// Records written before the fields existed decode with both absent, which is exactly the
/// "never chosen here" the resolver expects — so an existing operator keeps what they had.
@Test func aRecordThatPredatesTheFieldsDecodesAsNeverChosen() throws {
    let legacy = """
        {"host":"192.168.1.1","displayName":"Nikon ZR","transport":"Wi-Fi"}
        """
    let record = try JSONDecoder().decode(
        PTPIPSavedCameraRecord.self, from: Data(legacy.utf8))

    #expect(record.streamPreset == nil)
    #expect(record.qualityBias == nil)
    #expect(
        SetupStreamSettings.qualityBias(
            stored: record.qualityBias, pathKind: record.pathKind, seed: .balanced) == .balanced)
}
