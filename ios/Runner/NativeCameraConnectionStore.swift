import Foundation
import OpenZCineCore

@MainActor
final class NativeCameraConnectionStore {
    static let shared = NativeCameraConnectionStore()
    var onSavedCamerasChanged: (() -> Void)?

    private let guidKey = "OpenZCine.PTPIP.GUID"
    private let pairedHostsKey = "OpenZCine.PTPIP.PairedHosts"
    private let savedCamerasKey = "OpenZCine.PTPIP.SavedCameras"
    private let knownPairedCamerasKey = "OpenZCine.PTPIP.KnownPairedCameras"

    private init() {
        migrateLegacyRebrandKeysIfNeeded()
    }

    /// One-time, idempotent migration of the pre-rebrand `OpenZCinemaControl.*` UserDefaults keys
    /// to `OpenZCine.*` — without it the rename orphans the saved/paired-camera list and cached
    /// app GUID, forcing a full camera re-pair.
    private func migrateLegacyRebrandKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let migrations = [
            ("OpenZCinemaControl.PTPIP.GUID", guidKey),
            ("OpenZCinemaControl.PTPIP.PairedHosts", pairedHostsKey),
            ("OpenZCinemaControl.PTPIP.SavedCameras", savedCamerasKey),
            ("OpenZCinemaControl.PTPIP.KnownPairedCameras", knownPairedCamerasKey),
        ]
        for (legacyKey, currentKey) in migrations {
            guard defaults.object(forKey: currentKey) == nil else { continue }
            guard let value = defaults.object(forKey: legacyKey) else { continue }
            defaults.set(value, forKey: currentKey)
            defaults.removeObject(forKey: legacyKey)
        }
    }

    func guid() -> Data {
        let defaults = UserDefaults.standard
        let persistedGUID = defaults.data(forKey: guidKey)
        let resolvedGUID = PTPIPInitiator.resolvedAppGUID(persistedGUID: persistedGUID)
        if persistedGUID != resolvedGUID {
            defaults.set(resolvedGUID, forKey: guidKey)
        }
        return resolvedGUID
    }

    func pairedHosts() -> [String] {
        knownPairedCameras().map(\.host)
    }

    func isPaired(host: String) -> Bool {
        PTPIPSavedCameraRecords.canonicalized(knownPairedCameras()).contains {
            $0.host == PTPIPPairedHosts.normalizedHost(host)
        }
    }

    func markPaired(host: String) {
        upsertKnownPairedCamera(
            host: host,
            displayName: "",
            transport: "Wi-Fi",
            lastSeenAt: Date()
        )
    }

    func upsertSavedCamera(
        host: String, displayName: String, transport: String,
        onCameraAccessPoint: Bool? = nil,
        serialNumber: String? = nil,
        path: CameraPath? = nil
    ) {
        var records = PTPIPSavedCameraRecords.upserting(
            host: host,
            displayName: displayName,
            transport: transport,
            lastSeenAt: Date(),
            pairedViaCameraAccessPoint: onCameraAccessPoint,
            serialNumber: serialNumber,
            path: path,
            into: savedCameras()
        )
        // The presentation SSID stamp is for the CAMERA-AP setup — stamping a derived
        // "NIKON_…" onto every network record is what taught router records to prompt joins.
        // An untyped call (legacy path) keeps the old stamp so migration can still read it.
        let stampsSSID: Bool
        switch path?.kind {
        case .cameraAccessPoint: stampsSSID = true
        case nil: stampsSSID = !PTPIPSavedCameraRecord.isUSBTransportLabel(transport)
        default: stampsSSID = false
        }
        if stampsSSID, let ssid = CameraWiFiSSID.deriveSSID(fromCameraName: displayName) {
            records = PTPIPSavedCameraRecords.updatingWiFiSSID(
                host: host,
                wifiSSID: ssid,
                in: records
            )
        }
        saveSavedCameras(records)
        upsertKnownPairedCamera(
            host: host,
            displayName: displayName,
            transport: transport,
            lastSeenAt: Date()
        )
    }

    func updateSavedCameraStreamSettings(
        host: String,
        pathKind: CameraPath.Kind?,
        streamPreset: OperatorPreferences.StreamPreset?,
        qualityBias: OperatorPreferences.QualityBias?
    ) {
        saveSavedCameras(
            PTPIPSavedCameraRecords.updatingStreamSettings(
                host: host,
                pathKind: pathKind,
                streamPreset: streamPreset,
                qualityBias: qualityBias,
                in: savedCameras()
            )
        )
    }

    func forgetPairing(host: String) {
        saveSavedCameras(PTPIPSavedCameraRecords.removing(host, from: savedCameras()))
    }

    func forgetKnownPairing(host: String) {
        saveKnownPairedCameras(
            PTPIPSavedCameraRecords.removing(host, from: knownPairedCameras())
        )
        saveSavedCameras(PTPIPSavedCameraRecords.removing(host, from: savedCameras()))
    }

    func savedCameras() -> [PTPIPSavedCameraRecord] {
        let records = decodedSavedCameras()
        if !records.isEmpty {
            let canonical = PTPIPSavedCameraRecords.canonicalized(records)
            if canonical != records {
                saveSavedCameras(canonical)
            }
            return canonical
        }
        return []
    }

    func knownPairedCameras() -> [PTPIPSavedCameraRecord] {
        let records = decodedKnownPairedCameras()
        let legacyHosts = PTPIPPairedHosts.canonicalized(
            UserDefaults.standard.stringArray(forKey: pairedHostsKey) ?? []
        ).map {
            PTPIPSavedCameraRecord(
                host: $0,
                displayName: "Camera \($0)",
                transport: "Wi-Fi",
                lastSeenAt: nil
            )
        }
        let migrated = PTPIPSavedCameraRecords.canonicalized(
            records + legacyHosts + decodedSavedCameras()
        )
        if migrated != records {
            saveKnownPairedCameras(migrated)
        }
        return migrated
    }

    private func decodedSavedCameras() -> [PTPIPSavedCameraRecord] {
        decodedCameraRecords(forKey: savedCamerasKey)
    }

    private func decodedKnownPairedCameras() -> [PTPIPSavedCameraRecord] {
        decodedCameraRecords(forKey: knownPairedCamerasKey)
    }

    private func decodedCameraRecords(forKey key: String) -> [PTPIPSavedCameraRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let records = try? JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    private func upsertKnownPairedCamera(
        host: String,
        displayName: String,
        transport: String,
        lastSeenAt: Date?
    ) {
        let records = PTPIPSavedCameraRecords.upserting(
            host: host,
            displayName: displayName,
            transport: transport,
            lastSeenAt: lastSeenAt,
            into: knownPairedCameras()
        )
        saveKnownPairedCameras(records)
    }

    private func saveSavedCameras(_ records: [PTPIPSavedCameraRecord]) {
        let canonical = PTPIPSavedCameraRecords.canonicalized(records)
        if let data = try? JSONEncoder().encode(canonical) {
            UserDefaults.standard.set(data, forKey: savedCamerasKey)
            onSavedCamerasChanged?()
        }
    }

    private func saveKnownPairedCameras(_ records: [PTPIPSavedCameraRecord]) {
        let canonical = PTPIPSavedCameraRecords.canonicalized(records)
        if let data = try? JSONEncoder().encode(canonical) {
            UserDefaults.standard.set(data, forKey: knownPairedCamerasKey)
        }
        UserDefaults.standard.set(canonical.map(\.host), forKey: pairedHostsKey)
    }
}

// SAFETY: `@unchecked Sendable` — `establishmentSummary` is mutated only during the serialized
// establishment sequence (`openAndIdentify` and its helpers run one transaction at a time); the
// transport serializes its own transactions and socket/device I/O internally.
